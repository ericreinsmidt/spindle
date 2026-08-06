# Spindle

An album-first music player for the Playdate.

Music is prepared on a Mac by an ingest tool that converts audio to ADPCM,
dithers album art to 1-bit, and precomputes spectrum and beat data. The device
reads a single index at startup and does no scanning of its own.

The design, and the hardware measurements it rests on, are in
[DESIGN.md](DESIGN.md).

## Why there is a build step

The Playdate cannot usefully seek an MP3. Seeking is a linear scan costing
roughly 89.5 milliseconds per second of seek target, measured on hardware, so
jumping four minutes into a track blocks for about twenty seconds and trips the
run loop stall detector. ADPCM seeks in about one millisecond, which is what
makes crank scrubbing possible at all.

ADPCM in Playdate's `.pda` container cannot carry ID3 tags, and the SDK provides
no FFT. So metadata and frequency analysis both have to be prepared in advance.
That turned out to be an advantage rather than a cost: the analysis can be far
better than anything the device could compute live, which is what the
visualizers run on.

## Layout

```
Source/            the Lua app
  main.lua           entry point and screen routing
  library.lua        loads the index, builds playback lists
  analysis.lua       reads the binary spectrum and beat files
  player.lua         playback, seeking, gapless transitions
  session.lua        remembers what was playing across launches
  screen_*.lua       the three screens
  visualizers.lua    plugin registry and the per frame context
  viz_*.lua          the visualizers themselves
  launcher/          generated launcher art
tools/
  ingest.py              music folder in, Playdate data out
  make_launcher_art.py   generates the launcher art from assets/
assets/            source artwork
notes/             raw logs from the hardware investigation
```

## Building

Requires the Playdate SDK at `~/Developer/PlaydateSDK`, or set
`PLAYDATE_SDK_PATH`.

```
./build.sh            compile only
./build.sh sim        compile and open in the Simulator
./build.sh device     compile and copy to a Playdate in data disk mode
```

## Preparing music

```
python3 tools/ingest.py <music folder> <output folder>
```

The source folder holds one folder per album. Track order and metadata come
from the files' own tags, and an optional `_album.m3u` sidecar can override
them:

```
music/
  Beastie Boys/
    Ill Communication/
      06 Sabotage.mp3
      cover.jpg          optional, otherwise embedded art is used
      _album.m3u         optional
```

Copy the result into `/Data/com.reinsmidt.spindle/` on the device.

Ingest needs `ffmpeg` on the path, plus `numpy`, `Pillow` and `mutagen`.

To rebuild only the album artwork, leaving the converted audio, the analysis
files and the index alone:

```
python3 tools/ingest.py --artwork-only <music folder> <output folder>
```

A full run reconverts every track, which is an hour of work and a gigabyte of
copying when all that changed was the pictures. After an artwork only run,
copying `art/` to the device is enough.

## Regenerating the launcher art

```
python3 tools/make_launcher_art.py
```

Reads `assets/adapter-45rpm.webp` and writes the icon, the card, and the frames
for the rotating card animation. The generated files are committed so the
project builds without running this first.
