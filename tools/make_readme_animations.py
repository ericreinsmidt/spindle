#!/usr/bin/env python3
"""
Build the two animations the README shows, from frames the demo recorder wrote.

There are two of them and no still screenshots, because almost everything worth
seeing here moves. A photograph of a visualizer says nothing about what the crank
does to it, and a photograph of the album list says nothing about the artwork
scrolling past.

Animated WebP rather than GitHub's more usual GIF, and lossless rather than
lossy, which is the opposite of what you would reach for.

Lossy compression works by discarding detail the eye will not miss, and it
assumes a photograph. Given hard black and white edges it has nothing to discard
and instead spends its bits on ringing around every one of them, which is both
larger and worse: the visualizer montage came to 2332 KB lossy and 497 KB
lossless, and the lossless one is exact. GIF would also be exact, having only 256
colors to lose, but it has no equivalent of WebP's compression and runs several
times larger again.

The frames arrive as negatives, because the app draws for a display that inverts
everything afterward, so they are flipped here. They are also doubled in size
with nearest neighbor, since 400 by 240 is small on a web page and any smoothing
would turn the 1-bit dither into gray mush.

Usage:

    python3 tools/make_readme_animations.py

Reads ~/spindle-demo by default, which is where the recorder puts its frames.
"""

import argparse
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageOps

PROJECT_FOLDER = Path(__file__).resolve().parent.parent
DEFAULT_FRAME_FOLDER = Path.home() / "spindle-demo"
OUTPUT_FOLDER = PROJECT_FOLDER / "docs"

SCREEN_WIDTH = 400
SCREEN_HEIGHT = 240

# Doubled, so the animation is 800 by 480 on the page. An exact multiple, so
# every source pixel becomes the same four output pixels and the dither stays
# even.
SCALE = 2

# The frames were recorded at thirty a second. Every second one is kept, which
# is fast enough that scrolling and the visualizers still read as motion and
# halves the size of the file.
SOURCE_FRAMES_PER_SECOND = 30
KEEP_EVERY = 2

# A border in the same yellow as the README badges, so the animations sit on the
# page as part of it rather than as two black rectangles. Rounded, with the
# corners left transparent, which WebP carries happily.
BORDER = 6
BORDER_RADIUS = 18
BORDER_COLOR = (255, 200, 51, 255)

# Where each visualizer's stretch of the recording begins, worked out from the
# recorder's timeline. The montage skips the first part of each, because that is
# where the picker's name overlay is showing.
VISUALIZER_STARTS = [596, 776, 911, 1031, 1181, 1316, 1481, 1601, 1751]
VISUALIZER_SKIP = 50
VISUALIZER_LENGTH = 46


def load_frame(frame_folder, frame_number):
    """One recorded frame, the right way up and at its final size."""
    picture = Image.open(frame_folder / f"frame-{frame_number:05d}.png").convert("L")
    return ImageOps.invert(picture).resize(
        (SCREEN_WIDTH * SCALE, SCREEN_HEIGHT * SCALE), Image.NEAREST).convert("RGBA")


def add_border(picture):
    """
    Put the yellow surround on, with the corners rounded and cut away.

    The rounding is done by drawing the whole thing into a rounded rectangle mask
    rather than by drawing four corners, so there is no seam where the straight
    edges meet the curves.
    """
    width = picture.width + BORDER * 2
    height = picture.height + BORDER * 2

    framed = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    painter = ImageDraw.Draw(framed)
    painter.rounded_rectangle(
        [0, 0, width - 1, height - 1], radius=BORDER_RADIUS, fill=BORDER_COLOR)
    framed.paste(picture, (BORDER, BORDER))

    # The screen's own corners follow the outer curve, slightly tighter, so the
    # yellow reads as an even width all the way round.
    corners = Image.new("L", (width, height), 0)
    ImageDraw.Draw(corners).rounded_rectangle(
        [0, 0, width - 1, height - 1], radius=BORDER_RADIUS, fill=255)
    framed.putalpha(corners)

    return framed


def write_animation(frames, destination, frames_per_second):
    """Save a list of pictures as one animated WebP."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    frames[0].save(
        destination,
        format="WEBP",
        save_all=True,
        append_images=frames[1:],
        duration=round(1000 / frames_per_second),
        loop=0,
        lossless=True,
        method=6,
    )
    return destination.stat().st_size


def build_browsing_animation(frame_folder, first, last):
    """The album list, a track list, and now playing, in one continuous run."""
    return [add_border(load_frame(frame_folder, number))
            for number in range(first, last + 1, KEEP_EVERY)]


def build_visualizer_animation(frame_folder):
    """
    A couple of seconds of each visualizer, one after another.

    Cut rather than run straight through, because sitting through all nine in
    full is forty seconds and the point is to show that there are nine of them
    and that they are not variations on one idea.
    """
    frames = []
    for start in VISUALIZER_STARTS:
        first = start + VISUALIZER_SKIP
        for number in range(first, first + VISUALIZER_LENGTH, KEEP_EVERY):
            frames.append(add_border(load_frame(frame_folder, number)))
    return frames


def main():
    parser = argparse.ArgumentParser(
        description="Build the README animations from recorded frames.")
    parser.add_argument("--frames", default=DEFAULT_FRAME_FOLDER, type=Path,
                        help=f"folder of recorded frames (default {DEFAULT_FRAME_FOLDER})")
    parser.add_argument("--out", default=OUTPUT_FOLDER, type=Path,
                        help="where to write the animations")
    arguments = parser.parse_args()

    if not (arguments.frames / "frame-00001.png").exists():
        print(f"No recorded frames in {arguments.frames}. Run the demo recorder first.",
              file=sys.stderr)
        return 1

    playing_at = SOURCE_FRAMES_PER_SECOND // KEEP_EVERY

    browsing = build_browsing_animation(arguments.frames, 1, 560)
    size = write_animation(browsing, arguments.out / "browsing.webp", playing_at)
    print(f"  browsing.webp   {len(browsing):4d} frames, "
          f"{len(browsing) / playing_at:4.1f}s, {size / 1024:6.0f} KB")

    visualizers = build_visualizer_animation(arguments.frames)
    size = write_animation(visualizers, arguments.out / "visualizers.webp", playing_at)
    print(f"  visualizers.webp {len(visualizers):3d} frames, "
          f"{len(visualizers) / playing_at:4.1f}s, {size / 1024:6.0f} KB")

    return 0


if __name__ == "__main__":
    sys.exit(main())
