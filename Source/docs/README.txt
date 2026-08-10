SPINDLE
An album-first music player for the Playdate.


YOU ARE IN THE RIGHT PLACE

This folder is where Spindle looks for music. It is empty, which is why the
app is showing you nothing to play.

Music cannot be copied here as-is. It has to be converted on a computer
first, by the script sitting next to this file. That is not a preference:
the Playdate can play MP3, but seeking through one costs about ninety
milliseconds for every second you seek into the track, so jumping to the
three minute mark takes roughly sixteen seconds. Converting to ADPCM makes
a seek take about a millisecond, which is what makes scrubbing with the
crank possible at all.

The same script also shrinks and dithers your album art to the three sizes
the app uses, and works out the spectrum and beat data the visualizers read.


WHAT YOU NEED ON THE COMPUTER

  Python 3.9 or newer      python.org, or already installed on a Mac
  ffmpeg                   ffmpeg.org
  Pillow and mutagen       pip install pillow mutagen

ffmpeg has to be on your PATH. On a Mac, "brew install ffmpeg" does it. On
Windows, the installer or "winget install ffmpeg" does.


LAYING OUT YOUR MUSIC

One folder per album, with the tracks inside it:

  Music/
    Kind of Blue/
      01 So What.mp3
      02 Freddie Freeloader.mp3
      cover.jpg
    Remain in Light/
      01 Born Under Punches.mp3
      ...

Track order comes from the filenames, sorted, so number them. Titles and
artists come from the files' own tags. Cover art is taken from cover.jpg or
folder.jpg if either is there, and from the tags if not.

Playlists are .m3u files in a "playlists" folder beside the albums.


CONVERTING

  python3 ingest.py /path/to/your/Music /path/to/output

On Windows that is "py ingest.py" and a path like C:\Users\you\Music.

It prints what it is doing and takes a while: converting is slower than
copying, and every track is decoded once.


GETTING IT ONTO THE PLAYDATE

Copy everything the script produced into this folder, so that library.json
ends up beside this README. Then eject the Playdate and open Spindle.

If you are reading this on the device over USB, you are already in the right
folder and can copy straight into it.


IF IT STILL SHOWS NOTHING

  Nothing at all              library.json is not in this folder. Check it
                              did not land in a subfolder one level down.

  An error about library.json  The file is here but did not survive the
                              copy. Convert again and recopy.

  An album with no tracks      Those files did not convert. The script says
                              which and why as it runs.


MORE

Full instructions, including a longer Windows walkthrough, are at

  github.com/ericreinsmidt/spindle

Spindle is 0BSD licensed. Do what you like with it.
