#!/usr/bin/env python3
"""
Spindle ingest tool.

Converts a folder of ordinary music files into everything the Playdate app
needs: ADPCM audio in Playdate's .pda container, album artwork dithered to
1-bit .pdi images, precomputed spectrum and beat data for the visualizers, and
a single library.json index that the app reads once at startup.

Why this exists at all: the Playdate cannot seek MP3 files usefully, because
seeking is a linear scan costing roughly 89.5 milliseconds per second of seek
target. ADPCM seeks in about one millisecond. But ADPCM in the .pda container
cannot carry ID3 tags, and the Playdate SDK provides no FFT, so both the
metadata and the frequency analysis have to be prepared here on the Mac.

Usage:
    python3 tools/ingest.py <source folder> <output folder>

Source folder layout, which you maintain by hand:

    music/
      Beastie Boys/
        Ill Communication/
          06 Sabotage.mp3
          cover.jpg              optional, otherwise embedded art is used
          _album.m3u             optional, overrides tags read from the files
    playlists/
      Long Drive.m3u             optional

Output folder layout, which this tool generates:

    music/<album slug>/<track slug>.pda
    art/<album slug>.pdi
    art/<album slug>-thumb.pdi
    analysis/<album slug>/<track slug>.bin
    library.json
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unicodedata
from pathlib import Path

import numpy
from PIL import Image, ImageOps

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Audio target. Stereo at 44.1 kHz works out to about 2.6 MB per minute, which
# fits roughly 25 hours of music on the 4 GB device. Storage is not the binding
# constraint, so there is no reason to degrade quality.
AUDIO_SAMPLE_RATE = 44100
AUDIO_CHANNEL_COUNT = 2

# Album artwork is displayed at 140 by 140 pixels on the now playing screen.
ALBUM_ART_SIZE = 140

# The album list shows a smaller cover beside each row. It is dithered
# separately at its final size rather than being shrunk on the device, because a
# Floyd Steinberg pattern is chosen for the resolution it was generated at and
# resampling it turns the picture into noise.
ALBUM_THUMBNAIL_SIZE = 60

# Spectrum analysis. Twenty frames per second is plenty for a visualizer and
# keeps the per-track analysis file to roughly 80 KB. Sixteen bands spread
# logarithmically across the audible range gives a useful spread from bass to
# treble without wasting resolution where the ear cannot tell the difference.
ANALYSIS_FRAMES_PER_SECOND = 20
ANALYSIS_BAND_COUNT = 16
ANALYSIS_FFT_WINDOW_SIZE = 2048

# The scrub bar is drawn across a 400 pixel wide screen, so a couple of
# hundred amplitude samples is more than enough detail for the waveform. It is
# stored in the binary analysis file rather than in the JSON index, to keep the
# index small enough that startup stays fast on a large library.
WAVEFORM_POINT_COUNT = 200

# File extensions we are willing to read as source audio.
SOURCE_AUDIO_EXTENSIONS = {".mp3", ".m4a", ".flac", ".wav", ".aiff", ".ogg"}

# Magic bytes at the start of an analysis file, so the app can sanity check
# what it is reading before trusting the rest.
ANALYSIS_FILE_MAGIC = b"SPNA"
ANALYSIS_FILE_VERSION = 2


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

def run_command(command_parts, description):
    """
    Run an external command and raise a readable error if it fails.

    The tools we shell out to (ffmpeg, ffprobe, pdc) are noisy on success and
    unhelpful on failure, so this swallows their normal chatter and only
    surfaces output when something has actually gone wrong.
    """
    result = subprocess.run(
        command_parts,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"{description} failed.\n"
            f"Command: {' '.join(str(part) for part in command_parts)}\n"
            f"{result.stderr.strip()}"
        )
    return result.stdout


def make_filesystem_slug(text):
    """
    Turn an arbitrary album or track title into something safe to use as a
    filename, while still being readable by a human browsing the data folder
    over USB.

    Accented characters are folded to their closest ASCII equivalent rather
    than stripped, so "Namaste" survives instead of becoming "Namast".
    """
    normalised = unicodedata.normalize("NFKD", text)
    ascii_only = normalised.encode("ascii", "ignore").decode("ascii")
    lowered = ascii_only.lower()
    hyphenated = re.sub(r"[^a-z0-9]+", "-", lowered)
    return hyphenated.strip("-") or "untitled"


# ---------------------------------------------------------------------------
# Reading metadata from the source files
# ---------------------------------------------------------------------------

def read_tags_with_mutagen(audio_file_path):
    """
    Read title, artist, album, track number and year from a source file's
    embedded tags. Returns a dictionary with whatever could be found, and
    simply omits anything that is missing rather than guessing.

    mutagen presents different tag formats through a common interface, so this
    works for MP3, FLAC, M4A and the rest without special casing each one.
    """
    try:
        import mutagen
    except ImportError:
        return {}

    try:
        loaded_file = mutagen.File(audio_file_path, easy=True)
    except Exception:
        return {}

    if loaded_file is None:
        return {}

    def first_value(tag_name):
        values = loaded_file.get(tag_name)
        if values:
            return str(values[0]).strip()
        return None

    tags = {}
    for tag_name, key in (
        ("title", "title"),
        ("artist", "artist"),
        ("album", "album"),
        ("albumartist", "album_artist"),
        ("date", "year"),
    ):
        value = first_value(tag_name)
        if value:
            tags[key] = value

    # Track numbers are often stored as "6/18", so keep only the part before
    # the slash and only if it is actually a number.
    track_number_raw = first_value("tracknumber")
    if track_number_raw:
        leading_digits = track_number_raw.split("/")[0].strip()
        if leading_digits.isdigit():
            tags["track_number"] = int(leading_digits)

    # Years are frequently full dates such as "1994-05-31", and we only want
    # the year itself.
    if "year" in tags:
        year_match = re.match(r"(\d{4})", tags["year"])
        tags["year"] = int(year_match.group(1)) if year_match else None
        if tags["year"] is None:
            del tags["year"]

    return tags


def read_album_sidecar(album_folder):
    """
    Read an optional _album.m3u sidecar, which lets you override what the
    embedded tags say without editing the audio files themselves.

    The format is ordinary extended m3u with a few extra directives. Anything
    it specifies wins over the tags read from the files:

        #EXTALB:Ill Communication
        #EXTART:Beastie Boys
        #EXTYEAR:1994
        #EXTCOVER:cover.jpg
        06 Sabotage.mp3
        08 Sabrosa.mp3

    Listing filenames is optional. If any are listed, that becomes the track
    order. If none are listed, the folder is sorted by filename instead.
    """
    sidecar_path = album_folder / "_album.m3u"
    if not sidecar_path.exists():
        return {}

    overrides = {}
    explicit_track_order = []

    directive_to_key = {
        "EXTALB": "album",
        "EXTART": "artist",
        "EXTYEAR": "year",
        "EXTCOVER": "cover",
    }

    for raw_line in sidecar_path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw_line.strip()
        if not line:
            continue

        if line.startswith("#"):
            directive_match = re.match(r"#(EXT[A-Z]+):(.*)", line)
            if directive_match:
                directive, value = directive_match.groups()
                key = directive_to_key.get(directive)
                if key:
                    overrides[key] = value.strip()
            continue

        explicit_track_order.append(line)

    if "year" in overrides:
        if overrides["year"].isdigit():
            overrides["year"] = int(overrides["year"])
        else:
            del overrides["year"]

    if explicit_track_order:
        overrides["track_order"] = explicit_track_order

    return overrides


def find_playlists(source_folder):
    """
    Read every .m3u in the playlists folder.

    A playlist is not an album and is deliberately not treated like one. An
    album is a folder of audio files that get converted; a playlist is a list of
    pointers at tracks that already live in albums. If it were another folder of
    files, every track on a playlist would be converted and stored a second
    time, and at 2.6 MB a minute that costs an album's worth of space for a
    couple of playlists.

    So this returns the paths a playlist names and nothing else. Resolving them
    to tracks happens later, once the albums have been processed and there is
    something to resolve against.

    The playlist is named by its filename, which keeps it to one concept: no
    directive to declare a name, no way for the name and the file to disagree.
    """
    playlists_folder = source_folder / "playlists"
    if not playlists_folder.is_dir():
        return []

    playlists = []

    for playlist_path in sorted(playlists_folder.glob("*.m3u")):
        listed_paths = []

        for raw_line in playlist_path.read_text(encoding="utf-8", errors="replace").splitlines():
            line = raw_line.strip()
            # Comments and the #EXTINF lines that carry duration and title are
            # both skipped: the title and duration come from the track itself,
            # which is more trustworthy than whatever wrote the playlist.
            if line and not line.startswith("#"):
                listed_paths.append(line)

        if listed_paths:
            playlists.append({
                "name": playlist_path.stem,
                "listed_paths": listed_paths,
                "folder": playlists_folder,
            })
        else:
            print(f"    warning: {playlist_path.name} lists no tracks", file=sys.stderr)

    return playlists


def resolve_playlist_track(listed_path, playlist_folder, source_folder, tracks_by_source_path,
                           tracks_by_filename):
    """
    Work out which converted track a line in a playlist refers to.

    Playlists are written by other programs and by hand, so the paths in them
    can be absolute, relative to the playlist, or relative to the music folder.
    Each is tried in turn rather than one being declared correct, because a
    playlist that silently loses half its tracks is worse than one that takes a
    moment longer to read.

    Matching on filename alone is the last resort. It is what makes a playlist
    exported from another application work at all, since those often carry paths
    from a library that lives somewhere else entirely.
    """
    candidates = [
        Path(listed_path),
        playlist_folder / listed_path,
        source_folder / listed_path,
        source_folder / "music" / listed_path,
    ]

    for candidate in candidates:
        try:
            resolved = candidate.resolve()
        except OSError:
            continue
        if resolved in tracks_by_source_path:
            return tracks_by_source_path[resolved]

    matches = tracks_by_filename.get(Path(listed_path).name)
    if matches and len(matches) == 1:
        return matches[0]
    if matches:
        print(f"    warning: \"{listed_path}\" matches {len(matches)} tracks by name, skipped",
              file=sys.stderr)
        return None

    return None


def find_album_artwork(album_folder, first_audio_file):
    """
    Locate album artwork, preferring a file sitting in the album folder and
    falling back to whatever is embedded in the first track.

    Returns a PIL Image, or None if no artwork could be found anywhere.
    """
    for candidate_name in ("cover.jpg", "cover.png", "folder.jpg", "front.jpg"):
        candidate_path = album_folder / candidate_name
        if candidate_path.exists():
            try:
                return Image.open(candidate_path)
            except Exception:
                pass

    # Nothing on disk, so try artwork embedded in the audio file's tags.
    try:
        import mutagen
        from io import BytesIO

        loaded_file = mutagen.File(first_audio_file)
        if loaded_file is None:
            return None

        # ID3 stores pictures in APIC frames, MP4 in "covr", FLAC in pictures.
        if hasattr(loaded_file, "tags") and loaded_file.tags:
            for tag_key in loaded_file.tags.keys():
                if tag_key.startswith("APIC"):
                    return Image.open(BytesIO(loaded_file.tags[tag_key].data))
            if "covr" in loaded_file.tags:
                return Image.open(BytesIO(bytes(loaded_file.tags["covr"][0])))

        if getattr(loaded_file, "pictures", None):
            return Image.open(BytesIO(loaded_file.pictures[0].data))
    except Exception:
        pass

    return None


# ---------------------------------------------------------------------------
# Audio conversion and analysis
# ---------------------------------------------------------------------------

def get_audio_duration_seconds(audio_file_path):
    """Ask ffprobe how long a file is, in seconds."""
    output = run_command(
        [
            "ffprobe", "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            str(audio_file_path),
        ],
        f"Reading duration of {audio_file_path.name}",
    )
    return float(output.strip())


def convert_to_adpcm_wav(source_audio_path, destination_wav_path):
    """
    Convert a source file to 4-bit IMA ADPCM in a WAV container.

    This WAV is only an intermediate. It gets handed to pdc, which repackages
    it as .pda. ADPCM stored as a plain .wav does not play on the device, so
    the pdc step is not optional.
    """
    run_command(
        [
            "ffmpeg", "-y",
            "-i", str(source_audio_path),
            "-vn",
            "-acodec", "adpcm_ima_wav",
            "-ar", str(AUDIO_SAMPLE_RATE),
            "-ac", str(AUDIO_CHANNEL_COUNT),
            str(destination_wav_path),
            "-loglevel", "error",
        ],
        f"Converting {source_audio_path.name} to ADPCM",
    )


def decode_to_mono_samples(source_audio_path):
    """
    Decode a source file to a mono float array for analysis.

    Analysis does not need stereo, and mixing to mono halves the work and
    avoids the question of which channel to analyse. The samples come back as
    16-bit integers on stdout and get scaled into the range minus one to one.
    """
    raw_bytes = subprocess.run(
        [
            "ffmpeg",
            "-i", str(source_audio_path),
            "-f", "s16le",
            "-acodec", "pcm_s16le",
            "-ac", "1",
            "-ar", str(AUDIO_SAMPLE_RATE),
            "-",
            "-loglevel", "error",
        ],
        capture_output=True,
        check=True,
    ).stdout

    samples_as_integers = numpy.frombuffer(raw_bytes, dtype=numpy.int16)
    return samples_as_integers.astype(numpy.float32) / 32768.0


def compute_band_energies(mono_samples):
    """
    Produce the per-frame spectrum the visualizers read.

    Runs a short-time Fourier transform at ANALYSIS_FRAMES_PER_SECOND, groups
    the resulting bins into logarithmically spaced bands, and scales each band
    to a single byte. Logarithmic spacing matters because human hearing is
    roughly logarithmic in frequency, so linear bands would waste almost all
    their resolution on the top octave where nothing interesting happens.

    Returns an array of shape (frame count, ANALYSIS_BAND_COUNT), dtype uint8.
    """
    hop_size_in_samples = AUDIO_SAMPLE_RATE // ANALYSIS_FRAMES_PER_SECOND
    window_function = numpy.hanning(ANALYSIS_FFT_WINDOW_SIZE).astype(numpy.float32)

    frame_count = max(1, (len(mono_samples) - ANALYSIS_FFT_WINDOW_SIZE) // hop_size_in_samples)

    # Work out which FFT bins belong to which band. The lowest band starts at
    # 40 Hz because there is nothing musically useful below that on a device
    # with this speaker, and the highest stops at 16 kHz.
    band_edges_in_hertz = numpy.logspace(
        numpy.log10(40.0),
        numpy.log10(16000.0),
        ANALYSIS_BAND_COUNT + 1,
    )
    hertz_per_bin = AUDIO_SAMPLE_RATE / ANALYSIS_FFT_WINDOW_SIZE
    band_edges_in_bins = numpy.clip(
        (band_edges_in_hertz / hertz_per_bin).astype(int),
        0,
        ANALYSIS_FFT_WINDOW_SIZE // 2,
    )

    band_energies = numpy.zeros((frame_count, ANALYSIS_BAND_COUNT), dtype=numpy.float32)
    spectrum_history = numpy.zeros((frame_count, ANALYSIS_FFT_WINDOW_SIZE // 2 + 1), dtype=numpy.float32)

    for frame_index in range(frame_count):
        window_start = frame_index * hop_size_in_samples
        windowed_samples = mono_samples[window_start:window_start + ANALYSIS_FFT_WINDOW_SIZE] * window_function
        magnitude_spectrum = numpy.abs(numpy.fft.rfft(windowed_samples))
        spectrum_history[frame_index] = magnitude_spectrum

        for band_index in range(ANALYSIS_BAND_COUNT):
            first_bin = band_edges_in_bins[band_index]
            last_bin = max(first_bin + 1, band_edges_in_bins[band_index + 1])
            band_energies[frame_index, band_index] = magnitude_spectrum[first_bin:last_bin].mean()

    # Convert to decibels so quiet detail survives, then normalise the whole
    # track to fill the byte range. Normalising per track rather than globally
    # means a quietly mastered album still produces a lively visualizer.
    band_energies_in_decibels = 20.0 * numpy.log10(band_energies + 1e-9)
    loudest = band_energies_in_decibels.max()
    quietest = max(band_energies_in_decibels.min(), loudest - 60.0)
    normalised = (band_energies_in_decibels - quietest) / max(loudest - quietest, 1e-6)

    scaled_to_bytes = numpy.clip(normalised * 255.0, 0, 255).astype(numpy.uint8)
    return scaled_to_bytes, spectrum_history


def detect_beats(spectrum_history):
    """
    Find onset times using spectral flux, and estimate a tempo from them.

    Spectral flux measures how much the spectrum grew between one frame and
    the next. Growth means energy appearing, which is what a drum hit or a note
    attack looks like. Only positive change counts, because energy fading away
    is not an onset.

    Returns a list of frame indices where an onset was detected, and an
    estimated beats per minute, which is None when there were too few onsets to
    make a sensible guess.
    """
    if len(spectrum_history) < 3:
        return [], None

    spectrum_difference = numpy.diff(spectrum_history, axis=0)
    positive_change_only = numpy.maximum(spectrum_difference, 0.0)
    flux_per_frame = positive_change_only.sum(axis=1)

    # Compare each frame against a local average rather than a fixed level, so
    # a quiet passage still registers its own onsets instead of being drowned
    # out by a loud chorus elsewhere in the track.
    smoothing_window = ANALYSIS_FRAMES_PER_SECOND  # roughly one second
    moving_average = numpy.convolve(
        flux_per_frame,
        numpy.ones(smoothing_window) / smoothing_window,
        mode="same",
    )
    threshold = moving_average * 1.5

    onset_frame_indices = []
    minimum_frames_between_onsets = max(1, ANALYSIS_FRAMES_PER_SECOND // 8)
    last_onset_frame = -minimum_frames_between_onsets

    for frame_index in range(1, len(flux_per_frame) - 1):
        is_above_threshold = flux_per_frame[frame_index] > threshold[frame_index]
        is_local_peak = (
            flux_per_frame[frame_index] >= flux_per_frame[frame_index - 1]
            and flux_per_frame[frame_index] > flux_per_frame[frame_index + 1]
        )
        is_far_enough_from_last = frame_index - last_onset_frame >= minimum_frames_between_onsets

        if is_above_threshold and is_local_peak and is_far_enough_from_last:
            onset_frame_indices.append(frame_index)
            last_onset_frame = frame_index

    estimated_bpm = None
    if len(onset_frame_indices) > 8:
        gaps_between_onsets = numpy.diff(onset_frame_indices)
        # The median gap is more robust than the mean here, because onset
        # detection always produces a few spurious extras.
        median_gap_in_frames = float(numpy.median(gaps_between_onsets))
        if median_gap_in_frames > 0:
            seconds_per_beat = median_gap_in_frames / ANALYSIS_FRAMES_PER_SECOND
            candidate_bpm = 60.0 / seconds_per_beat
            # Fold the result into a musically plausible range, since onset
            # detection often locks onto half or double the real tempo.
            while candidate_bpm < 70:
                candidate_bpm *= 2
            while candidate_bpm > 180:
                candidate_bpm /= 2
            estimated_bpm = round(candidate_bpm, 1)

    return onset_frame_indices, estimated_bpm


def compute_waveform_envelope(mono_samples):
    """
    Reduce the whole track to WAVEFORM_POINT_COUNT amplitude values for the
    scrub bar. Each point is the RMS amplitude of its slice.

    This started out as the peak of each slice, on the reasoning that a track's
    loud chorus should look loud. That turned out to be exactly wrong, and the
    measurement is worth keeping because the failure was invisible until it was
    counted. Two hundred points across a three minute track is roughly one point
    per second, and the peak of any one second of a mastered record is very
    nearly full scale almost all of the time. Across the whole 122 track test
    library the median point sat at 228 out of 255 and 49 percent of all points
    were at 230 or above, so the scrub bar was a solid block on most songs and
    showed nothing about the shape of anything.

    RMS measures how loud a slice actually is rather than how loud its single
    loudest sample was, so quiet verses read as quiet and the structure of a
    song is visible. It is normalised to the track's own loudest slice, so every
    track uses the full height of the bar whatever it was mastered at.

    A power curve applied on top of this was tried, to push the difference
    between loud and quiet further apart. It made the busy tracks look better
    and hollowed the quiet ones out into nothing, so there is no curve here.
    """
    slice_boundaries = numpy.linspace(0, len(mono_samples), WAVEFORM_POINT_COUNT + 1).astype(int)
    loudness_per_slice = numpy.zeros(WAVEFORM_POINT_COUNT, dtype=numpy.float64)

    for point_index in range(WAVEFORM_POINT_COUNT):
        slice_start = slice_boundaries[point_index]
        slice_end = max(slice_start + 1, slice_boundaries[point_index + 1])
        slice_samples = mono_samples[slice_start:slice_end].astype(numpy.float64)
        loudness_per_slice[point_index] = numpy.sqrt(numpy.mean(slice_samples ** 2))

    loudest_slice = loudness_per_slice.max()
    if loudest_slice > 0:
        loudness_per_slice /= loudest_slice

    return numpy.clip(loudness_per_slice * 255.0, 0, 255).astype(numpy.uint8)


def write_analysis_file(destination_path, band_energies, onset_frame_indices, waveform):
    """
    Write the per-track analysis file that the visualizers and the scrub bar
    read.

    The layout is deliberately simple so the Lua side can parse it with
    string.byte and a couple of loops, with no dependency on string.unpack
    being available:

        offset 0   4 bytes   magic "SPNA"
        offset 4   1 byte    format version
        offset 5   1 byte    frames per second
        offset 6   1 byte    band count
        offset 7   1 byte    waveform point count
        offset 8   4 bytes   frame count, big endian
        offset 12  4 bytes   onset count, big endian
        offset 16  ...       band bytes, frame count times band count
        then       ...       onset frame indices, two bytes each, big endian
        then       ...       waveform bytes, one per point

    The waveform lives here rather than in the library index because the index
    is JSON. Two hundred numbers per track would add roughly 800 characters of
    text to parse for every track in the library, which would make startup slow
    for no benefit. As bytes in this file it costs 200 bytes and is read only
    when a track is actually selected.
    """
    frame_count = band_energies.shape[0]
    onset_count = len(onset_frame_indices)

    header = bytearray()
    header += ANALYSIS_FILE_MAGIC
    header.append(ANALYSIS_FILE_VERSION)
    header.append(ANALYSIS_FRAMES_PER_SECOND)
    header.append(ANALYSIS_BAND_COUNT)
    header.append(len(waveform))
    header += frame_count.to_bytes(4, "big")
    header += onset_count.to_bytes(4, "big")

    onset_bytes = bytearray()
    for onset_frame in onset_frame_indices:
        onset_bytes += min(onset_frame, 65535).to_bytes(2, "big")

    with open(destination_path, "wb") as analysis_file:
        analysis_file.write(bytes(header))
        analysis_file.write(band_energies.tobytes())
        analysis_file.write(bytes(onset_bytes))
        analysis_file.write(waveform.tobytes())


# ---------------------------------------------------------------------------
# Artwork
# ---------------------------------------------------------------------------

def crop_to_square_and_resize(source_image, output_size):
    """
    Turn any artwork into a square greyscale image at the size we want.

    The crop is centred, so non-square artwork loses its edges rather than being
    stretched out of shape.
    """
    image_in_greyscale = source_image.convert("L")

    width, height = image_in_greyscale.size
    square_side = min(width, height)
    left_edge = (width - square_side) // 2
    top_edge = (height - square_side) // 2
    cropped_to_square = image_in_greyscale.crop(
        (left_edge, top_edge, left_edge + square_side, top_edge + square_side)
    )

    return cropped_to_square.resize((output_size, output_size), Image.LANCZOS)


def dither_artwork_to_png(source_image, destination_png_path):
    """
    Convert album artwork to the full size 1-bit image the now playing screen
    shows.

    Floyd Steinberg dithering, which is what PIL's convert("1") does by default.
    At 140 pixels there are enough dots to carry a continuous tone, so dithered
    artwork on this screen reads like newsprint halftone, which looks deliberate
    rather than like a compromise.
    """
    resized = crop_to_square_and_resize(source_image, ALBUM_ART_SIZE)
    resized.convert("1").save(destination_png_path)


def reduce_artwork_to_thumbnail_png(source_image, destination_png_path):
    """
    Convert album artwork to the smaller 1-bit cover the album list shows.

    How small the thumbnail is decides which method works, and the answer is not
    the same at every size, which is worth recording because it is not obvious.

    The album list originally showed five rows and had room for a 36 pixel
    cover. At 36 pixels error diffusion has nowhere near enough dots to average
    out, and every photographic cover came out as noise that read as texture
    rather than as a picture. Four approaches were compared at six times
    magnification, and the only readable one threw the tone away entirely:
    stretch the contrast, blur slightly, then threshold hard at mid grey, which
    reduces the cover to a silhouette.

    The list now shows three rows and has room for 60 pixels, and at that size
    the comparison comes out the other way round. There are enough dots for
    dithering to carry real tone, faces are recognisable, and lettering on a
    cover is legible as lettering. The silhouette method looks blobby beside it.

    So this is a plain Floyd Steinberg dither, with the contrast stretched
    first. The stretch is what separates it from the full size image: a cover
    shot in a narrow range of greys has that range spread over the whole scale,
    which matters far more at 60 pixels than at 140 because there are fewer dots
    to spend on the difference between one dark grey and another.
    """
    resized = crop_to_square_and_resize(source_image, ALBUM_THUMBNAIL_SIZE)

    # A small cutoff throws away the extreme two percent at each end, so one
    # stray highlight or shadow does not set the scale for the whole picture.
    stretched = ImageOps.autocontrast(resized, cutoff=2)

    stretched.convert("1").save(destination_png_path)


# ---------------------------------------------------------------------------
# Scanning the source tree
# ---------------------------------------------------------------------------

def find_albums(source_folder):
    """
    Walk the source tree and return one entry per album.

    An album is any folder that directly contains audio files. The artist is
    taken from the parent folder name as a starting point, though tags and the
    sidecar can override it. This means both a flat folder of songs and a
    properly organised artist and album tree will work.
    """
    music_root = source_folder / "music"
    if not music_root.exists():
        music_root = source_folder

    albums = []

    for current_folder, _subfolders, filenames in os.walk(music_root):
        folder_path = Path(current_folder)

        audio_files = sorted(
            folder_path / filename
            for filename in filenames
            if Path(filename).suffix.lower() in SOURCE_AUDIO_EXTENSIONS
        )
        if not audio_files:
            continue

        # Guess the artist from the folder above this one, when there is one.
        parent_folder_name = folder_path.parent.name
        guessed_artist = parent_folder_name if folder_path.parent != music_root.parent else "Unknown Artist"

        albums.append({
            "folder": folder_path,
            "audio_files": audio_files,
            "guessed_album": folder_path.name,
            "guessed_artist": guessed_artist,
        })

    return albums


# ---------------------------------------------------------------------------
# Writing library.lua
# ---------------------------------------------------------------------------

def write_library_index(destination_path, albums, playlists):
    """
    Write the library index the app loads at startup.

    This is JSON, read on the device with playdate.datastore.read("library").
    An earlier attempt used a Lua source file, on the assumption that the app
    could execute it directly. It cannot: playdate.file.run only runs compiled
    .pdz files, and even a compiled one is resolved against the game bundle
    rather than the data folder, so a file produced by this tool is unreachable
    that way. datastore is the mechanism the SDK provides for exactly this.

    The index deliberately holds only metadata. Bulk per-track data such as the
    waveform and the spectrum lives in the binary analysis files, so that
    startup stays fast no matter how large the library grows.
    """
    index = {
        "version": 3,
        "albumCount": len(albums),
        "albums": [],
    }

    for album in albums:
        album_entry = {
            "title": album["title"],
            "artist": album["artist"],
            "tracks": [],
        }
        if album.get("year"):
            album_entry["year"] = album["year"]
        if album.get("art_path"):
            album_entry["art"] = album["art_path"]

        for track in album["tracks"]:
            track_entry = {
                "title": track["title"],
                "file": track["audio_path"],
                "duration": round(track["duration"], 2),
                "analysis": track["analysis_path"],
            }
            if track.get("bpm"):
                track_entry["bpm"] = track["bpm"]
            album_entry["tracks"].append(track_entry)

        index["albums"].append(album_entry)

    # Playlists carry the converted paths of the tracks they name and nothing
    # else. No titles, no durations, no artwork: the app looks those up from the
    # album the track already belongs to, so a playlist cannot drift out of step
    # with the library and costs a few dozen bytes a track rather than a few
    # hundred.
    if playlists:
        index["playlists"] = [
            {"name": playlist["name"], "tracks": playlist["tracks"]}
            for playlist in playlists
        ]

    destination_path.write_text(
        json.dumps(index, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    argument_parser = argparse.ArgumentParser(
        description="Convert a music folder into Spindle's Playdate data format."
    )
    argument_parser.add_argument("source", type=Path, help="Folder containing your music")
    argument_parser.add_argument("output", type=Path, help="Folder to write the Playdate data into")
    argument_parser.add_argument(
        "--sdk",
        type=Path,
        default=Path.home() / "Developer" / "PlaydateSDK",
        help="Playdate SDK location, used to find pdc",
    )
    argument_parser.add_argument(
        "--only",
        choices=["artwork", "analysis"],
        default=None,
        help=(
            "Rebuild one part of the output and leave the rest alone. A full "
            "run reconverts every track, which is a gigabyte of copying when "
            "all that changed was the pictures or the spectrum data. Neither "
            "mode rewrites library.json, because neither one gathers "
            "everything a complete index needs."
        ),
    )
    arguments = argument_parser.parse_args()

    rebuilding_artwork_only = arguments.only == "artwork"
    rebuilding_analysis_only = arguments.only == "analysis"

    playdate_compiler = arguments.sdk / "bin" / "pdc"
    if not playdate_compiler.exists():
        print(f"Could not find pdc at {playdate_compiler}", file=sys.stderr)
        return 1

    if not arguments.source.exists():
        print(f"Source folder does not exist: {arguments.source}", file=sys.stderr)
        return 1

    albums = find_albums(arguments.source)
    if not albums:
        print(f"No audio files found under {arguments.source}", file=sys.stderr)
        return 1

    track_total = sum(len(album["audio_files"]) for album in albums)
    if arguments.only:
        print(f"Found {len(albums)} album(s), {track_total} track(s). "
              f"Rebuilding {arguments.only} only.", flush=True)
    else:
        print(f"Found {len(albums)} album(s), {track_total} track(s)", flush=True)

    # Everything that needs converting is gathered into one staging folder so
    # pdc can be run a single time over the whole batch. pdc flattens its
    # output, so staging filenames are made unique up front and mapped back to
    # their final destinations afterwards.
    staging_folder = Path(tempfile.mkdtemp(prefix="spindle-ingest-"))
    staging_source = staging_folder / "Source"
    staging_source.mkdir()
    (staging_source / "pdxinfo").write_text("name=staging\nbundleID=com.example.staging\n")
    (staging_source / "main.lua").write_text("-- staging only\n")

    conversion_plan = []
    processed_albums = []

    # Where each source file ended up, so a playlist naming that source file can
    # be pointed at the converted track afterwards. Keyed by resolved absolute
    # path, with a second index by bare filename for playlists written against a
    # library that lives somewhere else.
    tracks_by_source_path = {}
    tracks_by_filename = {}

    try:
        for album in albums:
            sidecar = read_album_sidecar(album["folder"])
            first_track_tags = read_tags_with_mutagen(album["audio_files"][0])

            album_title = sidecar.get("album") or first_track_tags.get("album") or album["guessed_album"]
            album_artist = (
                sidecar.get("artist")
                or first_track_tags.get("album_artist")
                or first_track_tags.get("artist")
                or album["guessed_artist"]
            )
            album_year = sidecar.get("year") or first_track_tags.get("year")
            album_slug = make_filesystem_slug(f"{album_artist}-{album_title}")

            print(f"\n  {album_artist} / {album_title}", flush=True)

            # Work out the track order, honouring the sidecar if it listed one.
            ordered_audio_files = album["audio_files"]
            if "track_order" in sidecar:
                by_filename = {path.name: path for path in album["audio_files"]}
                ordered_from_sidecar = [
                    by_filename[name] for name in sidecar["track_order"] if name in by_filename
                ]
                remaining = [path for path in album["audio_files"] if path not in ordered_from_sidecar]
                ordered_audio_files = ordered_from_sidecar + remaining

            # Artwork, converted once per album rather than once per track.
            album_art_path = None
            artwork_image = None
            if not rebuilding_analysis_only:
                artwork_image = find_album_artwork(album["folder"], ordered_audio_files[0])
            if artwork_image is not None:
                # The full size image for the now playing screen.
                dither_artwork_to_png(
                    artwork_image,
                    staging_source / f"art-{album_slug}.png",
                )
                album_art_path = f"art/{album_slug}.pdi"
                conversion_plan.append({
                    "staged_name": f"art-{album_slug}.pdi",
                    "final_relative_path": album_art_path,
                })

                # The thumbnail for the album list. The app finds it by adding
                # "-thumb" to the full image's path, so the index does not need
                # to carry a second path for every album.
                reduce_artwork_to_thumbnail_png(
                    artwork_image,
                    staging_source / f"art-{album_slug}-thumb.png",
                )
                conversion_plan.append({
                    "staged_name": f"art-{album_slug}-thumb.pdi",
                    "final_relative_path": f"art/{album_slug}-thumb.pdi",
                })

                print(f"      artwork dithered to {ALBUM_ART_SIZE}x{ALBUM_ART_SIZE} "
                      f"and {ALBUM_THUMBNAIL_SIZE}x{ALBUM_THUMBNAIL_SIZE}")
            elif not rebuilding_analysis_only:
                print("      no artwork found")

            # In artwork only mode nothing below this point is wanted: the
            # audio, the analysis and the index are all left exactly as they
            # are, and only the pictures are rebuilt.
            if rebuilding_artwork_only:
                continue

            processed_tracks = []

            for track_index, audio_file in enumerate(ordered_audio_files, start=1):
                track_tags = read_tags_with_mutagen(audio_file)
                track_title = track_tags.get("title") or audio_file.stem

                # The track slug is short because the album folder already
                # supplies the context. Someone browsing the data folder over
                # USB should see "06-sabotage.pda" inside the album folder
                # rather than the album name repeated on every file.
                track_slug = make_filesystem_slug(f"{track_index:02d}-{track_title}")

                # pdc flattens its output into a single folder, so the staged
                # filename has to be unique across the whole run even though
                # the final path does not.
                staging_unique_slug = f"{album_slug}-{track_slug}"

                print(f"      {track_index:2d}. {track_title}", flush=True)

                # Convert the audio into the staging folder for pdc. An analysis
                # only run skips this, which is the whole point of it: the
                # conversion is nearly all of the time and all of the gigabyte,
                # and the analysis is computed from the original file anyway.
                final_audio_path = f"music/{album_slug}/{track_slug}.pda"
                if not rebuilding_analysis_only:
                    staged_wav_name = f"audio-{staging_unique_slug}.wav"
                    convert_to_adpcm_wav(audio_file, staging_source / staged_wav_name)
                    conversion_plan.append({
                        "staged_name": f"audio-{staging_unique_slug}.pda",
                        "final_relative_path": final_audio_path,
                    })

                # Analyse the original file rather than the ADPCM version, so
                # the spectrum reflects the source rather than the compression.
                mono_samples = decode_to_mono_samples(audio_file)
                band_energies, spectrum_history = compute_band_energies(mono_samples)
                onset_frames, estimated_bpm = detect_beats(spectrum_history)
                waveform = compute_waveform_envelope(mono_samples)

                # Analysis mirrors the music folder structure for the same
                # reason, so a track and its analysis sit at matching paths.
                analysis_relative_path = f"analysis/{album_slug}/{track_slug}.bin"
                analysis_destination = arguments.output / analysis_relative_path
                analysis_destination.parent.mkdir(parents=True, exist_ok=True)
                write_analysis_file(analysis_destination, band_energies, onset_frames, waveform)

                # Remember where this source file ended up, for playlists.
                resolved_source = audio_file.resolve()
                tracks_by_source_path[resolved_source] = final_audio_path
                tracks_by_filename.setdefault(audio_file.name, []).append(final_audio_path)

                # Reading the duration is a separate probe of the source file,
                # and it is only ever used to write the index. An analysis only
                # run does not write the index, so there is no reason to spend
                # one probe per track finding out something nobody will read.
                if not rebuilding_analysis_only:
                    processed_tracks.append({
                        "title": track_title,
                        "audio_path": final_audio_path,
                        "analysis_path": analysis_relative_path,
                        "duration": get_audio_duration_seconds(audio_file),
                        "bpm": estimated_bpm,
                    })

            processed_albums.append({
                "title": album_title,
                "artist": album_artist,
                "year": album_year,
                "art_path": album_art_path,
                "tracks": processed_tracks,
            })

        # The index is plain JSON read by playdate.datastore, so it does not
        # go through pdc at all. Neither partial rebuild may touch it, because
        # neither one gathers all of the durations, analysis paths and artwork
        # paths that a complete index needs.
        processed_playlists = []
        if not arguments.only:
            for playlist in find_playlists(arguments.source):
                resolved_tracks = []
                missing = 0

                for listed_path in playlist["listed_paths"]:
                    track_path = resolve_playlist_track(
                        listed_path, playlist["folder"], arguments.source,
                        tracks_by_source_path, tracks_by_filename)
                    if track_path:
                        resolved_tracks.append(track_path)
                    else:
                        missing += 1

                if resolved_tracks:
                    processed_playlists.append({
                        "name": playlist["name"],
                        "tracks": resolved_tracks,
                    })
                    note = f", {missing} not found" if missing else ""
                    print(f"  playlist {playlist['name']}: "
                          f"{len(resolved_tracks)} track(s){note}")
                else:
                    print(f"  playlist {playlist['name']}: no tracks resolved, skipped",
                          file=sys.stderr)

        if not arguments.only:
            write_library_index(arguments.output / "library.json",
                                processed_albums, processed_playlists)

        # One pdc pass converts every staged WAV into .pda and every staged PNG
        # into .pdi. An analysis only run stages nothing, since the analysis
        # files are written directly, so there is nothing for pdc to do.
        if conversion_plan:
            print("\n  Running pdc over the staged files...")
            staging_output = staging_folder / "out.pdx"
            run_command(
                [str(playdate_compiler), str(staging_source), str(staging_output)],
                "pdc conversion",
            )

            # Move each converted file from pdc's flat output into its final home.
            print("  Moving converted files into place...")
            for planned_file in conversion_plan:
                converted_source = staging_output / planned_file["staged_name"]
                if not converted_source.exists():
                    print(f"    warning: pdc did not produce {planned_file['staged_name']}",
                          file=sys.stderr)
                    continue
                final_destination = arguments.output / planned_file["final_relative_path"]
                final_destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(converted_source), str(final_destination))

    finally:
        shutil.rmtree(staging_folder, ignore_errors=True)

    if rebuilding_artwork_only:
        print(f"\nDone. {len(conversion_plan)} artwork file(s) rebuilt in "
              f"{arguments.output / 'art'}")
        return 0

    if rebuilding_analysis_only:
        print(f"\nDone. {track_total} analysis file(s) rebuilt in "
              f"{arguments.output / 'analysis'}")
        return 0

    # Report what was produced, and how much space it takes, since that is the
    # number people actually want to know.
    total_bytes = sum(
        path.stat().st_size for path in arguments.output.rglob("*") if path.is_file()
    )
    print(f"\nDone. {len(processed_albums)} album(s), {track_total} track(s), "
          f"{total_bytes / (1024 * 1024):.1f} MB written to {arguments.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
