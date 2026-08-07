The demo recorder
=================

demo.lua drives the real app through a scripted sequence of button presses and
crank movement and writes every frame out as a PNG, which tools/make_demo_video.py
then assembles into the demo video.

It lives here rather than in Source/ because it is not part of the app. Anything
in Source/ is compiled into the shipped .pdx, and a scripted input harness with
four debug accessors reaching into the library screen has no business being in
something people install.

Wiring it in takes three edits and one file copy. Undo all four afterward.

1.  Copy demo.lua into Source/

2.  In Source/main.lua, add an import beside the others:

        import "demo"

    and, at the very end of the file, after playdate.update has been defined:

        if Demo.ENABLED then
            Demo.install()
        end

    The order matters. Demo.install wraps the per frame function, so it has to
    run after that function exists.

3.  In Source/main.lua, stop the app resuming the last session, so that every
    take starts from the album list. Change:

        if Session.restore() then

    to:

        if false and Session.restore() then

    Deleting session.json by hand between takes does not work, because quitting
    writes a new one on the way out.

4.  At the end of Source/screen_library.lua, add the four accessors the recorder
    uses to scroll until it finds a record that will actually play:

        function ScreenLibrary.debugSelectedIndex()
            return selectedAlbumIndex
        end

        function ScreenLibrary.debugCollections()
            return browsableCollections()
        end

        function ScreenLibrary.debugSelectedTrackIndex()
            return selectedTrackIndex
        end

        function ScreenLibrary.debugOpenedCollection()
            return openedCollection
        end

Then build and run it in the Simulator. It writes frames to ~/spindle-demo and a
manifest into the Simulator's data folder, and stops on its own. The Simulator's
own audio during a run is meaningless: the frames are written far slower than
real time and the sound is not being recorded. See make_demo_video.py for how
the finished video gets its audio.

Two things the recorder has to do, both of which are easy to undo by accident:

Drive the clock from the frame counter rather than from playdate.getCurrentTime-
Milliseconds. Writing a PNG every frame drops the Simulator well below thirty a
second, and anything reading the real clock then runs several times too fast in
the finished video.

Never move the playhead except by playing. The finished video's sound is the
original audio file played straight through, so a crank scrub, a ten second seek
or a pause puts the picture and the sound permanently out of step from that
moment on. make_demo_video.py checks for this and says so, by comparing where
the playhead finished against how many frames went by.
