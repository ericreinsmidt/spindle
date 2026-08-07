#!/usr/bin/env python3
"""
Generate Spindle's launcher artwork from a photograph of a 45 RPM adapter.

The source is a red adapter on a white background, which separates cleanly:
the plastic reads around (219, 21, 52) and the background is pure white, so
thresholding on redness rather than brightness isolates the shape exactly. That
matters because a plain greyscale conversion would turn the red into a mid grey
and lose the edges.

Everything is rendered from the full resolution source and scaled down at the
last moment, so the curves stay clean through rotation rather than accumulating
artefacts from repeatedly resampling an already small bitmap.

Because the adapter has three fold rotational symmetry, a rotation of 120
degrees returns it to where it started, so the animation only needs frames
covering 120 degrees before it can loop seamlessly.

Output goes to Source/launcher, which pdxinfo points at with imagePath. pdc
converts the PNGs during the build.
"""

from pathlib import Path

import numpy
from PIL import Image, ImageChops, ImageDraw, ImageFont

PROJECT_FOLDER = Path(__file__).parent.parent
SOURCE_IMAGE_PATH = PROJECT_FOLDER / "assets" / "adapter-45rpm.webp"
OUTPUT_FOLDER = PROJECT_FOLDER / "Source" / "launcher"

CARD_WIDTH = 350

# Where the wordmark starts. The adapter occupies roughly the first 155 pixels,
# so this leaves a small gap beside it and keeps a similar margin on the right.
WORDMARK_LEFT = 162
CARD_HEIGHT = 155
ICON_SIZE = 32

# Whether the launcher art comes out white on black.
#
# The app itself runs inverted, so the card and icon match it rather than being
# the one part of Spindle that is the other way round. Flip this to False to see
# the black on white version again; nothing else needs changing, because the
# inversion is applied at the very end after everything has been composed.
RENDER_INVERTED = False

# Whether the card and icon are cut out, leaving only the adapter and the
# wordmark with nothing behind them.
#
# The launcher draws cards over its own striped background, so a cut out card
# lets those stripes run through the artwork instead of sitting on a solid
# block. Whether the launcher honours a mask on a card at all is the thing this
# is here to find out, and it can only be answered on the device.
RENDER_TRANSPARENT_BACKGROUND = True

# How red a pixel has to be, measured as red minus the average of green and
# blue, before it counts as part of the adapter. The sampled image ranges from
# about -2 on the background to 203 on the plastic, so anything in the middle
# separates them with room to spare.
REDNESS_THRESHOLD = 60

# Frames covering the 120 degrees of rotational symmetry. More frames make the
# motion smoother without changing its speed, because each step covers less
# ground. Sixty frames is two degrees per step, which is small enough that the
# rotation reads as continuous rather than stepped.
ANIMATION_FRAME_COUNT = 60

# How many launcher ticks each frame is held for. Holding a frame for several
# ticks slows the rotation, but it also makes each step land as a visible jump.
# Holding for one tick and using more frames gives the same kind of speed with
# none of the jerkiness.
TICKS_PER_FRAME = 1


def load_adapter_mask():
    """
    Load the source photograph and reduce it to a mask of the adapter: black
    where the plastic is, white everywhere else, centred on the axis it should
    rotate about.

    Centring is the part that matters. Using the bounding box centre makes the
    adapter wobble when it turns, because the curved arms do not sit
    symmetrically inside their bounding box. The centroid, meaning the average
    position of every pixel of plastic, is exactly the rotational axis for a
    shape with three fold symmetry, so that is what gets placed at the middle
    of the canvas.
    """
    source = Image.open(SOURCE_IMAGE_PATH).convert("RGB")
    pixels = numpy.asarray(source, dtype=numpy.int16)

    # Redness separates the plastic from the white background far better than
    # brightness does, because red converts to a mid grey.
    redness = pixels[:, :, 0] - (pixels[:, :, 1] + pixels[:, :, 2]) // 2
    isPlastic = redness > REDNESS_THRESHOLD

    plasticRows, plasticColumns = numpy.nonzero(isPlastic)
    if len(plasticRows) == 0:
        raise SystemExit("No adapter found in the source image. Check REDNESS_THRESHOLD.")

    centroidX = plasticColumns.mean()
    centroidY = plasticRows.mean()

    # The canvas has to be big enough that no part of the shape leaves it while
    # turning, which means twice the distance from the centroid to the furthest
    # pixel of plastic.
    distancesFromCentroid = numpy.sqrt(
        (plasticColumns - centroidX) ** 2 + (plasticRows - centroidY) ** 2
    )
    outerRadius = float(distancesFromCentroid.max())
    canvasSide = int(outerRadius * 2) + 8

    mask = Image.fromarray(numpy.where(isPlastic, 0, 255).astype(numpy.uint8), mode="L")

    # Paste so the centroid lands exactly at the centre of the square canvas.
    squared = Image.new("L", (canvasSide, canvasSide), 255)
    squared.paste(mask, (
        int(round(canvasSide / 2 - centroidX)),
        int(round(canvasSide / 2 - centroidY)),
    ))

    return squared


def to_one_bit(image):
    """
    Finish an image: invert it if the art is being rendered white on black, then
    reduce it to the 1-bit the launcher wants.

    Inverting here rather than while composing means every part of the card is
    built the same way whichever version is being made, so the adapter, the
    wordmark and the background can never end up disagreeing about which way
    round they are.

    Dithering is off. These are solid shapes and type, and a dither pattern on
    either would shimmer as the card animates rather than reading as tone.
    """
    if RENDER_INVERTED:
        image = ImageChops.invert(image)

    one_bit = image.convert("1", dither=Image.NONE)
    if not RENDER_TRANSPARENT_BACKGROUND:
        return one_bit

    # Cut the paper away and leave the ink.
    #
    # Which value counts as paper depends on which way round the art is being
    # rendered, so it is taken from the same switch rather than assumed to be
    # white. Getting that backwards would cut out the artwork and keep the
    # background, which is a mistake that looks like the mask simply not working.
    paper_value = 0 if RENDER_INVERTED else 255

    greyscale = one_bit.convert("L")
    transparency = greyscale.point(lambda value: 0 if value == paper_value else 255)

    return Image.merge("RGBA", (greyscale, greyscale, greyscale, transparency))


def render_adapter(mask, target_size, rotation_degrees):
    """
    Rotate the full resolution mask and scale it down to the requested size.
    Rotating before downsampling is what keeps the curved arms smooth.
    """
    rotated = mask.rotate(rotation_degrees, resample=Image.BICUBIC, fillcolor=255)
    return rotated.resize((target_size, target_size), Image.LANCZOS)


def load_wordmark_font(size):
    """
    Find a usable font for the wordmark. The exact paths vary between macOS
    versions, so several candidates are tried before falling back to PIL's
    built in bitmap font.
    """
    candidate_paths = [
        "/System/Library/Fonts/Supplemental/Futura.ttc",
        "/System/Library/Fonts/HelveticaNeue.ttc",
        "/System/Library/Fonts/Helvetica.ttc",
        "/Library/Fonts/Arial.ttf",
    ]
    for path in candidate_paths:
        if Path(path).exists():
            try:
                return ImageFont.truetype(path, size)
            except Exception:
                continue
    return ImageFont.load_default()


def build_card(mask, rotation_degrees):
    """
    The launcher card: the adapter on the left, the wordmark on the right.
    """
    card = Image.new("L", (CARD_WIDTH, CARD_HEIGHT), 255)

    adapter_size = CARD_HEIGHT - 10
    adapter = render_adapter(mask, adapter_size, rotation_degrees)
    card.paste(adapter, (10, 5))

    draw = ImageDraw.Draw(card)

    # Centre the wordmark on the actual ink rather than on the text origin.
    # draw.text positions by the font's ascender line, which sits well above the
    # visible letters, so passing a y of half the card height leaves the word
    # noticeably low. textbbox reports where the pixels really land.
    wordmarkFont = load_wordmark_font(44)
    wordmark = "SPINDLE"
    inkBounds = draw.textbbox((0, 0), wordmark, font=wordmarkFont)
    inkHeight = inkBounds[3] - inkBounds[1]

    draw.text(
        (WORDMARK_LEFT - inkBounds[0], (CARD_HEIGHT - inkHeight) // 2 - inkBounds[1]),
        wordmark,
        font=wordmarkFont,
        fill=0,
    )

    return to_one_bit(card)


def build_icon(mask, rotation_degrees=0):
    """
    The 32 by 32 launcher icon: the adapter alone, since nothing else is
    legible at this size.
    """
    return to_one_bit(render_adapter(mask, ICON_SIZE, rotation_degrees))


def main():
    if not SOURCE_IMAGE_PATH.exists():
        raise SystemExit(f"Source image not found: {SOURCE_IMAGE_PATH}")

    print("reading the adapter photograph and isolating the shape...")
    mask = load_adapter_mask()
    print(f"  shape isolated, working at {mask.size[0]} by {mask.size[1]}")

    OUTPUT_FOLDER.mkdir(parents=True, exist_ok=True)
    highlighted_folder = OUTPUT_FOLDER / "card-highlighted"
    highlighted_folder.mkdir(exist_ok=True)

    # Clear out any frames from a previous run with a different frame count,
    # otherwise stale images are left behind and the animation references only
    # some of what is present.
    for stale_frame in highlighted_folder.glob("*.png"):
        stale_frame.unlink()

    build_card(mask, 0).save(OUTPUT_FOLDER / "card.png")
    build_card(mask, 0).save(OUTPUT_FOLDER / "card-pressed.png")
    build_icon(mask).save(OUTPUT_FOLDER / "icon.png")

    # Negative angles because PIL rotates counter clockwise for positive ones,
    # and a record turns clockwise.
    degrees_per_frame = 120 / ANIMATION_FRAME_COUNT
    for frame_number in range(ANIMATION_FRAME_COUNT):
        rotation = -frame_number * degrees_per_frame
        build_card(mask, rotation).save(highlighted_folder / f"{frame_number + 1}.png")

    # Each frame is listed with a hold count, which is what makes the rotation
    # slow. loopCount of zero repeats forever.
    frame_sequence = ", ".join(
        f"{number}x{TICKS_PER_FRAME}" for number in range(1, ANIMATION_FRAME_COUNT + 1)
    )
    (highlighted_folder / "animation.txt").write_text(
        f"loopCount = 0\nframes = {frame_sequence}\n"
    )

    total_ticks = ANIMATION_FRAME_COUNT * TICKS_PER_FRAME
    print(f"wrote launcher art to {OUTPUT_FOLDER}")
    print(f"  card.png, card-pressed.png, icon.png")
    print(f"  {ANIMATION_FRAME_COUNT} frames over 120 degrees, held {TICKS_PER_FRAME} ticks each")
    print(f"  {total_ticks} ticks per third of a turn, so {total_ticks * 3} per full revolution")


if __name__ == "__main__":
    main()
