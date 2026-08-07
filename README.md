<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/logo-dark.png">
  <source media="(prefers-color-scheme: light)" srcset="docs/logo-light.png">
  <img src="docs/logo-light.png" alt="Spindle" width="480">
</picture>

<p>
  <img alt="License: 0BSD" src="https://img.shields.io/badge/license-0BSD-7C3AED">
  <img alt="Platform: Playdate" src="https://img.shields.io/badge/platform-Playdate-FFC833">
  <img alt="Playdate SDK 3.1.1" src="https://img.shields.io/badge/Playdate%20SDK-3.1.1-FFC833">
  <img alt="Lua 5.4" src="https://img.shields.io/badge/Lua-5.4-7C3AED">
</p>

</div>

An album-first music player for the Playdate. A listening object rather than a
pocket player.

The Playdate's screen has to stay on for audio to keep playing, so the display
is not a cost to be minimized here. It is the point. Spindle is meant to sit on
a desk or a nightstand showing something worth looking at while a record plays,
with the crank as a control you reach for rather than a novelty.

<div align="center">

https://github.com/user-attachments/assets/cc334202-1a13-46ae-b45b-e2ca2f58eea3

</div>

<!--
  The demo video goes here.
  It cannot be committed, because GitHub strips <video> tags from README files
  and only plays video that lives in its own assets area. To add it: open this
  file on github.com, click the pencil, drag spindle-demo-web.mp4 onto this
  line, and commit. GitHub uploads it and leaves a URL of the form
  https://github.com/<owner>/spindle/assets/<numbers>/<uuid>

  Leave that URL bare on a line of its own. That exact form is what the renderer
  turns into a player; wrapping it in a markdown link turns it back into a link.
-->

## What it does

**Albums, not files.** The landing screen is a list of records with their cover
art, three to a screen, scrolled with the crank or the buttons. Opening one
shows its tracks. Picking a track plays the whole album from there rather than
that song on its own, because that is how a record works.

**Crank scrubbing.** On the now playing screen the crank moves the playhead, and
the bar it moves along is the track's own waveform rather than a plain line. You
can see the shape of a song while moving through it, so finding the point where
a quiet intro ends is something you aim at rather than hunt for. Seeking costs
about a millisecond, which is what makes this possible at all.

**Nine visualizers**, full screen, reached with up from now playing and stepped
through with up again. Eight of them do something with the crank: it steers a
flock, winds a drawing machine forward and back, rotates a moire grid, tears the
album cover apart a strip at a time. The ninth is a plain spectrum, which
deliberately ignores it.

**Gapless transitions.** The next track is opened ten seconds early and left
decoding on a silent channel, so the boundary is a swap between two players that
are both already running rather than a file being opened.

**Playlists**, written as ordinary `.m3u` files on your Mac. They appear above
the albums in the same list and play the same way. They are pointers at tracks
already in the library rather than second copies of them, so a playlist costs
about eighty bytes a track instead of several megabytes.

**Three play modes and three repeat modes.** Play modes are in order, shuffle
tracks, which shuffles the record you are on, and shuffle albums, which plays the
current record in order and then puts on another one at random. Repeat modes are
off, album and track.

The two are separate settings but they are not independent, and the repeat mode
wins where they disagree. Repeat track replays the current track at every
boundary, which means the play mode has nothing left to decide. Repeat album
restarts the current record when it ends, which beats shuffle albums putting on
a different one, on the grounds that asking for this record again is a more
specific request than asking for any record next.

**Resume on launch.** It comes back to the track and the position it left, and
whether it starts playing again depends on how the last session ended. Quitting
deliberately comes back paused; a flat battery or a lock comes back playing.

**Pocket mode**, on a hold of B. Input is ignored and the screen stops being
redrawn while the music keeps going. A and B held together for two seconds
unlocks it, with a ring filling to show the hold registering.

## Requirements

**On the Playdate**, nothing beyond the device itself. Everything is prepared in
advance and the app does no work on startup beyond reading one index file.

**On a Mac**, to convert your music:

| | |
|---|---|
| Python 3 | with `numpy`, `Pillow` and `mutagen` |
| ffmpeg | supplies both `ffmpeg` and `ffprobe`, which must be on your `PATH` |
| Playdate SDK | for `pdc`, which is the only thing that can produce the `.pda` audio and `.pdi` image formats |

```bash
brew install ffmpeg
pip3 install numpy Pillow mutagen
```

The SDK is expected at `~/Developer/PlaydateSDK`. Set `PLAYDATE_SDK_PATH` if
yours is somewhere else, or pass `--sdk` to the ingest tool.

Of the three Python packages, `mutagen` is the one you could technically do
without. Ingest catches its absence and carries on, but without it no tags can
be read, so every track falls back to its filename and every album needs a
`cover.jpg` beside it. Install it.

## Preparing your music

One folder per album. Track order and titles come from the files' own tags.

```
music/
  Beastie Boys/
    Ill Communication/
      06 Sabotage.mp3
      cover.jpg          optional, otherwise embedded artwork is used
      _album.m3u         optional, overrides the tags and sets the track order
playlists/
  Long Drive.m3u         optional
```

Anything ffmpeg can decode works as a source: MP3, FLAC, M4A, WAV.

```bash
python3 tools/ingest.py <music folder> <output folder>
```

That converts every track to ADPCM, dithers each cover to 1-bit at three sizes,
runs an FFT and beat detection over every track, and writes a single index:

```
music/<album>/<track>.pda      the audio
art/<album>.pdi                the cover at 140 px, for now playing
art/<album>-thumb.pdi          the same at 60 px, for the album list
art/<album>-full.pdi           the same at 240 px, for the Sleeve visualizer
analysis/<album>/<track>.bin   spectrum, onsets and waveform
library.json                   the index, read once at startup
```

Copy that whole folder into `/Data/com.reinsmidt.spindle/` on the device.

A full run reconverts everything, which is a gigabyte of copying if all you
changed was a picture. Two flags rebuild one part and leave the rest alone:

```bash
python3 tools/ingest.py --only artwork  <music folder> <output folder>
python3 tools/ingest.py --only analysis <music folder> <output folder>
```

Rebuilding all 122 analysis files in the test library took 54 seconds and 9.2 MB
of copying. Neither flag rewrites `library.json`, because neither one gathers
everything a complete index needs.

### Playlists

A playlist is an `.m3u` naming tracks that already live in your albums. Paths
inside it are tried absolute, then relative to the playlist, then relative to
the source root, then relative to the music folder, and finally matched on
filename alone, so a playlist exported from another application generally works
without editing. Anything that cannot be resolved is reported and skipped rather
than taking the playlist down with it.

## Installing the app

Requires the Playdate SDK. Set `PLAYDATE_SDK_PATH` if it is not at
`~/Developer/PlaydateSDK`.

```bash
./build.sh              # compile to Spindle.pdx
./build.sh sim          # compile and open in the Simulator
./build.sh device       # compile, mount a connected Playdate, and copy it across
```

`./build.sh device` puts the device into data disk mode over USB by itself, so
the only manual step is the cable. It copies the app but not your music; the
ingest output goes across separately as above.

## Controls

One row per control, rather than one row per screen, because now playing has
eight of them and cramming those into a single cell was what made the table
unreadable.

| Screen | Control | What it does |
|---|---|---|
| Album list | Crank, or up and down | Move through the list |
| | A | Open the album or playlist |
| | B | Jump to what is playing |
| Track list | Crank, or up and down | Move through the tracks |
| | A | Play the album from this track on |
| | B | Back to the album list |
| Now playing | Crank | Scrub the track |
| | A | Pause and resume |
| | Left, right | Previous and next track |
| | Up | Open the visualizers |
| | Down | Cycle play mode |
| | Hold down | Cycle repeat mode |
| | B | Back to the album list |
| | Hold B | Pocket mode |
| Visualizers | Crank | Drives whichever one is showing |
| | A | Pause and resume |
| | Left, right | Seek ten seconds |
| | Up | Next visualizer |
| | Down, or B | Back to now playing |
| Pocket | Anything | Ignored |
| | A and B together, two seconds | Unlock |

## Why there is a build step

The Playdate cannot usefully seek an MP3. Seeking is a linear scan costing
roughly 89.5 milliseconds per second of seek target, measured on hardware, so
jumping four minutes into a track blocks for about twenty seconds and trips the
run loop's stall detector. ADPCM seeks in about one millisecond, which is what
makes crank scrubbing possible at all.

ADPCM in Playdate's `.pda` container cannot carry ID3 tags, and the SDK provides
no FFT, only a single amplitude reading per frame. So both the metadata and the
frequency data have to be prepared in advance. That turned out to be an
advantage rather than a cost: the analysis can be far better than anything the
device could compute live, and it costs the device one table lookup per frame.

## Layout

```
Source/                the Lua app
  main.lua               entry point and screen routing
  library.lua            loads the index, resolves playlists
  analysis.lua           reads the binary spectrum and beat files
  player.lua             playback, seeking, gapless transitions
  session.lua            remembers what was playing across launches
  typography.lua         the two fonts and the text helpers
  artwork.lua            keeps album art out of the display inversion
  glyphs.lua             the playback state marks, as bitmaps
  screen_*.lua           the four screens
  fonts/                 copied from the SDK by build.sh, not in this repository
  visualizers.lua        plugin registry and the per frame context
  viz_*.lua              the visualizers themselves
tools/
  ingest.py              music folder in, Playdate data out
  make_launcher_art.py   launcher art, cover marks and the README logos
assets/                the drawing the launcher art is generated from
docs/                  the README logos
```

Adding a `viz_*.lua` file that registers itself is all it takes to add a
visualizer. It receives a table holding the current spectrum, whether this frame
is on a beat, how far the crank moved, the playhead, and the album, and it
knows nothing else about the app.

## Regenerating the artwork

```bash
python3 tools/make_launcher_art.py
```

Reads `assets/adapter-45rpm.png` and writes the launcher icon and card, the 60
frames of the card's rotation, the adapter marks the app draws where a cover is
missing, the two logos above, and `docs/social-banner.png`. That last one is not part of
this repository and is not shown here: it is uploaded by hand under Settings,
Social preview, and is what appears when the repository is linked elsewhere. Generated files are committed, so the project
builds without running this first.

Two constants at the top control how the launcher art comes out:
`RENDER_INVERTED` for white on black, and `RENDER_TRANSPARENT_BACKGROUND` for a
card with no background at all, which is what ships. The launcher honors a mask
on card art, so a transparent card sits directly on the launcher's own backdrop
rather than on a rectangle of its own.

## License

[0BSD](LICENSE). Do what you like with it.

That covers everything in this repository. It does not cover one thing inside a
built copy.

`Spindle.pdx` contains `fonts/Roobert-11-Bold.pft` and `Roobert-20-Medium.pft`,
compiled from fonts that belong to Panic and ship with the SDK. Building and
releasing a `.pdx` containing them is what the SDK agreement is for: it permits
distributable parts of the SDK to be incorporated into a program you have made.
What it does not permit is passing the fonts on in source form, which is why
they are not in this repository and `build.sh` copies them out of your own SDK
before each compile.

So if you download a release, the app is yours to do anything with under 0BSD,
except the two font files inside it, which remain Panic's under the SDK
agreement.

Playdate is a registered trademark of Panic. This is a personal project and is
not affiliated with or endorsed by them.
