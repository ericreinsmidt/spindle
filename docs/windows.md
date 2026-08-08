# Preparing music on Windows

Spindle's app runs on the Playdate like any other, but the music has to be
converted on a computer first. The tool that does it, `tools/ingest.py`, runs on
Windows. This is what you need and how to run it.

You do not need to build the app. Download `Spindle-1.0.zip` from
[Releases](https://github.com/ericreinsmidt/spindle/releases) and install it
either by uploading it at
[play.date/account/sideload](https://play.date/account/sideload) and fetching it
from your device's Settings, or by copying it across yourself as described at the
end of this page. Only the music conversion needs anything installed, and
`build.sh` is a shell script you can ignore entirely.

## Getting the conversion tool

`Spindle-1.0.zip` is the app and nothing else. The tool that converts your music
is the other download on the same
[release](https://github.com/ericreinsmidt/spindle/releases) page,
`spindle-tools-1.0.zip`.

Extract it anywhere. Every command below is run from inside the folder it makes:

```
cd C:\Users\you\Downloads\spindle-tools-1.0
```

Take the version that matches your app. The tools and the app agree about file
formats, and a mismatched pair is a problem you should not have to think about.

The whole repository works just as well if you would rather have it, either from
the green **Code** button and **Download ZIP**, or with
`git clone https://github.com/ericreinsmidt/spindle.git`. The layout is the same,
so every command below is unchanged.

## What you need

| | |
|---|---|
| Python 3 | with the `numpy`, `Pillow` and `mutagen` packages |
| FFmpeg | supplies `ffmpeg` and `ffprobe`, both of which must be on your `PATH` |
| Playdate SDK | supplies `pdc.exe`, the only thing that can produce the `.pda` audio and `.pdi` image formats |

The SDK is required even though you are not building anything. Playdate's audio
and image formats are made by `pdc` and by nothing else.

### Python

Any Python 3 will do; ingest uses nothing newer than f-strings.

Install from [python.org](https://www.python.org/downloads/windows/) or the
Microsoft Store. On the python.org installer's first screen, make sure **Add
python.exe to PATH** is ticked. Missing it is the single most common reason the
commands below report that `py` or `python` is not recognised.

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
winget install -e --id Gyan.FFmpeg
```

winget sets the `PATH` for you.

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
defaults to `C:\Users\<you>\Documents\PlaydateSDK`.

Unlike the macOS installer, **the Windows one does not set `PLAYDATE_SDK_PATH`
for you.** Ingest looks in the default location anyway, and also in
`OneDrive\Documents\PlaydateSDK` in case Windows has redirected your Documents
folder into OneDrive, which it often does without being asked. So if you took
the default install, it should just work.

If you installed the SDK anywhere else, either set the variable once or pass the
path each time.

To set it: open the Start menu, type "Environment Variables", open the panel,
and add a user variable named `PLAYDATE_SDK_PATH` pointing at your SDK folder.
Then close and reopen your terminal and check it took:

```
echo $env:PLAYDATE_SDK_PATH
```

To pass it instead:

```
py tools\ingest.py --sdk "D:\PlaydateSDK" <music folder> <output folder>
```

### Checking it is all there

Three commands, before pointing anything at your music. Each should print
something rather than complain:

```
py tools\ingest.py --help
ffmpeg -version
dir "$env:PLAYDATE_SDK_PATH\bin\pdc.exe"
```

The first proves Python has `numpy` and `Pillow`, since ingest imports both
before it can print anything at all. The last one only works if you set the
variable; if you did not, check the folder the installer used instead.

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
documented in the [README](../README.md#preparing-your-music). If they contain
accented characters, save them as UTF-8. Notepad's Save As dialog has an
Encoding dropdown for this.

## Converting

```
py tools\ingest.py "C:\Users\you\Music\Spindle" "C:\Users\you\Desktop\spindle-library"
```

Quote both paths. Windows user folders are full of spaces and an unquoted path
splits into two arguments.

Expect very roughly a second per track, measured on a Mac. The output is several
times the size of your source music, because ADPCM is lightly compressed rather
than heavily compressed: about 2.6 MB per minute, so a 4 GB Playdate holds
roughly twenty five hours.

Rebuilding one part without redoing everything:

```
py tools\ingest.py --only artwork  <music folder> <output folder>
py tools\ingest.py --only analysis <music folder> <output folder>
```

## Getting it onto the Playdate

Connect the Playdate by USB and put it into data disk mode, where it appears as
an ordinary drive called PLAYDATE. On the device: **Settings, System, Reboot to
Data Disk.** Holding Lock and Menu and d-pad Left together for a few seconds does
the same thing.

To leave data disk mode afterward, hold A for a few seconds.

Once the drive appears, copy in two things:

- **The music.** Everything inside your output folder goes into
  `Data\com.reinsmidt.spindle\`. That is the contents of the folder, not the
  folder itself. When it is right, the device has
  `Data\com.reinsmidt.spindle\library.json` sitting beside `music\`, `art\`
  and `analysis\`.
- **The app**, if you did not sideload it through the website. Extract
  `Spindle-1.0.zip`, which gives you a folder `Spindle-1.0` with a folder
  `Spindle.pdx` inside it. Copy **`Spindle.pdx`**, the inner one, into `Games\`.

  Copy the inner folder, not the one Explorer made. When it is right the device
  has `Games\Spindle.pdx\pdxinfo`. If it has
  `Games\Spindle.pdx\Spindle.pdx\pdxinfo`, the app will not start.

Eject the drive properly before unplugging, the same as any USB stick, then hold
A on the device to leave data disk mode.

## If something goes wrong

**"py is not recognized"** or **"python is not recognized"**: Python is not on
your `PATH`. Reinstall and tick "Add python.exe to PATH", or use the full path
to `python.exe`.

**"ffmpeg failed"** or **"ffprobe failed"**: FFmpeg is not on your `PATH`. Check
with `ffmpeg -version` in a freshly opened terminal.

**"Could not find pdc"**: the message says the exact path it looked in. If the
SDK is somewhere else, set `PLAYDATE_SDK_PATH` or pass `--sdk`. Remember that
Windows does not set that variable for you, and that a terminal opened before you
set it will not see it.

**"pdxinfo file not found"**, or the app shows its card and then dies: you have
a `Spindle.pdx` inside another `Spindle.pdx`. Extracting a zip in Explorer makes
a folder named after the zip and puts the contents inside it, so it is easy to
copy the outer one. Open `Games\Spindle.pdx\` on the device; if there is
another `Spindle.pdx` in there, move the inner one up a level and delete the
outer.

**Spindle opens on an empty library**: the converted files are in the wrong
place. Check that `Data\com.reinsmidt.spindle\library.json` exists on the device.
The usual mistake is copying the output folder itself rather than its contents.

**Accented artist or album names look wrong**: your `_album.m3u` or playlist is
not saved as UTF-8. Re-save it with UTF-8 encoding.

## What has been tested

This page has been followed from end to end on Windows: installing the three
dependencies, converting a real library of three albums and thirty seven tracks,
copying it to the device, and playing it. The files that came out were correct in
every respect that could be checked, with forward slashes throughout the index
and the right headers on the audio, artwork and analysis files.

One thing did go wrong on that run, and it is fixed. The app download used to be
called `Spindle.pdx.zip`, which Explorer extracts into a folder of the same name,
so you ended up with a `Spindle.pdx` inside a `Spindle.pdx` and the launcher
reported `pdxinfo file not found`. That is why the download is now
`Spindle-1.0.zip`.

Two branches have not been exercised: the fallback that looks for the SDK inside
a OneDrive-redirected Documents folder, and setting `PLAYDATE_SDK_PATH` by hand
for an SDK installed somewhere unusual. Both are short and both fail loudly
rather than quietly, but neither has been run.

If you hit something this page does not cover, an issue with the exact command
and the exact error is genuinely useful.
