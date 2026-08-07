Notes on the README, the artwork pipeline and the screenshots
2026-08-07

Things here that are easy to get wrong a second time.

GitHub strips style attributes from README HTML. A border on an image therefore
has to be baked into the file. The screenshots carry a 6 pixel yellow rounded
border with transparent corners, added when the images are assembled, so they
sit on either GitHub theme.

Animated GIF with transparency and frame delta optimisation fight each other if
the disposal method is wrong. With disposal 2, restore to background, every frame
has to be stored whole and now playing came to 438 KB. With disposal 1, leave in
place, the optimiser stores only the changed region and the corner transparency
survives from the first frame, which is 24 KB for the same animation. Use
disposal 1.

The screenshots are captured by the app writing its own display out a frame at a
time with playdate.simulator.writeToFile, not by recording the screen. Screen
recording is not available here. The capture harness is temporary and is removed
after each use; it lives in main.lua as a captureStep that runs instead of the
normal update, plus a Player.debugFreezeAt and a
ScreenVisualizer.debugSelectByName.

Two things that harness has to do. Drive the playhead from the frame counter
rather than the clock, because writing a PNG every frame slows the Simulator well
below thirty a second and anything reading the real clock then runs several times
too fast in the finished animation. And keep the player reporting as playing
while the playhead is frozen, or the transport glyph captures as paused.

Frames come out the way the app draws before the display inverts them, so they
have to be inverted when assembled.

The README logo is generated at 720 pixels with smooth edges, not 1-bit. Two of
them, black and white on transparent, handed to GitHub through a picture element
with prefers-color-scheme. A single black logo disappears on a dark theme and a
single white one disappears on a light theme.

make_launcher_art.py now writes five things from the one photograph: the launcher
icon and card, the 60 rotation frames, the adapter cover marks the app draws
where artwork is missing, and the two README logos. Two constants at the top,
RENDER_INVERTED and RENDER_TRANSPARENT_BACKGROUND, control the launcher art;
what ships is black artwork cut out with no background at all.
