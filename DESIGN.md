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

## Hardware constraints

Every item here was measured on real hardware during Phase 0, not assumed.

| Finding | Consequence for the design |
|---|---|
| Audio stops when the device is locked or the system menu opens | Playback only happens with the screen on. An in-app lock is required. Resume behaviour matters more than usual |
| MP3 seeking is O(n), costing roughly 89.5 ms per second of seek target | MP3 is unusable for scrubbing. ADPCM seeks in about 1 ms |
| There is no backlight. The display is reflective memory-in-pixel | A static screen is nearly free to hold, but dropping the refresh rate only saves about 22 percent of battery, so animation is affordable |
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
  art/<album>.pdi                 album art, dithered to 1-bit
  analysis/<album>/<track>.bin    spectrum, onsets and waveform
  library.json                    the index, read once at startup
```

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
scrolls with the crank. Artists act as a filter above that list, and tracks live
inside each album.

Two ways to collect music beyond a single album:

- The queue is built on the device while browsing. You can add to it, reorder
  it, and clear it. It does not persist.
- Playlists are `.m3u` files written on the Mac and named by their filename.
  This avoids on-device text entry entirely.

## Controls

The crank is an enhancement and never a requirement. Everything it does has a
button equivalent, because plenty of people leave the crank docked all the time.

| Screen | Crank does | Buttons do |
|---|---|---|
| Library | Scrolls the list | Up and down move, A opens, B goes back |
| Now playing | Scrubs the track | Left and right change track, up opens the fullscreen visualizer, down cycles play modes |
| Fullscreen visualizer | Drives the visualizer | Left and right seek by 10 seconds, down returns |

To unlock from pocket mode, hold A and B together for two seconds while a
progress ring fills. This works regardless of whether the crank is docked, and a
pocket is very unlikely to press two specific buttons and hold them. A full
crank revolution also unlocks, for people who happen to have it extended.

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
2. Shuffle tracks, which picks random songs
3. Shuffle albums, which picks a random record and plays it through in order

Shuffle albums is the mode no other Playdate player offers, and it is the one
that suits an album-first library.

Repeat is a separate setting in the menu with three states: off, album, track.

On launch, Spindle always restores the track, position, and queue. Whether it
starts playing depends on how the previous session ended. If the device locked
or the system menu killed the audio, that was not a deliberate choice, so
playback resumes. If you backed out of the app yourself, it comes back paused.
The lifecycle callbacks `deviceWillLock` and `gameWillPause` make the two cases
distinguishable.

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

The crank can be a participant rather than just a control. No other Playdate
music player uses it for anything except scrolling, so a visualizer you can play
with is genuinely new, and it holds up to repeat viewing far better than one you
only watch.

The first batch:

| Visualizer | What it does |
|---|---|
| Chladni figures | The nodal patterns of a vibrating plate. Frequency bands drive the mode numbers, so the pattern is the spectrum expressed as physics |
| Fourier epicycles | Circles rotating on circles, each radius taken from a spectrum band. The drawing mechanism and the audio analysis are the same operation |
| Harmonograph | Two damped pendulums tracing a curve. Frequencies come from spectral peaks and the drawing restarts on a beat |
| Cellular automaton | Rule 30 or 110 scrolling upward, each new row seeded by the current spectrum. Pure 1-bit with no dithering needed |
| Boids | The crank steers an attractor the flock chases. Bass tightens cohesion, treble increases separation, beats scatter the flock |
| Moire interference | Two line grids overlaid, one rotated by the crank, spacing driven by the bands. The cheapest to draw and the most native to a 1-bit screen |
| Slime mould | Physarum agents laying pheromone trails toward a food source the crank moves |
| Spectrum and waveform | The readable one, which doubles as the scrub display |

Ideas held back for later: a gravity well, a ripple tank, an Abelian sandpile,
Langton's ant, Truchet tiles, a pendulum wave, and strange attractors.

## Features that were cut

Audiobook and podcast mode was cut. Screen-on-only playback removes most of the
reason to listen to long-form content on this device, and `setRate` only
pitch-shifts rather than time-stretching, so there is no usable speed control.
Per-file resume positions survive as a small feature that helps any long track.

MP3 support was cut. Seeking is O(n) in the seek target, which makes scrubbing
impossible. It is worth noting that no shipping Playdate music player has solved
this either. Soundpal has no seek function at all, Musik only restores saved
positions, and Kicooya documents that some MP3 files simply will not play
depending on their encoding.

## Build status

Working on hardware as of 2026-08-05:

- tools/ingest.py, converting a music folder into ADPCM audio, dithered
  artwork, precomputed spectrum and beat data, and a library.json index
- The album list and the track list inside an album, scrolling with the crank
  or the buttons
- The now playing screen with artwork, track details and the waveform scrub bar
- Crank scrubbing, which is the feature the whole ADPCM decision was for
- Gapless track transitions using the pre-warmed muted channel technique
- The three play modes

Not built yet: the queue, the visualizers beyond the waveform, pocket mode and
its lock screen, resume on launch, album artwork in the album list, and
playlist support in the ingest tool.

## Remaining unknowns

One item is still unverified, and it only affects the generative visualizer
mode: whether `channel:getDryLevelSignal()` combined with `signal:getValue()`
actually returns a usable amplitude reading. The precomputed visualizers do not
need it, since they have spectrum data to work from. It matters only for
visualizers that run without any analysis data.
