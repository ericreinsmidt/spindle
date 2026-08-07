#!/usr/bin/env python3
"""
Turn a folder of frames written by the demo recorder into a video with sound.

The frames come from Source/demo.lua, which drives the app through a scripted
sequence and hands over each frame as the app drew it. They are exact, and they
are not a screen recording, so the Simulator running at four frames a second
while it writes them makes no difference to the result.

The sound does not come from the Simulator at all. It comes from the original
audio file that ingest converted into the .pda the app played, which means it
has never been through a virtual audio device and is not a re-recording of
anything. The manifest the recorder writes says which frame the music started on
and how far into the track it was at that moment, and those two numbers are what
line the audio up against the picture.

Two things have to be done to the frames on the way through:

  The app draws for a display that inverts everything afterward, so what it
  hands over is a negative. playdate.graphics.getWorkingImage is documented as
  not applying setInverted, so the frames come out the wrong way round and have
  to be flipped back.

  400 by 240 is very small for a video, and scaling it smoothly turns a 1-bit
  dither into gray mush. Nearest neighbor scaling keeps every dot a dot.

Usage:

    python3 tools/make_demo_video.py --audio "~/Music/.../03 High and Dry.mp3"

The frame folder and manifest default to where the recorder puts them.
"""

import argparse
import math
import shutil
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageOps

# make_launcher_art lives beside this file and owns the adapter artwork, which
# the closing card borrows rather than reproducing.
sys.path.insert(0, str(Path(__file__).resolve().parent))

PROJECT_FOLDER = Path(__file__).resolve().parent.parent
LAUNCHER_FOLDER = PROJECT_FOLDER / "Source/launcher"

DEFAULT_FRAME_FOLDER = Path.home() / "spindle-demo"
DEFAULT_MANIFEST = (
    Path.home()
    / "Developer/PlaydateSDK/Disk/Data/com.reinsmidt.spindle/demo-manifest.txt"
)
DEFAULT_OUTPUT = Path.home() / "Desktop/spindle-demo.mp4"

# How much bigger the video is than the Playdate screen. Two gives 800 by 480,
# which is large enough to watch and still an exact multiple, so every source
# pixel becomes the same number of output pixels and the dither stays even.
SCALE_FACTOR = 2

SCREEN_WIDTH = 400
SCREEN_HEIGHT = 240

# Where the launcher draws a game's card, straight from the SDK documentation:
# the card image is drawn centered on the screen in the rect (25, 43, 350, 155).
CARD_LEFT = 25
CARD_TOP = 43

# How long the card is held with the A button down before the app appears. Short,
# because that is all it is on the device.
PRESSED_SECONDS = 0.25

# The device the video is set into.
#
# Drawn here rather than taken from the Simulator, whose device artwork is not a
# loose file and belongs to Panic in any case. The proportions come from the real
# thing: a body of 76 by 74 millimetres with a screen of roughly 56 by 33, which
# is what puts the screen at about three quarters of the body's width and sets
# how much room is left underneath for the controls.
#
# The screen stays at exactly twice the Playdate's resolution and the body is
# sized around it, rather than the body being sized first and the screen made to
# fit. A screen scaled by any fraction turns the 1-bit dither into gray mush, so
# the integer multiple is the fixed point that everything else is measured from.
DEVICE_BODY_WIDTH = round(SCREEN_WIDTH * SCALE_FACTOR / 0.737)
DEVICE_BODY_HEIGHT = round(DEVICE_BODY_WIDTH * 74 / 76)
DEVICE_SCREEN_TOP_SHARE = 0.135

CANVAS_WIDTH = 1920
CANVAS_HEIGHT = 1200

# A mask sitting beside the device render, with the active display area painted
# in one flat color. Picked up automatically when it is there.
DEVICE_MASK_NAME = "mask.png"

# The scene the device is set into.
#
# The tilt is applied to the device rather than to the whole canvas, so the
# background stays square to the frame and only the handheld leans. Positive
# degrees are clockwise, matching the way the ffmpeg rotate filter reads them,
# because the same angle has to be given to both the picture of the device and
# the frames going into its screen.
BACKGROUND_COLOR = (124, 58, 237)

# How far the picture runs past the marked screen area on every side.
#
# The frames deliberately overhang rather than being fitted inside the mask. A
# hand painted mask has a ragged pixel or two along its edges, and the marked
# area is not exactly the screen's shape either, so fitting inside it leaves a
# thin seam of whatever is underneath showing through. Overhanging hides both,
# and the overhang is cut off by nothing because the screen is drawn on top.
#
# It also removes the reason to compromise on scale. The frames stay at an exact
# whole multiple and the render is resized so the mask sits just inside them,
# rather than the frames being squeezed to whatever size the mask happens to be.
OVERSCAN_PIXELS = 10

# The device drops in over the launcher card rather than simply being there.
#
# It starts larger than life, as though it were close to you, and settles back
# with a damped bounce: well past its resting size, back under it, over it again
# by less, and so on until the swing has gone out of it. That is a decaying
# cosine, which is the same shape a real thing settling on a spring makes, and
# it is far more convincing than easing straight into place.
#
# BOUNCE_OVERSHOOT is how much bigger than final it starts, so 0.55 begins at one
# and a half times size. BOUNCE_SWINGS is how many times it crosses its resting
# size on the way, and BOUNCE_DAMPING is how quickly the swing dies away.
BOUNCE_SECONDS = 1.5
BOUNCE_OVERSHOOT = 0.55
BOUNCE_SWINGS = 2.0
BOUNCE_DAMPING = 1.6

# The device turns back square over the closing stretch, so the video finishes
# on the handheld sitting level rather than leaning.
#
# Eased at both ends rather than turned at a constant rate. A constant rate
# starts and stops abruptly, which reads as a machine moving it; easing in and
# out reads as the thing coming to rest.
OUTRO_SECONDS = 10.0

# The card the video finishes on: the picture fades away to black, the adapter
# turns up spinning with the wordmark under it, and it is left to spin.
#
# The adapter is rendered from the same photograph the launcher art and the
# README logos come from, at the angle it should be at for that frame, rather
# than being a pre-made picture that gets rotated. Rotating first and scaling
# down afterward is what keeps the curved arms smooth, and that is what
# make_launcher_art already does, so this borrows it rather than repeating it.
ENDCARD_FADE_OUT_SECONDS = 1.0
ENDCARD_FADE_IN_SECONDS = 1.0
ENDCARD_HOLD_SECONDS = 3.0

# Ten revolutions a minute. Slower than a record, deliberately: 45 would be two
# whole turns during the hold, which reads as frantic on something meant to sit
# there at the end.
ENDCARD_SPIN_PER_SECOND = 60.0

ENDCARD_ADAPTER_SHARE = 0.22
ENDCARD_WORDMARK_SHARE = 0.065
ENDCARD_GAP_SHARE = 0.035
TILT_DEGREES = 20
MARGIN_SHARE = 0.10

CANVAS_COLOR = (18, 18, 18)
BODY_COLOR = (242, 194, 51)
BODY_EDGE_COLOR = (198, 154, 30)
CONTROL_COLOR = (28, 26, 22)
CRANK_COLOR = (54, 50, 44)


def parse_timecode(text):
    """
    Read a position as either plain seconds or minutes:seconds.

    Written for values copied off a video player, which shows 1:05.10 rather
    than 65.1, and getting that wrong by a factor of sixty is the kind of mistake
    that is only obvious afterward.
    """
    text = str(text).strip()
    if ":" not in text:
        return float(text)
    minutes, _, seconds = text.partition(":")
    return int(minutes) * 60 + float(seconds)


def parse_color(text):
    """Read a hex color, with or without its leading hash."""
    if isinstance(text, tuple):
        return text
    digits = text.lstrip("#")
    if len(digits) != 6:
        raise argparse.ArgumentTypeError(f"{text} is not a six digit hex color")
    return tuple(int(digits[index:index + 2], 16) for index in (0, 2, 4))


def read_manifest(manifest_path):
    """
    Read the recorder's manifest into a dictionary.

    The format is one "key value" pair per line, with the value being the rest
    of the line, because album and track titles have spaces in them.
    """
    values = {}
    for line in manifest_path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        key, _, value = line.partition(" ")
        values[key] = value.strip()
    return values


def build_launcher_backdrop():
    """
    The surface the launcher draws its cards on.

    Measured off a device screenshot as exactly 50 percent black in alternating
    single pixel rows, which is why it is built a row at a time rather than
    filled with a gray value. On a 1-bit screen there is no gray to fill with,
    and a real halftone is what makes black card artwork stand out against it.
    """
    backdrop = Image.new("L", (SCREEN_WIDTH, SCREEN_HEIGHT), 255)
    black_row = Image.new("L", (SCREEN_WIDTH, 1), 0)
    for row in range(0, SCREEN_HEIGHT, 2):
        backdrop.paste(black_row, (0, row))
    return backdrop


def render_opening_frames(opening_folder, seconds, frames_per_second):
    """
    Render the launcher sitting on Spindle's card, then the card being pressed.

    This is generated rather than captured because the launcher is the system's
    own program and cannot be driven by the recorder. Everything in it is real:
    the card and its sixty rotation frames are the files the launcher would
    actually be showing, the position is the rect the SDK documents, and the
    backdrop is the one measured off the device.

    The rotation plays one frame per tick, which is what animation.txt asks for,
    so the speed here is the speed the launcher would run it at.

    Note that these frames are written the right way round already. The app's own
    frames arrive as negatives, because the display inverts them afterward, but
    the launcher is not Spindle and is not inverted. The two sequences are
    therefore treated differently when they are joined.
    """
    opening_folder.mkdir(parents=True, exist_ok=True)
    for stale_frame in opening_folder.glob("frame-*.png"):
        stale_frame.unlink()

    backdrop = build_launcher_backdrop()

    rotation_frames = sorted(
        (LAUNCHER_FOLDER / "card-highlighted").glob("*.png"),
        key=lambda path: int(path.stem),
    )
    if not rotation_frames:
        rotation_frames = [LAUNCHER_FOLDER / "card.png"]

    pressed_card = Image.open(LAUNCHER_FOLDER / "card-pressed.png").convert("RGBA")

    total_frames = round(seconds * frames_per_second)
    pressed_frames = round(PRESSED_SECONDS * frames_per_second)

    for frame_index in range(total_frames):
        if frame_index >= total_frames - pressed_frames:
            card = pressed_card
        else:
            card = Image.open(
                rotation_frames[frame_index % len(rotation_frames)]).convert("RGBA")

        screen = backdrop.copy().convert("RGBA")

        # The card carries its own transparency, which is the whole point of it:
        # it is cut out so the adapter and the wordmark sit directly on the
        # launcher's backdrop rather than on a rectangle of their own.
        screen.alpha_composite(card, (CARD_LEFT, CARD_TOP))

        screen.convert("L").save(opening_folder / f"frame-{frame_index + 1:05d}.png")

    return total_frames


def canvas_size_for(device_layer, tilt_degrees, margin_share):
    """
    Work out the finished picture's size from the device at its widest tilt.

    Fixed once and used for every frame afterward, including the ones where the
    device is turning back toward square. A canvas that grew and shrank with the
    device would be a video that changes size part way through, which is not a
    thing videos can do.
    """
    turned = device_layer.rotate(-tilt_degrees, resample=Image.NEAREST, expand=True)
    margin = round(turned.width * margin_share)

    return (round_up_to_macroblock(turned.width + margin * 2),
            round_up_to_macroblock(turned.height + margin * 2))


def round_up_to_macroblock(value):
    """
    Round a dimension up to a multiple of sixteen.

    H264 codes the picture in sixteen by sixteen macroblocks. A frame that is not
    a whole number of them gets padded up to one and carries a note asking the
    decoder to crop the padding off again. Plenty of players handle that badly,
    and what they show is blocky rubbish along the edges of the visible area,
    which was the artifact that would not go away no matter what the encoder
    settings were. It was never in the pixels; it was in the geometry.

    Rounding up rather than down, so nothing is cut off the picture. The extra is
    background, which is what the edges are anyway.
    """
    return (value + 15) // 16 * 16


def affine_for_rotation(angle_degrees, source_center, target_center):
    """
    Coefficients that rotate a picture clockwise about a point and land that
    point somewhere chosen in the output.

    Pillow's AFFINE transform is described backwards from how you think about it:
    the coefficients map a point in the output back to where it came from in the
    input, which is why this is the inverse rotation rather than the rotation.

    Everything here is floating point on purpose. The rotate helper this replaces
    grew the picture to fit and then centered it with integer division, so the
    offset stepped by a whole pixel every time the grown size crossed a boundary,
    and the device visibly twitched against the background as it turned. A fixed
    output size and a matrix with no rounding in it has nowhere for that to hide.
    """
    radians = math.radians(angle_degrees)
    cosine = math.cos(radians)
    sine = math.sin(radians)

    source_x, source_y = source_center
    target_x, target_y = target_center

    return (
        cosine, sine, source_x - cosine * target_x - sine * target_y,
        -sine, cosine, source_y + sine * target_x - cosine * target_y,
    )


def rotate_point(point, angle_degrees, source_center, target_center):
    """Where a point in the picture ends up once the rotation has been applied."""
    radians = math.radians(angle_degrees)
    cosine = math.cos(radians)
    sine = math.sin(radians)

    offset_x = point[0] - source_center[0]
    offset_y = point[1] - source_center[1]

    return (target_center[0] + cosine * offset_x - sine * offset_y,
            target_center[1] + sine * offset_x + cosine * offset_y)


def place_device(device_layer, screen_rect, tilt_degrees, canvas_size):
    """
    Turn the device by an angle, center it on a transparent canvas, and say
    where its screen ended up.

    Called once for a still device and once per frame while it is turning, which
    is why the canvas size is handed in rather than worked out here.

    One matrix does the whole job: it rotates the device about the middle of the
    canvas straight into a canvas sized picture, and the same rotation applied to
    the middle of the screen rectangle says where the screen went. The two cannot
    disagree, because they are the same rotation rather than two descriptions of
    it, and the answer comes back as a fraction of a pixel rather than rounded.
    """
    screen_left, screen_top, screen_width, screen_height = screen_rect

    canvas_center = (canvas_size[0] / 2, canvas_size[1] / 2)
    device_center = (device_layer.width / 2, device_layer.height / 2)

    layer = device_layer.transform(
        canvas_size, Image.AFFINE,
        affine_for_rotation(tilt_degrees, device_center, canvas_center),
        resample=Image.BICUBIC)

    screen_center = rotate_point(
        (screen_left + screen_width / 2, screen_top + screen_height / 2),
        tilt_degrees, device_center, canvas_center)

    return layer, screen_center[0], screen_center[1]


def flatten_onto_background(layer, background_color):
    """Put a transparent layer down on a solid background."""
    canvas = Image.new("RGBA", layer.size, tuple(background_color) + (255,))
    canvas.alpha_composite(layer)
    return canvas.convert("RGB")


def bounce_scale_at(elapsed_share):
    """
    How big the device is, as a share of its resting size, part way through the
    drop in.

    A decaying cosine. It starts at one plus the overshoot, swings through its
    resting size the given number of times, and the swing shrinks as it goes. At
    the end the multiplier is forced to exactly one, so the last rendered frame
    matches the still device the rest of the video is built on and the handover
    between the two is invisible.
    """
    if elapsed_share >= 1:
        return 1.0

    swing = math.cos(elapsed_share * BOUNCE_SWINGS * 2 * math.pi)

    # Two things damp the swing, and the second is the important one.
    #
    # The exponential alone never actually reaches zero. It was cut off at the
    # end instead, which left the last bounce frame 2.7 percent larger than the
    # still device that follows it, and that one frame jump is exactly the snap
    # it looked like. Multiplying by (1 - share) squared brings both the size and
    # the rate it is changing to zero together, so the movement runs out rather
    # than being stopped.
    decay = math.exp(-elapsed_share * BOUNCE_DAMPING) * (1 - elapsed_share) ** 2

    return 1 + BOUNCE_OVERSHOOT * swing * decay


def outro_angle_at(elapsed_share, tilt_degrees):
    """
    How far the device is still leaning, part way through the closing turn.

    Smootherstep, which is the cubic's better behaved relative: it leaves the
    starting angle and arrives at the final one with no rate of change at either
    end, so there is nothing to see starting and nothing to see stopping.
    """
    if elapsed_share >= 1:
        return 0.0

    share = max(0.0, elapsed_share)
    eased = share ** 3 * (share * (share * 6 - 15) + 10)
    return tilt_degrees * (1 - eased)


def render_outro_frames(outro_folder, app_folder, first_app_frame, device_layer,
                        screen_rect, canvas_size, screen_scale, tilt_degrees,
                        background_color, frame_count):
    """
    Render the closing turn as finished frames.

    Same reason the drop in cannot go through the normal pipeline: the device is
    moving, so it is no longer a still that ffmpeg can lay the screen over. Each
    frame here places the device at its own angle, turns that frame of the app by
    the same angle, and sets both down on the background.

    The app's frames arrive as negatives, because the display inverts them
    afterward, so they are flipped here exactly as the ffmpeg path flips them.
    """
    outro_folder.mkdir(parents=True, exist_ok=True)
    for stale_frame in outro_folder.glob("frame-*.png"):
        stale_frame.unlink()

    canvas_width, canvas_height = canvas_size

    for frame_index in range(frame_count):
        angle = outro_angle_at(frame_index / max(frame_count - 1, 1), tilt_degrees)

        layer, screen_center_x, screen_center_y = place_device(
            device_layer, screen_rect, angle, canvas_size)

        app_frame = Image.open(
            app_folder / f"frame-{first_app_frame + frame_index:05d}.png").convert("L")
        screen_picture = ImageOps.invert(app_frame).convert("RGBA").resize(
            (SCREEN_WIDTH * screen_scale, SCREEN_HEIGHT * screen_scale), Image.NEAREST)

        # The screen is turned and positioned by one matrix as well, rather than
        # being turned and then pasted at a rounded offset. Rounding the paste
        # was the other half of the judder: the device and its screen each landed
        # on a whole pixel independently, so they twitched against each other as
        # well as against the background.
        #
        # Nearest neighbor here and bicubic for the device, matching what the
        # still part of the video does to each, so nothing changes appearance at
        # the moment the turn takes over.
        turned_screen = screen_picture.transform(
            canvas_size, Image.AFFINE,
            affine_for_rotation(
                angle,
                (screen_picture.width / 2, screen_picture.height / 2),
                (screen_center_x, screen_center_y)),
            resample=Image.NEAREST)

        layer.alpha_composite(turned_screen)

        canvas = Image.new("RGBA", canvas_size, tuple(background_color) + (255,))
        canvas.alpha_composite(layer)
        canvas.convert("RGB").save(outro_folder / f"frame-{frame_index + 1:05d}.png")

    return frame_count


def build_endcard_logo(canvas_size, rotation_degrees):
    """
    The adapter at a given angle with SPINDLE under it, white on black.

    Built at the angle wanted rather than by rotating a finished picture, for the
    same reason the launcher frames are: the mask is turned at full resolution
    and scaled down afterward, which is what keeps the arms smooth instead of
    stepped.
    """
    import make_launcher_art

    canvas_width, canvas_height = canvas_size
    adapter_size = round(canvas_height * ENDCARD_ADAPTER_SHARE)
    wordmark_size = round(canvas_height * ENDCARD_WORDMARK_SHARE)
    gap = round(canvas_height * ENDCARD_GAP_SHARE)

    if not hasattr(build_endcard_logo, "mask"):
        build_endcard_logo.mask = make_launcher_art.load_adapter_mask()

    # render_adapter gives black plastic on white paper, which is the wrong way
    # round for a card that sits on black, so it is inverted on the way in.
    adapter = ImageOps.invert(
        make_launcher_art.render_adapter(
            build_endcard_logo.mask, adapter_size, rotation_degrees).convert("L"))

    font = make_launcher_art.load_wordmark_font(wordmark_size)

    canvas = Image.new("L", canvas_size, 0)
    painter = ImageDraw.Draw(canvas)

    wordmark_box = painter.textbbox((0, 0), "SPINDLE", font=font)
    wordmark_width = wordmark_box[2] - wordmark_box[0]
    wordmark_height = wordmark_box[3] - wordmark_box[1]

    block_height = adapter_size + gap + wordmark_height
    block_top = (canvas_height - block_height) // 2

    canvas.paste(adapter, ((canvas_width - adapter_size) // 2, block_top))
    painter.text(
        ((canvas_width - wordmark_width) // 2 - wordmark_box[0],
         block_top + adapter_size + gap - wordmark_box[1]),
        "SPINDLE", font=font, fill=255)

    return canvas.convert("RGB")


def render_endcard_frames(endcard_folder, last_video_frame, canvas_size,
                          frames_per_second):
    """
    Render the closing card: the last frame of the video fading away to black,
    then the spinning logo fading up, then the logo left spinning.

    The adapter keeps turning through the fade rather than starting to turn once
    it has arrived, so it is already in motion by the time you can see it. A logo
    that appears still and then starts moving reads as two separate events.
    """
    endcard_folder.mkdir(parents=True, exist_ok=True)
    for stale_frame in endcard_folder.glob("frame-*.png"):
        stale_frame.unlink()

    fade_out_frames = round(ENDCARD_FADE_OUT_SECONDS * frames_per_second)
    fade_in_frames = round(ENDCARD_FADE_IN_SECONDS * frames_per_second)
    hold_frames = round(ENDCARD_HOLD_SECONDS * frames_per_second)

    black = Image.new("RGB", canvas_size, (0, 0, 0))
    closing_picture = Image.open(last_video_frame).convert("RGB") \
        if last_video_frame else black

    degrees_per_frame = ENDCARD_SPIN_PER_SECOND / frames_per_second
    frame_number = 0

    for step in range(fade_out_frames):
        frame_number += 1
        remaining = 1 - (step + 1) / fade_out_frames
        Image.blend(black, closing_picture, remaining).save(
            endcard_folder / f"frame-{frame_number:05d}.png")

    for step in range(fade_in_frames + hold_frames):
        frame_number += 1
        angle = -(fade_out_frames + step) * degrees_per_frame
        logo = build_endcard_logo(canvas_size, angle)

        arrived = min(1.0, (step + 1) / fade_in_frames)
        Image.blend(black, logo, arrived).save(
            endcard_folder / f"frame-{frame_number:05d}.png")

    return frame_number


def render_bounce_frames(bounce_folder, opening_folder, scene_layer,
                         screen_center, screen_scale, tilt_degrees,
                         background_color, frame_count):
    """
    Render the drop in as finished frames.

    These cannot be assembled the way the rest of the video is. Everywhere else
    the device is a still that ffmpeg lays the screen over, which works because
    the device never moves. Here it does, and the screen has to grow and shrink
    with it while the background stays put, so each of these frames is composed
    whole: the device and its screen together on one layer, that layer scaled
    about the middle of the picture, and the result set down on the background.

    The screen shows the launcher card, since the drop in happens over the
    opening. It takes the same nearest neighbor treatment as everywhere else.
    """
    bounce_folder.mkdir(parents=True, exist_ok=True)
    for stale_frame in bounce_folder.glob("frame-*.png"):
        stale_frame.unlink()

    canvas_width, canvas_height = scene_layer.size
    screen_center_x, screen_center_y = (round(value) for value in screen_center)

    for frame_index in range(frame_count):
        opening_frame = Image.open(
            opening_folder / f"frame-{frame_index + 1:05d}.png").convert("RGBA")

        screen_picture = opening_frame.resize(
            (SCREEN_WIDTH * screen_scale, SCREEN_HEIGHT * screen_scale),
            Image.NEAREST)
        if tilt_degrees:
            screen_picture = screen_picture.rotate(
                -tilt_degrees, resample=Image.NEAREST, expand=True)

        moving = scene_layer.copy()
        moving.paste(
            screen_picture,
            (screen_center_x - screen_picture.width // 2,
             screen_center_y - screen_picture.height // 2),
            screen_picture)

        scale = bounce_scale_at(frame_index / max(frame_count - 1, 1))
        if abs(scale - 1) > 0.001:
            scaled_size = (round(canvas_width * scale), round(canvas_height * scale))
            moving = moving.resize(scaled_size, Image.LANCZOS)

        canvas = Image.new("RGBA", (canvas_width, canvas_height),
                           tuple(background_color) + (255,))
        canvas.paste(
            moving,
            ((canvas_width - moving.width) // 2, (canvas_height - moving.height) // 2),
            moving)

        canvas.convert("RGB").save(bounce_folder / f"frame-{frame_index + 1:05d}.png")

    return frame_count


def find_screen_from_mask(mask_path):
    """
    Read the screen rectangle out of a mask painted over the device render.

    A mask is worth having because finding the screen automatically does not
    work well. Flooding outward from a dark pixel finds the glass, which
    includes the black surround inside it, and on the render used here that came
    out at an aspect of 1.56 against the screen's 1.667. Close enough to look
    plausible and wrong enough to put the picture visibly out of place.

    The convention is one flat color painted over the active display area. It is
    picked out as the most common fully opaque color in the mask, which works
    because a render's body is full of shading and antialiasing and so never
    lands on one exact value anything like as often as a flat fill does.

    Both checks below are worth having rather than trusting the answer: the
    marked region should be very nearly a solid rectangle, and it should be very
    nearly the shape of the screen.
    """
    mask = Image.open(mask_path).convert("RGBA")
    pixels = mask.load()
    width, height = mask.size

    counts = {}
    for y in range(0, height, 2):
        for x in range(0, width, 2):
            red, green, blue, opacity = pixels[x, y]
            if opacity == 255:
                key = (red, green, blue)
                counts[key] = counts.get(key, 0) + 1

    if not counts:
        raise SystemExit(f"{mask_path.name} has no opaque pixels to read.")

    marker_color = max(counts, key=counts.get)

    left, top, right, bottom = width, height, 0, 0
    marked = 0
    for y in range(height):
        for x in range(width):
            red, green, blue, opacity = pixels[x, y]
            if opacity < 128:
                continue
            if abs(red - marker_color[0]) + abs(green - marker_color[1]) \
                    + abs(blue - marker_color[2]) >= 60:
                continue
            marked += 1
            left = min(left, x)
            right = max(right, x)
            top = min(top, y)
            bottom = max(bottom, y)

    screen_width = right - left + 1
    screen_height = bottom - top + 1

    fill_share = marked / (screen_width * screen_height)
    if fill_share < 0.9:
        print(f"  warning: the marked area in {mask_path.name} fills only "
              f"{fill_share * 100:.0f}% of its own bounding box, so it is not a "
              f"rectangle and the screen position will be wrong.")

    aspect = screen_width / screen_height
    wanted_aspect = SCREEN_WIDTH / SCREEN_HEIGHT
    if abs(aspect - wanted_aspect) / wanted_aspect > 0.02:
        print(f"  warning: the marked area is {aspect:.3f} wide for its height, "
              f"against the screen's {wanted_aspect:.3f}. The picture will be "
              f"stretched or letterboxed.")

    return left, top, screen_width, screen_height


def find_screen_rectangle(device_image):
    """
    Work out where the screen is in a supplied picture of the device.

    The screen is the one large dark area, so it is found by flooding outward
    from points inside it rather than by being told coordinates that would stop
    being true the moment a different render was used. Several starting points
    are tried and the biggest region wins, which keeps a screw head or the
    speaker grille from being mistaken for the screen.

    What that finds is the glass, not the picture. On the render supplied here
    the dark area comes out at an aspect of 1.56 against the screen's 1.667, the
    difference being the black border inside the glass. So a true 400 by 240
    rectangle is fitted inside the dark area and centered, and that is what the
    frames are laid into.
    """
    width, height = device_image.size
    gray = device_image.convert("L").load()
    alpha = device_image.getchannel("A").load()

    def is_screen_pixel(x, y):
        return alpha[x, y] >= 200 and gray[x, y] <= 90

    best_bounds = None
    best_size = 0

    for seed_x_share, seed_y_share in ((0.2, 0.2), (0.3, 0.3), (0.15, 0.35), (0.35, 0.15)):
        seed = (int(width * seed_x_share), int(height * seed_y_share))
        if not is_screen_pixel(*seed):
            continue

        visited = bytearray(width * height)
        pending = [seed]
        left, top, right, bottom = width, height, 0, 0
        filled = 0

        while pending:
            x, y = pending.pop()
            if x < 0 or y < 0 or x >= width or y >= height:
                continue
            offset = y * width + x
            if visited[offset] or not is_screen_pixel(x, y):
                continue
            visited[offset] = 1
            filled += 1
            left = min(left, x)
            right = max(right, x)
            top = min(top, y)
            bottom = max(bottom, y)
            pending.extend(((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)))

        if filled > best_size:
            best_size = filled
            best_bounds = (left, top, right - left + 1, bottom - top + 1)

    if not best_bounds:
        raise SystemExit("Could not find a screen in the device image.")

    glass_left, glass_top, glass_width, glass_height = best_bounds

    # Fit the screen's own shape inside the glass, whichever way round it has to
    # shrink, and center what is left over.
    screen_aspect = SCREEN_WIDTH / SCREEN_HEIGHT
    if glass_width / glass_height > screen_aspect:
        fitted_height = glass_height
        fitted_width = round(fitted_height * screen_aspect)
    else:
        fitted_width = glass_width
        fitted_height = round(fitted_width / screen_aspect)

    return (
        glass_left + (glass_width - fitted_width) // 2,
        glass_top + (glass_height - fitted_height) // 2,
        fitted_width,
        fitted_height,
    )


def prepare_supplied_device(device_path, screen_scale, mask_path=None):
    """
    Take a picture of the device and resize it so its screen is an exact whole
    multiple of the Playdate's resolution.

    This is the opposite way round from how it looks like it should be done, and
    it is the important part. Scaling the frames to fit whatever size the screen
    happens to be in the render would put some source pixels across three output
    pixels and others across four, and on a 1-bit dither that shows as banding.
    The frames therefore keep their exact multiple and the render is moved to
    meet them. A photographic render resizes smoothly and does not care.

    Returns the resized picture, still carrying its transparency, along with the
    rectangle its screen occupies. Tilting and the background come later.
    """
    device_image = Image.open(device_path).convert("RGBA")

    if mask_path:
        screen_left, screen_top, screen_width, _ = find_screen_from_mask(mask_path)
    else:
        screen_left, screen_top, screen_width, _ = find_screen_rectangle(device_image)

    # Resize so the marked area lands just inside the frames rather than exactly
    # on them, taking whichever of the two axes needs the device smaller so that
    # both of them overhang by at least the overscan.
    screen_height = find_screen_from_mask(mask_path)[3] if mask_path else \
        round(screen_width / (SCREEN_WIDTH / SCREEN_HEIGHT))

    frame_width = SCREEN_WIDTH * screen_scale
    frame_height = SCREEN_HEIGHT * screen_scale
    resize_ratio = min(
        (frame_width - 2 * OVERSCAN_PIXELS) / screen_width,
        (frame_height - 2 * OVERSCAN_PIXELS) / screen_height,
    )
    resized_size = (
        round(device_image.width * resize_ratio),
        round(device_image.height * resize_ratio),
    )
    device_image = device_image.resize(resized_size, Image.LANCZOS)

    # The frames are centered on the middle of the marked area, so the overhang
    # is shared evenly on all four sides.
    marked_center_x = (screen_left + screen_width / 2) * resize_ratio
    marked_center_y = (screen_top + screen_height / 2) * resize_ratio

    return device_image, (
        round(marked_center_x - frame_width / 2),
        round(marked_center_y - frame_height / 2),
        frame_width,
        frame_height,
    )


def find_supplied_device_image(frame_folder):
    """
    Look for a render of the device dropped into the frame folder.

    Anything that is not a captured frame and not the composed device picture
    this tool writes itself. One stray file is taken as the answer; more than one
    is ambiguous, so nothing is chosen and the drawn device is used instead.
    """
    candidates = [
        path for path in sorted(frame_folder.glob("*.png"))
        if not path.name.startswith("frame-")
        and path.name not in ("device.png", DEVICE_MASK_NAME)
    ]
    return candidates[0] if len(candidates) == 1 else None


def build_device_image():
    """
    Draw the handheld the video sits inside, and say where its screen is.

    Returns a transparent layer and the rectangle its screen occupies, the same
    shape of answer a supplied render gives, so that both go through the same
    tilting and backgrounding afterward. The screen is left as flat black, which
    means the frames can simply be laid on top of it rather than needing a hole
    cut in the device.

    No wordmark and no branding. This reads as the device it is meant to read as
    without borrowing anyone's logo to do it.
    """
    canvas = Image.new("RGBA", (CANVAS_WIDTH, CANVAS_HEIGHT), (0, 0, 0, 0))
    painter = ImageDraw.Draw(canvas)

    body_left = (CANVAS_WIDTH - DEVICE_BODY_WIDTH) // 2
    body_top = (CANVAS_HEIGHT - DEVICE_BODY_HEIGHT) // 2

    painter.rounded_rectangle(
        [body_left, body_top,
         body_left + DEVICE_BODY_WIDTH, body_top + DEVICE_BODY_HEIGHT],
        radius=64, fill=BODY_COLOR, outline=BODY_EDGE_COLOR, width=3)

    screen_width = SCREEN_WIDTH * SCALE_FACTOR
    screen_height = SCREEN_HEIGHT * SCALE_FACTOR
    screen_left = body_left + (DEVICE_BODY_WIDTH - screen_width) // 2
    screen_top = body_top + round(DEVICE_BODY_HEIGHT * DEVICE_SCREEN_TOP_SHARE)

    # The bezel is a slightly larger black rectangle behind the screen, which is
    # what stops the picture from appearing to float on the yellow.
    bezel_margin = 20
    painter.rounded_rectangle(
        [screen_left - bezel_margin, screen_top - bezel_margin,
         screen_left + screen_width + bezel_margin,
         screen_top + screen_height + bezel_margin],
        radius=16, fill=(24, 24, 24))

    painter.rectangle(
        [screen_left, screen_top,
         screen_left + screen_width, screen_top + screen_height],
        fill=(0, 0, 0))

    # Everything below the screen is the control area.
    controls_middle = screen_top + screen_height + \
        (body_top + DEVICE_BODY_HEIGHT - screen_top - screen_height) // 2

    # The directional pad, drawn as two crossed bars with rounded ends.
    pad_center_x = body_left + round(DEVICE_BODY_WIDTH * 0.20)
    pad_arm = 62
    pad_thickness = 46
    painter.rounded_rectangle(
        [pad_center_x - pad_arm, controls_middle - pad_thickness // 2,
         pad_center_x + pad_arm, controls_middle + pad_thickness // 2],
        radius=10, fill=CONTROL_COLOR)
    painter.rounded_rectangle(
        [pad_center_x - pad_thickness // 2, controls_middle - pad_arm,
         pad_center_x + pad_thickness // 2, controls_middle + pad_arm],
        radius=10, fill=CONTROL_COLOR)

    # A and B, set on a diagonal the way they are on the real thing, with A the
    # upper right of the pair.
    button_radius = 44
    b_center_x = body_left + round(DEVICE_BODY_WIDTH * 0.72)
    a_center_x = body_left + round(DEVICE_BODY_WIDTH * 0.85)
    for center_x, center_y in (
        (b_center_x, controls_middle + 34),
        (a_center_x, controls_middle - 26),
    ):
        painter.ellipse(
            [center_x - button_radius, center_y - button_radius,
             center_x + button_radius, center_y + button_radius],
            fill=CONTROL_COLOR)

    # The crank, folded away against the right edge where it lives when it is not
    # being used, sitting in its own recess.
    crank_right = body_left + DEVICE_BODY_WIDTH - 16
    crank_left = crank_right - 34
    crank_top = screen_top - 10
    crank_bottom = screen_top + screen_height + 40
    painter.rounded_rectangle(
        [crank_left - 6, crank_top - 6, crank_right + 6, crank_bottom + 6],
        radius=22, fill=BODY_EDGE_COLOR)
    painter.rounded_rectangle(
        [crank_left, crank_top, crank_right, crank_bottom],
        radius=17, fill=CRANK_COLOR)

    # The knob on the end of the crank arm.
    knob_radius = 25
    knob_center_y = crank_bottom - 26
    painter.ellipse(
        [crank_left + 17 - knob_radius, knob_center_y - knob_radius,
         crank_left + 17 + knob_radius, knob_center_y + knob_radius],
        fill=CONTROL_COLOR)

    # The speaker, a short row of holes under the screen.
    speaker_y = screen_top + screen_height + 46
    for hole_index in range(6):
        hole_x = body_left + round(DEVICE_BODY_WIDTH * 0.46) + hole_index * 22
        painter.ellipse(
            [hole_x - 6, speaker_y - 6, hole_x + 6, speaker_y + 6],
            fill=BODY_EDGE_COLOR)

    return canvas, (screen_left, screen_top,
                    SCREEN_WIDTH * SCALE_FACTOR, SCREEN_HEIGHT * SCALE_FACTOR)


def rotated_size(width, height, degrees):
    """
    How big a rectangle's bounding box becomes once it has been turned.

    Rounded up, so the turned picture is never clipped by a box a pixel too
    small, and forced even because the overlay is placed by halving it.
    """
    radians = math.radians(degrees)
    turned_width = math.ceil(
        abs(width * math.cos(radians)) + abs(height * math.sin(radians)))
    turned_height = math.ceil(
        abs(width * math.sin(radians)) + abs(height * math.cos(radians)))
    return turned_width + turned_width % 2, turned_height + turned_height % 2


def build_ffmpeg_command(frame_folder, manifest, audio_path, output_path,
                         opening_folder=None, opening_frame_count=0,
                         device_path=None, screen_center_x=0, screen_center_y=0,
                         screen_scale=SCALE_FACTOR, tilt_degrees=0,
                         bounce_folder=None, bounce_frame_count=0,
                         pixel_format="yuv420p", outro_folder=None,
                         outro_frame_count=0, middle_app_frames=None,
                         quality=16, output_width=None,
                         background_color=BACKGROUND_COLOR,
                         endcard_folder=None, endcard_frame_count=0):
    frames_per_second = int(manifest.get("framesPerSecond", 30))
    playback_start_frame = int(manifest.get("playbackStartFrame", 0))
    playback_start_position = float(manifest.get("playbackStartPosition", 0.0))

    # The video begins at frame one, but the music does not start until the demo
    # has browsed the library and pressed play, so the audio is held back by
    # however long that took. The launcher opening sits in front of all of it and
    # pushes the music back by its own length as well.
    silence_before_audio_in_milliseconds = round(
        ((opening_frame_count + playback_start_frame) / frames_per_second) * 1000
    )

    scale_expression = f"scale=iw*{screen_scale}:ih*{screen_scale}:flags=neighbor"
    background_pad = "0x%02x%02x%02x" % tuple(background_color)

    command = ["ffmpeg", "-y"]

    # The drop in has already used the first stretch of the opening, so the
    # opening picks up where it left off. Both together still come to the same
    # number of frames, which is why the audio delay above does not change.
    remaining_opening = opening_frame_count - bounce_frame_count

    if remaining_opening > 0:
        command += [
            "-framerate", str(frames_per_second),
            "-start_number", str(bounce_frame_count + 1),
            "-i", str(opening_folder / "frame-%05d.png"),
        ]

    command += [
        "-framerate", str(frames_per_second),
        "-i", str(frame_folder / "frame-%05d.png"),

        # Seek into the audio to wherever the playhead was when the music
        # started, which is normally zero but will not be if the script ever
        # begins part way through a track.
        "-ss", f"{playback_start_position:.3f}",
        "-i", str(audio_path),
    ]

    app_input = 1 if remaining_opening > 0 else 0

    # The app's frames stop where the closing turn takes over, since the turn
    # renders its own copies of the rest.
    app_trim = ""
    if middle_app_frames is not None:
        app_trim = f"trim=end_frame={middle_app_frames},setpts=PTS-STARTPTS,"

    audio_input = 2 if remaining_opening > 0 else 1

    # Everything the finished video is made of, for working out where the fade
    # out starts.
    total_video_frames = (
        bounce_frame_count + remaining_opening
        + (middle_app_frames or 0) + outro_frame_count + endcard_frame_count)

    # The device goes on last so that adding it does not renumber the inputs the
    # rest of the graph already refers to. It is a single still, so it has to be
    # looped, and the frames are what decide the length.
    if device_path:
        command += ["-loop", "1", "-i", str(device_path)]
        device_input = audio_input + 1

    if bounce_frame_count:
        command += [
            "-framerate", str(frames_per_second),
            "-i", str(bounce_folder / "frame-%05d.png"),
        ]
        bounce_input = device_input + 1

    if outro_frame_count:
        command += [
            "-framerate", str(frames_per_second),
            "-i", str(outro_folder / "frame-%05d.png"),
        ]
        outro_input = (bounce_input if bounce_frame_count else device_input) + 1

    if endcard_frame_count:
        command += [
            "-framerate", str(frames_per_second),
            "-i", str(endcard_folder / "frame-%05d.png"),
        ]
        last_input = outro_input if outro_frame_count else (
            bounce_input if bounce_frame_count else device_input)
        endcard_input = last_input + 1

    # Only the app's frames are negated. The launcher is not Spindle and does not
    # run inverted, so its frames are already the right way round and flipping
    # them would give a white card on a black backdrop.
    #
    # The two sequences are scaled after being joined rather than before, so
    # there is one scale rather than two and no chance of them disagreeing.
    if remaining_opening > 0:
        screen_chain = (
            "[0:v]format=gray[opening];"
            f"[{app_input}:v]{app_trim}negate,format=gray[app];"
            f"[opening][app]concat=n=2:v=1:a=0,{scale_expression},format=rgb24[screen];"
        )
    else:
        screen_chain = (
            f"[{app_input}:v]{app_trim}negate,{scale_expression},format=rgb24[screen];"
        )

    if device_path:
        # The frames are turned by the same angle as the device, so they sit
        # square in a screen that is no longer square to the frame. Nearest
        # neighbor, because rotating a 1-bit dither with any smoothing turns it
        # into the gray mush the whole pipeline is arranged to avoid.
        #
        # Rotating grows the picture's bounding box, and the rotate filter puts
        # the original in the middle of that box, so the box is centered on where
        # the screen ended up rather than being placed by its corner.
        turned_width, turned_height = rotated_size(
            SCREEN_WIDTH * screen_scale, SCREEN_HEIGHT * screen_scale, tilt_degrees)

        if tilt_degrees:
            screen_chain += (
                f"[screen]format=rgba,"
                f"rotate=a={tilt_degrees}*PI/180:ow={turned_width}:oh={turned_height}"
                f":c=none:bilinear=0[turned];"
            )
        else:
            screen_chain += "[screen]format=rgba[turned];"

        video_chain = (
            f"[{device_input}:v][turned]"
            f"overlay=x={screen_center_x - turned_width // 2}"
            f":y={screen_center_y - turned_height // 2}:shortest=1[settled];"
        )
    else:
        video_chain = "[screen]copy[settled];"

    # The drop in and the closing turn are already finished pictures, device and
    # screen and background together, so they are simply joined on either end.
    joined = []
    if bounce_frame_count:
        video_chain += f"[{bounce_input}:v]format=rgb24,setsar=1[dropin];"
        joined.append("[dropin]")

    joined.append("[settled]")

    if outro_frame_count:
        video_chain += f"[{outro_input}:v]format=rgb24,setsar=1[closing];"
        joined.append("[closing]")

    if endcard_frame_count:
        video_chain += f"[{endcard_input}:v]format=rgb24,setsar=1[endcard];"
        joined.append("[endcard]")

    if len(joined) > 1:
        video_chain += f"{''.join(joined)}concat=n={len(joined)}:v=1:a=0"
    else:
        video_chain += "[settled]copy"

    # An optional last resize, kept aligned to macroblocks for the same reason
    # the canvas is. Lanczos rather than nearest here, because this is resizing a
    # finished picture with a photographic render in it rather than a 1-bit
    # dither, and there is nothing left to keep crisp by refusing to interpolate.
    if output_width:
        video_chain += (f",scale={output_width}:-1:flags=lanczos,"
                        f"pad=ceil(iw/16)*16:ceil(ih/16)*16:0:0:{background_pad}")

    video_chain += "[v];"

    # The music finishes where the demo does, not where the closing card does.
    #
    # The fade lands on the end of the video rather than starting there, so the
    # sound is already gone by the time the picture begins fading to black. That
    # puts the last of the music at the same moment it ended before the card
    # existed, and it means the card is silent from its first frame rather than
    # having the tail of a song running under it.
    audio_chain = f"[{audio_input}:a]adelay={silence_before_audio_in_milliseconds}:all=1"
    if endcard_frame_count:
        video_ends_at = (total_video_frames - endcard_frame_count) / frames_per_second
        fade_starts_at = max(0.0, video_ends_at - ENDCARD_FADE_OUT_SECONDS)
        audio_chain += (f",afade=t=out:st={fade_starts_at:.3f}"
                        f":d={ENDCARD_FADE_OUT_SECONDS}")
    audio_chain += "[a]"

    filter_graph = (
        screen_chain
        + video_chain
        + audio_chain
    )

    command += [
        "-filter_complex", filter_graph,
        "-map", "[v]",
        "-map", "[a]",
        "-c:v", "libx264",
        "-preset", "slow",
        "-crf", str(quality),

        # These three are all about the flat background, which is most of the
        # picture and the hardest thing here to encode well.
        #
        # psy-rd is on by default and deliberately adds detail that was not in
        # the source, on the theory that it looks sharper. Against a large area
        # of one flat color it does the opposite: it shows as blocky lighter
        # patches, and while the device is flying around they get dragged into
        # the background and left there. aq-mode 3 pushes bits toward flat and
        # dark areas, which is where they are needed rather than on the device.
        # A keyframe every second stops anything that does slip through from
        # living on for the rest of the video.
        "-x264-params", "psy-rd=0:aq-mode=3",
        "-g", str(frames_per_second),

        "-pix_fmt", pixel_format,
        "-c:a", "aac",
        "-b:a", "192k",

        # The frames decide the length. Without this the audio would keep the
        # video alive past its last frame on a still picture.
        "-shortest",
        str(output_path),
    ]

    return command


def main():
    parser = argparse.ArgumentParser(
        description="Mux demo frames and the original audio into a video.")
    parser.add_argument("--audio", required=True,
                        help="the source audio file the played track was converted from")
    parser.add_argument("--frames", default=DEFAULT_FRAME_FOLDER, type=Path,
                        help=f"folder of frame PNGs (default {DEFAULT_FRAME_FOLDER})")
    parser.add_argument("--manifest", default=DEFAULT_MANIFEST, type=Path,
                        help="the manifest the recorder wrote")
    parser.add_argument("--out", default=DEFAULT_OUTPUT, type=Path,
                        help=f"where to write the video (default {DEFAULT_OUTPUT})")
    parser.add_argument("--opening-seconds", default=3.0, type=float,
                        help="launcher card shown before the app, zero to skip it")
    parser.add_argument("--device", action=argparse.BooleanOptionalAction, default=True,
                        help="set the picture into a picture of the handheld")
    parser.add_argument("--device-image", default=None, type=Path,
                        help="a render of the device to use instead of the drawn one. "
                             "Found automatically if a single stray PNG is sitting in "
                             "the frame folder")
    parser.add_argument("--device-mask", default=None, type=Path,
                        help=f"a copy of the device render with the screen painted in "
                             f"one flat color. Found automatically as {DEVICE_MASK_NAME} "
                             f"in the frame folder")
    parser.add_argument("--screen-scale", default=None, type=int,
                        help="whole multiple of 400 by 240 the screen is drawn at")
    parser.add_argument("--end-at", default=None, type=parse_timecode,
                        help="where the video should finish, in seconds or as "
                             "minutes:seconds, for example 1:05.10")
    parser.add_argument("--outro-seconds", default=OUTRO_SECONDS, type=float,
                        help="how long the device takes to turn back square at the "
                             "end, zero to leave it leaning")
    parser.add_argument("--endcard", action=argparse.BooleanOptionalAction, default=True,
                        help="fade to black at the end and finish on the spinning logo")
    parser.add_argument("--output-width", default=None, type=int,
                        help="resize the finished video to this width, keeping the "
                             "aspect. Useful if the full size one is more than "
                             "anything needs")
    parser.add_argument("--crf", default=16, type=int,
                        help="x264 quality, lower is better and larger")
    parser.add_argument("--pixel-format", default="yuv420p",
                        help="yuv420p plays everywhere. yuv444p keeps full color "
                             "detail, which matters on a saturated edge like yellow "
                             "against purple, but needs a player that handles the "
                             "High 4:4:4 profile")
    parser.add_argument("--bounce-seconds", default=BOUNCE_SECONDS, type=float,
                        help="how long the device takes to drop in and settle, "
                             "zero for no drop in")
    parser.add_argument("--tilt", default=TILT_DEGREES, type=float,
                        help="degrees to lean the device clockwise")
    parser.add_argument("--margin", default=MARGIN_SHARE, type=float,
                        help="space around the device, as a share of its width")
    parser.add_argument("--background", default=BACKGROUND_COLOR, type=parse_color,
                        help="background color behind the device, as a hex value")
    arguments = parser.parse_args()

    if shutil.which("ffmpeg") is None:
        print("ffmpeg is not on the path", file=sys.stderr)
        return 1

    audio_path = Path(arguments.audio).expanduser()
    if not audio_path.exists():
        print(f"No audio file at {audio_path}", file=sys.stderr)
        return 1

    if not arguments.manifest.exists():
        print(f"No manifest at {arguments.manifest}. Has the recorder finished?",
              file=sys.stderr)
        return 1

    frame_files = sorted(arguments.frames.glob("frame-*.png"))
    if not frame_files:
        print(f"No frames in {arguments.frames}", file=sys.stderr)
        return 1

    manifest = read_manifest(arguments.manifest)
    frames_per_second = int(manifest.get("framesPerSecond", 30))

    # The recorder says how many frames it wrote. If fewer arrived, the run was
    # cut short, and saying so beats producing a video that stops halfway
    # through and leaving it to be discovered on playback.
    expected_frames = int(manifest.get("frameCount", len(frame_files)))
    if len(frame_files) < expected_frames:
        print(f"  warning: manifest says {expected_frames} frames, found "
              f"{len(frame_files)}. The recording was cut short.")

    # The audio is played straight through, so the picture only stays with it if
    # the playhead advanced at exactly one second per second. Anything that moved
    # it, a crank scrub, a ten second seek, a pause, breaks that for the whole
    # rest of the video. The recorder writes down where the playhead started and
    # finished, and the frames say how much time should have passed between
    # those two moments, so the two can be compared rather than trusted.
    playback_start_frame = int(manifest.get("playbackStartFrame", 0))
    start_position = float(manifest.get("playbackStartPosition", 0.0))
    end_position = float(manifest.get("playbackEndPosition", 0.0))

    if end_position > 0:
        frames_while_playing = len(frame_files) - playback_start_frame
        expected_advance = frames_while_playing / frames_per_second
        actual_advance = end_position - start_position
        drift = actual_advance - expected_advance

        if abs(drift) > 0.2:
            print(f"  warning: the playhead moved {actual_advance:.1f}s while "
                  f"{expected_advance:.1f}s of frames went by, a difference of "
                  f"{drift:+.1f}s.")
            print("           Something in the script scrubbed, seeked or paused, "
                  "and the sound will not match the picture after that point.")
        else:
            print(f"  playhead and frames agree to within {abs(drift):.2f}s")

    print(f"  {len(frame_files)} frames at {frames_per_second} fps, "
          f"{len(frame_files) / frames_per_second:.1f} seconds")
    print(f"  playing {manifest.get('albumArtist')} / {manifest.get('trackTitle')}")
    print(f"  music starts at frame {manifest.get('playbackStartFrame')}")
    print(f"  audio from {audio_path.name}")

    opening_folder = arguments.frames / "opening"
    opening_frame_count = 0
    if arguments.opening_seconds > 0:
        opening_frame_count = render_opening_frames(
            opening_folder, arguments.opening_seconds, frames_per_second)
        print(f"  rendered {opening_frame_count} launcher frames in front")

    device_path = None
    screen_center_x = 0
    screen_center_y = 0
    screen_scale = arguments.screen_scale or SCALE_FACTOR

    if arguments.device:
        supplied = arguments.device_image or find_supplied_device_image(arguments.frames)

        if supplied:
            mask_path = arguments.device_mask
            if mask_path is None and (arguments.frames / DEVICE_MASK_NAME).exists():
                mask_path = arguments.frames / DEVICE_MASK_NAME

            # A supplied render carries far more detail than a drawing, so it is
            # worth showing larger. Two gives an 800 by 480 screen, which keeps
            # the finished video a sensible size once the tilt has grown it.
            screen_scale = arguments.screen_scale or 2
            device_layer, screen_rect = prepare_supplied_device(
                supplied, screen_scale, mask_path)
            print(f"  device from {supplied.name}"
                  + (f", screen from {mask_path.name}" if mask_path else ""))
        else:
            device_layer, screen_rect = build_device_image()
            print("  device drawn")

        # Sized from the widest tilt and then held, because the device turns
        # back square at the end and a canvas that followed it would be a video
        # that changes size part way through.
        canvas_size = canvas_size_for(device_layer, arguments.tilt, arguments.margin)
        scene_layer, screen_center_x, screen_center_y = place_device(
            device_layer, screen_rect, arguments.tilt, canvas_size)
        screen_center_x = round(screen_center_x)
        screen_center_y = round(screen_center_y)
        scene = flatten_onto_background(scene_layer, arguments.background)

        device_path = arguments.frames / "device.png"
        scene.save(device_path)
        print(f"  scene {scene.width} by {scene.height}, tilted {arguments.tilt:g} "
              f"degrees, screen {SCREEN_WIDTH * screen_scale} by "
              f"{SCREEN_HEIGHT * screen_scale} centered at "
              f"{screen_center_x}, {screen_center_y}")

    # The drop in eats the first stretch of the opening, so the total length of
    # the video is unchanged and the audio delay worked out below still holds.
    bounce_folder = arguments.frames / "bounce"
    bounce_frame_count = 0
    if opening_frame_count and arguments.device and arguments.bounce_seconds > 0:
        bounce_frame_count = min(
            round(arguments.bounce_seconds * frames_per_second),
            opening_frame_count)
        render_bounce_frames(
            bounce_folder, opening_folder, scene_layer,
            (screen_center_x, screen_center_y), screen_scale, arguments.tilt,
            arguments.background, bounce_frame_count)
        print(f"  {bounce_frame_count} frames of drop in, "
              f"starting {(1 + BOUNCE_OVERSHOOT):.2f} times size")

    # How long the finished video runs. Everything else is measured back from
    # here, so the closing turn always lands on the last frame rather than
    # somewhere near it.
    total_frames = len(frame_files) + opening_frame_count
    if arguments.end_at:
        wanted = round(arguments.end_at * frames_per_second)
        if wanted > total_frames:
            print(f"  warning: asked to end at {arguments.end_at:.2f}s but there are "
                  f"only {total_frames / frames_per_second:.2f}s of frames.")
        total_frames = min(wanted, total_frames)

    outro_folder = arguments.frames / "outro"
    outro_frame_count = 0
    if arguments.device and arguments.outro_seconds > 0 and arguments.tilt:
        outro_frame_count = min(
            round(arguments.outro_seconds * frames_per_second),
            total_frames - opening_frame_count)

    # The app's frames fill everything between the opening and the closing turn.
    middle_app_frames = total_frames - opening_frame_count - outro_frame_count

    if outro_frame_count:
        render_outro_frames(
            outro_folder, arguments.frames, middle_app_frames + 1,
            device_layer, screen_rect, canvas_size, screen_scale,
            arguments.tilt, arguments.background, outro_frame_count)
        print(f"  {outro_frame_count} frames of closing turn, "
              f"{arguments.tilt:g} degrees back to square")

    print(f"  finished video is {total_frames} frames, "
          f"{total_frames / frames_per_second:.2f} seconds")

    endcard_folder = arguments.frames / "endcard"
    endcard_frame_count = 0
    if arguments.endcard:
        last_video_frame = None
        if outro_frame_count:
            last_video_frame = outro_folder / f"frame-{outro_frame_count:05d}.png"
        endcard_frame_count = render_endcard_frames(
            endcard_folder, last_video_frame, canvas_size, frames_per_second)
        print(f"  {endcard_frame_count} frames of closing card, "
              f"{endcard_frame_count / frames_per_second:.1f} seconds after the end")

    command = build_ffmpeg_command(
        arguments.frames, manifest, audio_path, arguments.out,
        opening_folder, opening_frame_count,
        device_path, screen_center_x, screen_center_y, screen_scale,
        arguments.tilt, bounce_folder, bounce_frame_count,
        arguments.pixel_format, outro_folder, outro_frame_count,
        middle_app_frames, arguments.crf, arguments.output_width,
        arguments.background, endcard_folder, endcard_frame_count)

    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        print("ffmpeg failed:", file=sys.stderr)
        print(result.stderr[-2000:], file=sys.stderr)
        return 1

    print(f"\nWrote {arguments.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
