#!/usr/bin/env python3
"""
Generate Spindle's launcher artwork from a photograph of a 45 RPM adapter.

The source is a red adapter on a white background, which separates cleanly:
the plastic reads around (219, 21, 52) and the background is pure white, so
thresholding on redness rather than brightness isolates the shape exactly. That
matters because a plain grayscale conversion would turn the red into a mid gray
and lose the edges.

Everything is rendered from the full resolution source and scaled down at the
last moment, so the curves stay clean through rotation rather than accumulating
artifacts from repeatedly resampling an already small bitmap.

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
SOURCE_IMAGE_PATH = PROJECT_FOLDER / "assets" / "adapter-45rpm.png"
OUTPUT_FOLDER = PROJECT_FOLDER / "Source" / "launcher"

# Where the README's logo goes. Separate from the launcher art because it is a
# different job: the launcher wants 1-bit at the exact size the device draws it,
# and a README wants something large and smooth that reads on a web page.
DOCS_FOLDER = PROJECT_FOLDER / "docs"
README_LOGO_WIDTH = 720

# Empty space above and below the README logo, as a share of its height.
#
# Baked into the image rather than done with markup. GitHub strips style
# attributes, so margin is not available, and the alternative is a row of <br>
# tags whose height depends on whatever font the page happens to be using. Space
# inside the picture is exact, scales with the logo if its width ever changes,
# and there is nothing in it for a sanitizer to remove.
README_LOGO_PADDING_SHARE = 0.18

# GitHub's social preview, the picture that shows up when the repository is
# linked anywhere. GitHub asks for 1280 by 640 and warns below 640 by 320.
#
# White on black, which is what the app itself looks like. A social card is seen
# at thumbnail size in a feed, so it has to be one recognizable block rather than
# a picture that gets read, and nothing carries further at that size than the
# highest contrast available.
SOCIAL_BANNER_SIZE = (1280, 640)
SOCIAL_BANNER_INK = (255, 255, 255)
SOCIAL_BANNER_BACKGROUND = (17, 17, 17)
SOCIAL_TAGLINE = "An album-first music player for the Playdate"



# The adapter on its own, used in the app wherever a cover is wanted and there
# is none: beside a playlist, which has no artwork of its own, and beside an
# album whose files carried none. Two sizes, matching the two places a cover is
# drawn.
COVER_MARK_FOLDER = PROJECT_FOLDER / "Source"
COVER_MARK_SIZES = (60, 140)

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
# block. Whether the launcher honors a mask on a card at all is the thing this
# is here to find out, and it can only be answered on the device.
RENDER_TRANSPARENT_BACKGROUND = True

# How red a pixel has to be, measured as red minus the average of green and
# blue, before it counts as part of the adapter. The sampled image ranges from
# about -2 on the background to 203 on the plastic, so anything in the middle
# separates them with room to spare.
REDNESS_THRESHOLD = 60

# The angle everything sits at when it is not turning.
#
# The adapter has three fold symmetry with a lobe tip every 120 degrees, sitting
# at 31, 150 and 270 degrees in the source artwork, so turning it 60 brings one
# to straight down. That reads as placed rather than as however the shape
# happened to be lying, and it applies everywhere: the card, the icon, the cover
# marks, the README logos and the social banner, so no two of them disagree
# about which way up the thing is.
#
# The launcher animation adds its own rotation on top of this, which changes
# where the loop starts and nothing else, since the loop is 120 degrees long and
# the shape repeats every 120 degrees.
ADAPTER_REST_ROTATION = 60

# Frames covering the 120 degrees of rotational symmetry. More frames make the
# motion smoother without changing its speed, because each step covers less
# ground. Sixty frames is two degrees per step, which is small enough that the
# rotation reads as continuous rather than stepped.
ANIMATION_FRAME_COUNT = 60

# The spinner on the empty screen. Sixty frames over the adapter's 120 degrees of
# symmetry is two degrees a frame, the same resolution the launcher animation
# uses, which is fine enough that a slow turn does not step.
#
# Laid out ten across and six down rather than in one long strip, because the
# Playdate reads an image table as cells left to right and top to bottom and does
# not care which, and a 1400 by 840 sheet is a friendlier shape than a 8400 by
# 140 one.
SPIN_FRAME_COUNT = 60
SPIN_FRAME_SIZE = 140
SPIN_COLUMNS = 10
SPIN_INSET = 3

# How many launcher ticks each frame is held for. Holding a frame for several
# ticks slows the rotation, but it also makes each step land as a visible jump.
# Holding for one tick and using more frames gives the same kind of speed with
# none of the jerkiness.
TICKS_PER_FRAME = 1


def load_adapter_mask():
    """
    Load the source artwork and reduce it to a mask of the adapter: black where
    the plastic is, white everywhere else, centered on the axis it should rotate
    about.

    Centring is the part that matters. Using the bounding box center makes the
    adapter wobble when it turns, because the curved arms do not sit
    symmetrically inside their bounding box. The centroid, meaning the average
    position of every pixel of plastic, is exactly the rotational axis for a
    shape with three fold symmetry, so that is what gets placed at the middle
    of the canvas.
    """
    source = Image.open(SOURCE_IMAGE_PATH).convert("RGB")
    pixels = numpy.asarray(source, dtype=numpy.int16)

    # Redness separates the plastic from the background far better than
    # brightness does, because red converts to a mid gray. It also does not care
    # what the background is: white scores near zero and the green key scores
    # negative, so both fall the same side of the threshold.
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

    # Paste so the centroid lands exactly at the center of the square canvas.
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

    grayscale = one_bit.convert("L")
    transparency = grayscale.point(lambda value: 0 if value == paper_value else 255)

    return Image.merge("RGBA", (grayscale, grayscale, grayscale, transparency))


def render_adapter(mask, target_size, rotation_degrees):
    """
    Rotate the full resolution mask and scale it down to the requested size.
    Rotating before downsampling is what keeps the curved arms smooth.
    """
    rotated = mask.rotate(
        rotation_degrees + ADAPTER_REST_ROTATION, resample=Image.BICUBIC, fillcolor=255)
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

    # Center the wordmark on the actual ink rather than on the text origin.
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


def build_spin_table(mask):
    """
    The adapter alone, cut out, at every angle its three fold symmetry needs.

    This is the spinner on the empty screen, so it is the bare shape rather than
    a square: no paper behind it, only the adapter, which reads as a record
    rather than as a sleeve.

    Cut out means the background is transparent and the plastic is black. The app
    runs with the display inverted, so black in the frame buffer is what comes
    out white on the screen, and a transparent background leaves whatever is
    behind it alone. Drawing this straight gives a white adapter on black.

    Rendered as frames rather than turned on the device. The arms are curves, the
    screen has no antialiasing, and rotating a 140 pixel 1-bit image at run time
    lands them wherever the rasteriser decides. Turning the artwork at full
    resolution and scaling down afterward is what keeps them smooth, which is the
    same reason the launcher animation is built this way.

    The adapter reaches 937 pixels from the centre of a mask 940 across, so it
    fits a rotation with three pixels to spare. The inset here is what turns
    three pixels of theoretical clearance into enough that antialiasing cannot
    shave a corner.
    """
    columns = SPIN_COLUMNS
    rows = SPIN_FRAME_COUNT // SPIN_COLUMNS
    cell = SPIN_FRAME_SIZE
    inner = cell - SPIN_INSET * 2

    sheet = Image.new("RGBA", (cell * columns, cell * rows), (0, 0, 0, 0))

    # Negative angles because PIL rotates counter clockwise for positive ones,
    # and a record turns clockwise.
    degrees_per_frame = 120 / SPIN_FRAME_COUNT
    for frame_number in range(SPIN_FRAME_COUNT):
        # to_one_bit already cuts the paper away and leaves the ink, which is
        # exactly what a spinner wants, so this borrows that rather than working
        # out its own alpha and getting the sense of it backwards.
        frame = to_one_bit(
            render_adapter(mask, inner, -frame_number * degrees_per_frame))

        sheet.paste(
            frame,
            ((frame_number % columns) * cell + SPIN_INSET,
             (frame_number // columns) * cell + SPIN_INSET),
        )

    return sheet


def build_icon(mask, rotation_degrees=0):
    """
    The 32 by 32 launcher icon: the adapter alone, since nothing else is
    legible at this size.
    """
    return to_one_bit(render_adapter(mask, ICON_SIZE, rotation_degrees))


def build_readme_logo(mask, ink):
    """
    The logo for the README: the adapter and the wordmark, large and smooth, on
    a transparent background.

    Not 1-bit, and deliberately so. Everything the device draws is 1-bit because
    that is what the screen is, but a README is displayed on an ordinary screen
    where the dithered version just looks broken. The shape is rendered large and
    scaled down with a good filter, which leaves clean antialiased edges.

    Two of these get written, one black and one white, so the README can hand
    GitHub both and let it pick by theme. A single black logo disappears against
    a dark theme and a single white one disappears against a light one, and a
    logo with its own background is a rectangle stuck on the page.
    """
    height = README_LOGO_WIDTH * 155 // 350

    # Composed at four times the final size, then scaled down, which is what
    # smooths the curves of the arms.
    scale = 4
    canvas = Image.new("L", (README_LOGO_WIDTH * scale, height * scale), 255)

    adapter_size = (height - 10) * scale
    adapter = mask.rotate(
        ADAPTER_REST_ROTATION, resample=Image.BICUBIC, fillcolor=255)
    adapter = adapter.resize((adapter_size, adapter_size), Image.LANCZOS)
    canvas.paste(adapter, (10 * scale, 5 * scale))

    draw = ImageDraw.Draw(canvas)
    wordmark_font = load_wordmark_font(44 * scale * README_LOGO_WIDTH // CARD_WIDTH)
    ink_bounds = draw.textbbox((0, 0), "SPINDLE", font=wordmark_font)
    ink_height = ink_bounds[3] - ink_bounds[1]
    draw.text(
        (WORDMARK_LEFT * scale * README_LOGO_WIDTH // CARD_WIDTH - ink_bounds[0],
         (height * scale - ink_height) // 2 - ink_bounds[1]),
        "SPINDLE",
        font=wordmark_font,
        fill=0,
    )

    canvas = canvas.resize((README_LOGO_WIDTH, height), Image.LANCZOS)

    # The grayscale becomes the alpha: where the artwork is dark the logo is
    # opaque, and the paper it was drawn on becomes nothing at all.
    transparency = ImageChops.invert(canvas)
    solid = Image.new("L", canvas.size, 0 if ink == "black" else 255)
    logo = Image.merge("RGBA", (solid, solid, solid, transparency))

    # Trimmed to where the artwork actually is before the space is added, so the
    # gap above and below is equal.
    #
    # Padding the canvas alone does not do that. The adapter and the wordmark do
    # not sit centered in the box they were composed in, so a symmetric margin
    # around an asymmetric picture stays asymmetric: it came out 84 pixels above
    # and 63 below. Only the vertical extent is trimmed. Cropping sideways as
    # well would move the logo off center, since the wordmark makes it much
    # wider than it is tall.
    ink = logo.getbbox()
    if ink:
        logo = logo.crop((0, ink[1], logo.width, ink[3]))

    padding = round(height * README_LOGO_PADDING_SHARE)
    padded = Image.new("RGBA", (logo.width, logo.height + padding * 2), (0, 0, 0, 0))
    padded.paste(logo, (0, padding))
    return padded


def build_social_banner(mask, ink=None, background=None, rotation=None):
    """
    The repository's social preview: the adapter, the wordmark, and one line
    saying what this is, white on purple.

    Composed at three times size and scaled down, the same trick the README logo
    uses, because the arms are curved and a shape this large drawn directly
    would show every step in them.
    """
    ink = ink or SOCIAL_BANNER_INK
    background = background or SOCIAL_BANNER_BACKGROUND
    rotation = ADAPTER_REST_ROTATION if rotation is None else rotation

    scale = 3
    width, height = (side * scale for side in SOCIAL_BANNER_SIZE)
    canvas = Image.new("L", (width, height), 0)

    adapter_size = round(height * 0.46)
    adapter = ImageChops.invert(
        mask.rotate(rotation, resample=Image.BICUBIC, fillcolor=255)
            .resize((adapter_size, adapter_size), Image.LANCZOS))


    draw = ImageDraw.Draw(canvas)
    wordmark_font = load_wordmark_font(round(height * 0.15))
    tagline_font = load_wordmark_font(round(height * 0.045))

    wordmark_bounds = draw.textbbox((0, 0), "SPINDLE", font=wordmark_font)
    wordmark_width = wordmark_bounds[2] - wordmark_bounds[0]

    # The adapter and the wordmark are centered as one unit rather than
    # separately, so the pair sits in the middle of the card however wide the
    # wordmark turns out with whatever font was found.
    gap = round(height * 0.05)
    block_width = adapter_size + gap + wordmark_width
    block_left = (width - block_width) // 2
    block_top = round(height * 0.20)

    canvas.paste(adapter, (block_left, block_top))
    draw.text(
        (block_left + adapter_size + gap - wordmark_bounds[0],
         block_top + (adapter_size - (wordmark_bounds[3] - wordmark_bounds[1])) // 2
         - wordmark_bounds[1]),
        "SPINDLE", font=wordmark_font, fill=255)

    tagline_bounds = draw.textbbox((0, 0), SOCIAL_TAGLINE, font=tagline_font)
    draw.text(
        ((width - (tagline_bounds[2] - tagline_bounds[0])) // 2 - tagline_bounds[0],
         block_top + adapter_size + round(height * 0.10) - tagline_bounds[1]),
        SOCIAL_TAGLINE, font=tagline_font, fill=255)

    artwork = canvas.resize(SOCIAL_BANNER_SIZE, Image.LANCZOS)

    banner = Image.new("RGB", SOCIAL_BANNER_SIZE, background)
    banner.paste(Image.new("RGB", SOCIAL_BANNER_SIZE, ink), (0, 0), artwork)
    return banner


def build_cover_mark(mask, size):
    """
    The adapter alone, filling a square, for use where a cover is expected and
    none exists.

    Drawn on white with the adapter dark, so it sits the same way round as a real
    cover does and a list of albums and playlists reads consistently. The app
    flips it exactly as it flips artwork, since the display is inverted and a
    mark meant to look like a cover has to be treated like one.

    This replaces three separate hand drawn placeholders, each of which was a
    circle and three spokes approximating the shape this is actually made from.
    """
    # A margin so the arms do not touch the edge of the square the way a
    # photograph's content does.
    inset = max(2, size // 12)
    adapter_size = size - inset * 2

    square = Image.new("L", (size, size), 255)
    adapter = mask.rotate(
        ADAPTER_REST_ROTATION, resample=Image.BICUBIC, fillcolor=255
    ).resize((adapter_size, adapter_size), Image.LANCZOS)
    square.paste(adapter, (inset, inset))

    return square.convert("1", dither=Image.NONE)


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

    for size in COVER_MARK_SIZES:
        build_cover_mark(mask, size).save(COVER_MARK_FOLDER / f"adapter-{size}.png")
    print(f"wrote cover marks to {COVER_MARK_FOLDER}")
    print(f"  " + ", ".join(f"adapter-{size}.png" for size in COVER_MARK_SIZES))

    # The name has to carry the cell size. That is how the Playdate knows how to
    # cut an image table up, and it is read from the filename rather than from
    # anything in the file.
    spin_name = f"adapter-spin-table-{SPIN_FRAME_SIZE}-{SPIN_FRAME_SIZE}.png"
    build_spin_table(mask).save(COVER_MARK_FOLDER / spin_name)
    print(f"  {spin_name}, {SPIN_FRAME_COUNT} frames")

    DOCS_FOLDER.mkdir(parents=True, exist_ok=True)
    build_readme_logo(mask, "black").save(DOCS_FOLDER / "logo-light.png")
    build_readme_logo(mask, "white").save(DOCS_FOLDER / "logo-dark.png")
    build_social_banner(mask).save(DOCS_FOLDER / "social-banner.png")

    total_ticks = ANIMATION_FRAME_COUNT * TICKS_PER_FRAME
    print(f"wrote README logos to {DOCS_FOLDER}")
    print(f"  logo-light.png, logo-dark.png at {README_LOGO_WIDTH}px wide")
    print(f"  social-banner.png at {SOCIAL_BANNER_SIZE[0]} by {SOCIAL_BANNER_SIZE[1]}")
    print(f"wrote launcher art to {OUTPUT_FOLDER}")
    print(f"  card.png, card-pressed.png, icon.png")
    print(f"  {ANIMATION_FRAME_COUNT} frames over 120 degrees, held {TICKS_PER_FRAME} ticks each")
    print(f"  {total_ticks} ticks per third of a turn, so {total_ticks * 3} per full revolution")


if __name__ == "__main__":
    main()
