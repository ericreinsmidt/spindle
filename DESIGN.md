# Spindle

An album-first music player for the Playdate. A listening object rather than a
pocket player.

Bundle ID: `com.reinsmidt.spindle`

## Identity

The screen has to stay on for audio to keep playing, so the display is not a
cost to be minimised. It is the point. Spindle sits on a desk or a nightstand
showing something worth looking at while a record plays, with the crank as a
tactile control you reach for rather than a novelty.

A pocket mode exists as an explicit toggle for when it is not on a desk. It is a
single switch that locks input and stops redrawing the screen. Nothing happens
automatically.

The logo is a 45 RPM adapter, drawn as a solid three-arm spider in black with
white negative space and no dithering. It survives being scaled down to 32 by 32
pixels for the launcher list. In the launcher card it rotates at an actual 45
revolutions per minute. Because the shape has three-fold rotational symmetry,
only 120 degrees of animation frames are needed before the loop repeats.

The card has no background. The launcher honours a mask on card art, which was
not obvious and had to be tried, so the adapter and the wordmark sit directly on
the launcher's own backdrop instead of on a solid rectangle. That backdrop is
exactly 50 percent black in alternating single pixel rows, measured off a
screenshot, so it reads as mid grey and solid black artwork has real contrast
against it. Both the cut out and the solid versions, in either polarity, are two
constants at the top of tools/make_launcher_art.py.

## Hardware constraints

Every item here was measured on real hardware during Phase 0, not assumed.

| Finding | Consequence for the design |
|---|---|
| Audio stops when the device is locked or the system menu opens | Playback only happens with the screen on. An in-app lock is required. Resume behaviour matters more than usual |
| MP3 seeking is O(n), costing roughly 89.5 ms per second of seek target | MP3 is unusable for scrubbing. ADPCM seeks in about 1 ms |
| There is no backlight. The display is reflective memory-in-pixel | A static screen is nearly free to hold, but dropping the refresh rate only saves about 22 percent of battery, so animation is affordable. White on black is the default, and is a system menu checkbox using `playdate.display.setInverted` because whether it reads better depends on the light you are in rather than on taste. Album art is flipped on the way in when it is on, so the display's flip on the way out cancels and a cover never shows as a negative |
| Drawing is bound by how much ink reaches the screen, not by arithmetic | Anything visual has to be timed on hardware. The Simulator runs where filling pixels is nearly free and will mislead you about which of two versions is faster |
| The SDK provides no FFT, only a per-frame amplitude level | Frequency data has to be precomputed during ingest |
| `getOffset` and `getLength` return wrong values on MP3 | Track the playhead locally. This stops mattering once everything is ADPCM |
| Calling `setVolume(0)` on a player stops it decoding | A player cannot be pre-warmed by muting it. Mute the channel it sits on instead |
| ADPCM decode leaves enormous headroom | Baseline is 7 ms per frame. The decoder does not starve until 240 ms per frame |
| Battery lasts about six hours during continuous playback | A realistic listening session, not a demo |

## Audio format and ingest

Audio ships as ADPCM in Playdate's `.pda` container, stereo, 44.1 kHz. That
works out to roughly 2.6 MB per minute, so about 25 hours of music fits on the
4 GB device. Storage is not the binding constraint, which is why stereo was
chosen over mono despite the built-in speaker being mono.

The `.pda` files have to be produced by running a WAV through `pdc`. ADPCM
stored as a plain `.wav` does not work at runtime. It loads as an object,
reports a nil length, and stays silent.

### Source layout, maintained by hand

```
music/
  Beastie Boys/
    Ill Communication/
      06 Sabotage.mp3
      _album.m3u          title, artist, year, cover filename
      cover.jpg
playlists/
  Long Drive.m3u
```

Folders define albums. The m3u sidecars carry both track order and metadata,
which keeps it to one concept instead of two. This is necessary because `.pda`
files cannot hold ID3 tags.

### Ingest output, generated

```
/Data/com.reinsmidt.spindle/
  music/<album>/<track>.pda       converted audio
  art/<album>.pdi                 album art, dithered to 1-bit at 140 px
  art/<album>-thumb.pdi           the same art at 60 px for the album list
  analysis/<album>/<track>.bin    spectrum, onsets and waveform
  library.json                    the index, read once at startup, including
                                  any playlists as lists of track paths
  session.json                    what was playing, written by the app
```

The thumbnail path is not in the index. The app derives it by adding `-thumb`
to the full image's path, which means an existing library gains thumbnails by
rebuilding the artwork alone rather than by being ingested again from scratch.
`ingest.py --only artwork` does exactly that, and leaves the audio, the analysis
files and the index untouched. `--only analysis` is the matching flag for the
other direction, which rebuilt all 122 analysis files in 54 seconds against a
full run and a gigabyte of copying.

Both sizes are Floyd Steinberg dithered, with the contrast stretched first on
the thumbnail because it has far fewer dots to spend on the difference between
one dark grey and another.

How small the thumbnail is decides which method works, and the answer is not the
same at every size. The album list originally showed five rows with room for 36
pixels, and at that size error diffusion has nowhere near enough dots to average
out: every photographic cover came out as noise that read as texture rather than
as a picture. Four approaches were compared at six times magnification and the
only readable one threw the tone away entirely, reducing each cover to a
silhouette by stretching contrast, blurring slightly and thresholding hard.

The list now shows three rows with room for 60 pixels, and the comparison comes
out the other way round. There are enough dots for dithering to carry real tone,
faces are recognisable, and lettering on a cover is legible as lettering. The
silhouette method looks blobby beside it.

Startup reads a single file rather than scanning hundreds of small ones on
storage we have measured as slow. To change something, edit an m3u and re-run
ingest.

The index is JSON, read with playdate.datastore.read("library"). Two other
approaches were tried on hardware and do not work. A plain library.lua cannot
be executed, because playdate.file.run only runs compiled files. Compiling it
to library.pdz also fails, because file.run resolves paths against the game
bundle rather than the data folder, so anything the ingest tool writes is
unreachable that way.

The index holds metadata only. Bulk per-track data, meaning the spectrum, the
onset list and the waveform, lives in the binary analysis files. Two hundred
waveform values per track would add roughly 800 characters of JSON per track to
parse at startup, against 200 bytes read on demand from the analysis file. The
index currently runs to about 430 bytes per track, so a 500 track library is
roughly 215 KB.

If no index is present the app falls back to scanning folders and showing
filenames, so simply dropping `.pda` files somewhere still produces a working,
if unlabelled, library.

### Analysis performed during ingest

The Mac runs an FFT and beat detection during conversion and ships the results
alongside the audio:

```
bands[frame][1..16]     spectrum sampled at 20 frames per second
onsets[]                onset frame indices from spectral flux
waveform[]              amplitude envelope for the scrub bar
bpm                     estimated from the median gap between onsets
```

The analysis file starts with a sixteen byte header holding a magic number,
format version, frames per second, band count, waveform point count, frame
count and onset count. The band data follows as one byte per band per frame,
then the onsets as two bytes each, then the waveform as one byte per point.
Everything is big endian so the Lua side can read it with string.byte and a
loop, without depending on string.unpack being available.

On the device this costs one table lookup per frame. No CPU is spent on
analysis, the data is perfectly synchronised to the playhead, and the analysis
itself is better than the hardware could ever manage live. The build step we
originally treated as the main drawback of ADPCM is what makes this possible.

## Library

The album is the primary object. The landing screen is a list of albums that
scrolls with the crank, each row showing a cover thumbnail beside the title,
artist, year, track count and running time. Artists act as a filter above that
list, and tracks live inside each album.

Thumbnails are loaded the first time a row is drawn and then kept, so scrolling
does not reload the same picture every frame and startup does not stall reading
covers for albums nobody has scrolled to. A 60 by 60 one bit image is well under
a kilobyte, so holding one per album costs nothing at any library size that fits
on the device. They are keyed by the album itself rather than its position, so a
playlist borrowing a cover shares the one image.

Two ways to collect music beyond a single album:

- The queue is built on the device while browsing. You can add to it, reorder
  it, and clear it. It does not persist.
- Playlists are `.m3u` files written on the Mac and named by their filename.
  This avoids on-device text entry entirely.

A playlist is not an album and is deliberately not built like one. An album is a
folder of audio files that get converted; a playlist is a list of pointers at
tracks that already live in albums. Were it another folder of files, every track
on a playlist would be converted and stored a second time, and at 2.6 MB a minute
a couple of playlists would cost an album's worth of space.

So a playlist adds no audio and no analysis. The index stores only its name and
the converted paths of the tracks it names, because the title, duration and
artwork already exist on the album each track belongs to, and repeating them
would be a second copy to keep in step. A five track playlist costs 384 bytes,
about 77 a track against roughly 430 for a real track entry. The app resolves
those paths at load into exactly the shape an album produces, so nothing that
browses or plays needs to know which it is holding.

Playlists sit at the top of the same list as albums rather than behind a screen
of their own, because a playlist is another way to start a run of music and
putting it one level away would make it feel like a different kind of object than
it is. Opening one gives the same track list, with two differences: the
subheading says what it is and how long it runs, since there is no single artist
to name, and each row carries the artist after the title, because a list drawn
from several records is unreadable without it.

Paths inside an m3u are tried absolute, relative to the playlist, relative to the
source root, then relative to the music folder, and finally matched on filename
alone. That last one is what makes a playlist exported from another application
work at all, since those carry paths from a library living somewhere else. A name
matching more than one track is skipped with a warning rather than guessed at,
and a track that cannot be resolved is reported and dropped rather than taking
the playlist down with it.

## Controls

The crank is an enhancement and never a requirement. Everything it does has a
button equivalent, because plenty of people leave the crank docked all the time.

| Screen | Crank does | Buttons do |
|---|---|---|
| Library | Scrolls the list | Up and down move, A opens, B goes back |
| Now playing | Scrubs the track | Left and right change track, up opens the fullscreen visualizer, down cycles play modes, holding down cycles repeat, B goes back, holding B enters pocket mode |
| Pocket | Nothing | Everything is ignored except A and B held together for two seconds |
| Fullscreen visualizer | Drives the visualizer, except on the waveform scope where it scrubs the track | Left and right seek by 10 seconds, down returns |

To unlock from pocket mode, hold A and B together for two seconds while a
progress ring fills. A pocket is very unlikely to press two specific buttons and
hold them. A full crank revolution was an unlock as well and has been removed:
anyone pocketing the device closes the crank first, so it was a gesture for a
situation that does not arise, and it needed an idle reset alongside it to stop
partial turns accumulating over time.

Pocket mode is entered by holding B on now playing. It shares that button
because the screen has no spare one, and the system menu was the alternative and
is worse: opening it stops the audio, which is exactly the wrong thing to do at
the moment you are putting the device away with music playing.

The saving is the frames it does not draw. The screen is left exactly as it was
rather than being redrawn, which the memory-in-pixel display holds for free, and
a frame is only spent when the track rolls over or an unlock is part way
through. The refresh rate is deliberately not lowered as well: the gapless swap
happens on the frame the playhead passes the end of a track, so at ten frames a
second that is up to a tenth of a second of silence at every boundary, which is
not worth the roughly 22 percent the refresh rate is measured to be worth.

## Now playing screen

```
+-----------------------------------+
| ########   SABOTAGE               |
| #.:#:.#:   Beastie Boys           |
| #:#.#:.#   Ill Communication '94  |
| ########                          |
|              track 6 of 18        |
| ___-=#=-__-=##=-_-=#=-__-=#=-_    |
|        ^                          |
| 2:14                        2:58  |
+-----------------------------------+
```

Album art is dithered to 1-bit at 140 by 140 pixels. Halftoned artwork on this
screen looks like newsprint, which reads as a deliberate style rather than a
compromise. The scrub bar is the precomputed waveform, so you can see the shape
of the song while cranking through it and know where the quiet intro ends.

## Playback behaviour

Gapless playback is verified working on hardware. About ten seconds before the
current track ends, the next track's player is created at full volume on a
channel whose volume is set to zero. At the boundary the two channel volumes are
swapped. Two ADPCM players coexist happily, both decoding at real time, the
muted one is genuinely silent, and the swap is instant with no audible gap. Note
that the player itself must be at full volume and the channel is what gets
muted, because calling `setVolume(0)` on a player stops it decoding.

Pressing down cycles the play modes in this order:

1. In order
2. Shuffle tracks, which shuffles the record you are playing
3. Shuffle albums, which picks a random record and plays it through in order

Shuffle albums is the mode no other Playdate player offers, and it is the one
that suits an album-first library.

Repeat is a separate axis with three states: off, album, track. Shuffling
decides what order things come in and repeating decides what happens when the
list runs out, so every combination of the two is meaningful.

It is bound to holding down rather than to the system menu, which is where this
design originally put it. Opening the system menu stops the audio, and putting a
playback control behind something that silences playback is not a trade worth
making. Now playing has no free buttons left, so down carries both: a short
press cycles the play mode, and holding it for 400 milliseconds cycles repeat.
The play mode can only change on release, because until the button comes back up
there is no way to tell which of the two was meant.

Repeat track means "play this again when it ends" and not "disable the next
button", so pressing next still moves on. That distinction is the only thing the
advance logic needs to know about who asked for the next track.

On launch, Spindle restores the album, the track, the position, the play mode
and the repeat mode. Whether it starts playing depends on how the previous
session ended. If the device locked, the system menu killed the audio, or the
battery gave out, that was not a deliberate choice, so playback resumes. If you
backed out of the app yourself, it comes back paused.

`gameWillTerminate` is what separates the two. It fires on a deliberate exit and
does not fire when the device dies underneath the app, so the session file is
written marked as an interruption all the way through playback and only
rewritten as clean on the way out. The position is rewritten every thirty
seconds while music plays, so a flat battery costs at most half a minute rather
than the whole track.

The saved track index is checked against the file path before it is trusted,
because re-ingesting with different tags can reorder a record and the index on
its own would then restore the wrong song.

## Visualizers

Visualizers are a plugin interface rather than a set of bespoke screens. Each
one implements a single draw function and receives the same inputs:

```lua
-- bands       the current spectrum row, sixteen values
-- beat        true on frames where an onset was detected
-- bpm, energy whole-track values
-- crankDelta  degrees the crank moved since the last frame
-- position    playhead in seconds
-- length      track length in seconds
function visualizer:draw(context) end
```

Adding a file makes it appear in the picker. That is what keeps a large gallery
manageable.

The crank can be a participant rather than just a control, and a visualizer you
can play with holds up to repeat viewing far better than one you only watch.

A visualizer can also decline the crank and ask for it to be spent on scrubbing
instead, by setting `scrubsWithCrank`. Only the waveform scope does, because it
is the one that shows where you are in a song rather than only what it sounds
like right now, so seeing the quiet intro end and then turning to it is the
obvious thing to want. It is declared rather than acted on so that visualizers
stay ignorant of playback: they see a context table and nothing else, and the
screen is what honours the request.

The first batch:

| Visualizer | What it does |
|---|---|
| Haring, a Chladni figure | The nodal patterns of a vibrating plate, traced as an interpolated contour rather than filled cells. Mode numbers follow the spectrum continuously with a slow drift on top. Line width comes from the local steepness of the plate, so the figure swells where nodal lines converge, between 10 and 34 pixels, with loudness widening the whole thing |
| Spirograph, a harmonograph | Two damped pendulums tracing a curve, frequencies taken from spectral peaks. The only one driven entirely by the crank: the pen goes as far as you wind it and winding back retracts the line, which needs the figure to be a pure function of pen position rather than a trail of collected points, because a trail is history and history cannot be wound backwards |
| Triforce, a cellular automaton | Rule 30 or 110 scrolling upward, each new row seeded by the current spectrum. Pure 1-bit with no dithering needed |
| Koi, a boids flock | The crank steers an attractor the flock chases. Bass tightens cohesion, treble increases separation, beats scatter the flock |
| Garden o' Sound, a moire | Two line grids overlaid, one rotated by the crank, spacing driven by the bands. The cheapest to draw and the most native to a 1-bit screen |
| Slime, a physarum colony | Physarum agents laying pheromone trails toward a food source the crank moves |
| Spectrum, and Maigasa which is the same bands around a circle | The readable ones, for when the others are being decorative |

Ideas held back for later: a gravity well, a ripple tank, an Abelian sandpile,
Langton's ant, Truchet tiles, a pendulum wave, and strange attractors.

## Features that were cut

Audiobook and podcast mode was cut. Screen-on-only playback removes most of the
reason to listen to long-form content on this device, and `setRate` only
pitch-shifts rather than time-stretching, so there is no usable speed control.
Per-file resume positions survive as a small feature that helps any long track.

MP3 support was cut. Seeking is O(n) in the seek target, which makes scrubbing
impossible. Before accepting that, other Playdate music players were looked at to
check whether this was a limit of the platform or a mistake in our own use of it.
None of them scrub either, which is what settled it: the constraint is the SDK's
MP3 decoder, not anything we were doing wrong.

The queue was cut, after playlists shipped and after living with the app for a
while. It was in this document from the start, so the reasoning is worth keeping
rather than quietly deleting the line.

It argues against the premise. Everything else here pushes toward the album:
albums are the landing screen, picking a track plays the whole record, shuffle
albums is the mode nothing else offers. A queue is a track-first construct, built
so you can assemble a sequence of individual songs, which is the thing this
deliberately is not.

Playlists cover the durable case and cover it better, because they are written on
a machine with a keyboard and a real screen, and they persist.

It was also the most expensive thing left, and expensive in interaction rather
than in code: a screen of its own, add and reorder and clear, an insertion point
relative to whatever is playing, and correct behaviour against three play modes
and three repeat modes. Getting playback order subtly wrong is the kind of fault
you notice three tracks later.

The input budget settles it. Now playing has nothing free. A pauses, B goes back
with a hold for pocket mode, up opens the visualizer, down cycles play mode with
a hold for repeat, left and right change track, and the crank scrubs. Two
controls already hide behind holds. A third would be undiscoverable.

The one want a playlist cannot serve is the spontaneous one: playing a record and
wanting a particular other song after it. If that turns out to matter in real
use, the small version is play next as a single action on a hold of A in the
track list, kept as its own short list that nextPlaybackPosition drains before
continuing through the album, which also makes it immune to shuffle. No screen,
no reorder, no clear, because it empties itself. That is worth building when the
want appears, and not before.

## Build status

Working on hardware as of 2026-08-05.

Ingest, in tools/ingest.py. Converts a music folder into ADPCM .pda audio,
1-bit dithered .pdi artwork, binary analysis sidecars holding spectrum, onsets
and waveform, and a library.json index. Reads tags with mutagen across MP3,
FLAC, M4A and the rest, honours an optional _album.m3u sidecar for overrides
and track order, and finds artwork either beside the audio or embedded in it.
Roughly one second per track.

The app. Album list with cover thumbnails and track list, scrolling with the
crank or the buttons. Now playing with artwork, a compact spectrum, and the
precomputed waveform as the scrub bar with a playhead marker. Crank scrubbing.
Gapless transitions. Three play modes and three repeat modes. Resume on launch.
Ten visualizers behind a plugin interface, reached with up from now playing.

Launcher art, generated by tools/make_launcher_art.py from a photograph of a
45 RPM adapter. Sixty frames covering the 120 degrees of the shape's rotational
symmetry, turning clockwise about the shape's centroid.

Everything in this document is built. The queue was cut, for the reasons
recorded above.

Performance. Most visualizers run at 25 to 30 fps against a 30 fps target.
Chladni originally ran at 6, because two sine lookups sat inside the inner loop
and were being recomputed once per column for every row. It was rewritten to
hoist those, then rewritten again to trace the contour rather than fill cells.

It has since been through a longer round of work, measured on hardware at every
step, and the numbers are worth keeping because two of the three predictions
made along the way were wrong.

    uniform width, cell 8                         36.2 ms    27 fps
    gradient width 10 to 26, cell 10              41.0 ms    21 fps
    gradient width 10 to 34, cell 14, smoothed    31.6 ms    30 fps

The middle row is the lesson. Deriving the width from the local gradient was
predicted to be cheaper on the strength of a Simulator benchmark, and on the
device it was 13 percent worse. The Simulator runs on a host where filling
pixels is nearly free, so it was measuring the Lua arithmetic, while the device
is bound by how much ink ends up on the screen. Black coverage had gone from 17.7
to 32.6 percent.

The recovery came from the grid rather than from the widths. At identical widths,
cell 10 to cell 14 saved 31 percent, while narrowing the lines at a fixed cell
size saved only 4 to 8 percent for a figure that looked much lighter. That is the
signature of overdraw: each cell draws its own round capped segment, and a cap
reaches half a line width past each end, so with cells closer together than the
caps are wide, most of that ink is the same pixels being filled repeatedly.

A second attempt to predict, this time with a cost model calibrated on two device
measurements, failed its own calibration and was thrown away rather than trusted.
Anything that matters here gets measured on hardware.

## Remaining unknowns

One item is still unverified, and it only affects the generative visualizer
mode: whether `channel:getDryLevelSignal()` combined with `signal:getValue()`
actually returns a usable amplitude reading. The precomputed visualizers do not
need it, since they have spectrum data to work from. It matters only for
visualizers that run without any analysis data.

The visualizer timing report was previously listed here as unverified, because
`visualizer-timings.txt` never appeared in the data folder. Writing to that
folder with `playdate.file.open` has since been shown to work, by using the same
call to write a trace file during the session testing, so the mechanism itself is
sound. The report now records what happened on each attempt and the timing
overlay shows it, including the size of the file it wrote, so a failure is
visible on screen instead of being something you only discover afterwards by
going to look for a file that is not there.
