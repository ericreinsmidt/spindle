# Preparing music on Windows

Spindle's app runs on the Playdate like any other, but the music has to be
converted on a computer first. The tool that does it, `tools/ingest.py`, runs on
Windows. This is what you need and how to run it.

You do not need to build the app. Download `Spindle.pdx.zip` from
[Releases](https://github.com/ericreinsmidt/spindle/releases) and sideload it.
Only the music conversion needs anything installed, and `build.sh` is a shell
script you can ignore entirely.

## What you need

| | |
|---|---|
| Python 3 | with the `numpy`, `Pillow` and `mutagen` packages |
| FFmpeg | supplies `ffmpeg` and `ffprobe`, both of which must be on your `PATH` |
| Playdate SDK | supplies `pdc.exe`, the only thing that can produce the `.pda` audio and `.pdi` image formats |

The SDK is required even though you are not building anything. Playdate's audio
and image formats are made by `pdc` and by nothing else.

### Python

Install from [python.org](https://www.python.org/downloads/windows/) or the
Microsoft Store. During a python.org install, tick **Add python.exe to PATH** on
the first screen; it is off by default and skipping it is the single most common
reason the commands below do not work.

Then, in PowerShell or Command Prompt:

```
py -m pip install numpy Pillow mutagen
```

`py` is the Python launcher that ships with the python.org installer. If you
installed from the Microsoft Store, use `python` instead of `py` throughout.

All three packages are needed. Ingest technically survives without `mutagen`,
but then no tags can be read at all, so every track falls back to its filename
and every album needs a `cover.jpg` sitting beside it.

### FFmpeg

The easiest route is winget, which ships with Windows 11 and recent Windows 10:

```
winget install Gyan.FFmpeg
```

Close and reopen your terminal afterward so the new `PATH` takes effect, then
check both tools are visible:

```
ffmpeg -version
ffprobe -version
```

If either says it is not recognised, FFmpeg is installed but not on your `PATH`.
Scoop (`scoop install ffmpeg`) and Chocolatey (`choco install ffmpeg`) both
handle the `PATH` for you as well.

### Playdate SDK

Download from [play.date/dev](https://play.date/dev/) and run the installer. It
sets the `PLAYDATE_SDK_PATH` environment variable, which is how ingest finds it,
so nothing else is needed. Reopen your terminal after installing so the variable
is visible to it.

If ingest cannot find `pdc.exe`, point it at the SDK by hand:

```
py tools\ingest.py --sdk "C:\Users\you\Documents\PlaydateSDK" <music folder> <output folder>
```

## Laying out your music

One folder per album. Track order and titles come from the files' own tags.

```
music\
  Beastie Boys\
    Ill Communication\
      06 Sabotage.mp3
      cover.jpg          optional, otherwise embedded artwork is used
      _album.m3u         optional, overrides the tags and sets the track order
playlists\
  Long Drive.m3u         optional
```

Anything FFmpeg can decode works as a source: MP3, FLAC, M4A, WAV.

The `_album.m3u` and playlist formats are the same on every platform and are
documented in the [README](../README.md#preparing-your-music). Save them as
UTF-8 if they contain accented characters; Notepad has done that by default
since Windows 10 version 1903, but older editors may not.

## Converting

```
py tools\ingest.py "C:\Users\you\Music\Spindle" "C:\Users\you\Desktop\spindle-library"
```

Quote both paths. Windows user folders are full of spaces and an unquoted path
splits into two arguments.

Expect roughly a second per track. The output is several times the size of your
source music, because ADPCM is a lightly compressed format rather than a heavily
compressed one: about 2.6 MB per minute, so a 4 GB Playdate holds roughly
twenty five hours.

Rebuilding one part without redoing everything:

```
py tools\ingest.py --only artwork  <music folder> <output folder>
py tools\ingest.py --only analysis <music folder> <output folder>
```

## Getting it onto the Playdate

Put the device into data disk mode, where it appears as an ordinary USB drive:

```
"%PLAYDATE_SDK_PATH%\bin\pdutil.exe" list
"%PLAYDATE_SDK_PATH%\bin\pdutil.exe" <the port it listed> datadisk
```

Recent Playdate OS versions also offer this on the device itself under Settings,
if you would rather not use the command line.

Once the drive appears, copy in two things:

- `Spindle.pdx` from the release zip goes into `Games\`
- Everything inside your output folder goes into `Data\com.reinsmidt.spindle\`

That second one is the contents of the folder, not the folder itself. When it is
right, the device has `Data\com.reinsmidt.spindle\library.json` sitting beside
`music\`, `art\` and `analysis\`.

Eject the drive properly before unplugging, the same as any USB stick. The
Playdate reboots itself when you do.

## If something goes wrong

**"py is not recognized"** or **"python is not recognized"**: Python is not on
your `PATH`. Reinstall and tick "Add python.exe to PATH", or use the full path
to `python.exe`.

**"ffmpeg failed"** or **"ffprobe failed"**: FFmpeg is not on your `PATH`. Check
with `ffmpeg -version` in a freshly opened terminal.

**"Could not find pdc"**: the SDK is not installed, or `PLAYDATE_SDK_PATH` is not
set in the terminal you are using. Reopen the terminal after installing, or pass
`--sdk`.

**Spindle opens on an empty library**: the converted files are in the wrong
place. Check that `Data\com.reinsmidt.spindle\library.json` exists on the device.
The usual mistake is copying the output folder itself rather than its contents.

**Accented artist or album names look wrong**: your `_album.m3u` or playlist is
not saved as UTF-8. Re-save it with UTF-8 encoding.

## A note on what is tested

The tool is written to be platform independent and the two things that were not
have been fixed: it now looks for `pdc.exe` on Windows, and it knows the SDK's
Windows install location. Nothing else in it makes an assumption about the
operating system.

It has not been run end to end on Windows by the author, who has no Windows
machine. If you hit something this document does not cover, an issue with the
exact command and the exact error is genuinely useful.
