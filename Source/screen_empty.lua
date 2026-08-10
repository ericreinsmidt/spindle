-- What Spindle shows when there is no library on the device yet.
--
-- This is not an error screen, and the difference matters more than it sounds.
-- Every first run lands here, and so does every reviewer who installs the app
-- before they have converted any music, which means it is the first and possibly
-- only thing some people will ever see. A line reading "library.json could not
-- be read" tells those people the app is broken. It is not broken; it is empty,
-- the way a record player with nothing on it is empty.
--
-- A library that is present but will not load is a real fault and still goes to
-- the error text in main.lua. Only an absent one comes here.

ScreenEmpty = {}

local graphics <const> = playdate.graphics

-- The adapter above, the words below, everything centered.
--
-- Side by side was tried first and there is not room for it. The body font runs
-- about 9.6 pixels a character, so a column beside a 140 pixel mark leaves about
-- 23 characters, and the one line that has to survive intact is the path the
-- library goes to, which is 28. Stacking gives the text the whole 400.
--
-- 140 because that is a size the adapter mark already exists at. Shrinking the
-- large one to some other size would be resampling a 1-bit image, which is what
-- turns artwork into noise.
local ADAPTER_SIZE <const> = 140
local ADAPTER_TOP <const> = 20
local ADAPTER_LEFT <const> = (400 - ADAPTER_SIZE) // 2

-- The adapter turns, and the crank turns it.
--
-- The crank is the whole interaction model of this app and a new install has
-- nothing else to demonstrate it on, so the first screen anybody sees is also
-- the one that teaches it. It costs one image blit a frame.
--
-- Sixty frames over the 120 degrees the shape repeats in, so two degrees each.
local SPIN_FRAME_COUNT <const> = 60
local SPIN_DEGREES_PER_FRAME <const> = 120 / SPIN_FRAME_COUNT

-- What it does when nobody is touching it. Slow enough to read as idling rather
-- than as playing something.
local IDLE_DEGREES_PER_SECOND <const> = 24
local FRAMES_PER_SECOND <const> = 30

local spinFrames <const> = graphics.imagetable.new("adapter-spin")

-- Set so the adapter, the heading and the one line under it sit as a block in
-- the middle of the screen. They used to be pushed to the top, which was right
-- when there were three lines of instructions under them and leaves a hole now
-- that there is one.
local HEADING_TOP <const> = 166
local BODY_TOP <const> = 200
local BODY_LINE_HEIGHT <const> = 18

-- Short lines, and short here means under about 39 characters, which is what a
-- 400 pixel screen holds at roughly 9.6 pixels a character.
--
-- One line, pointing at the one thing that explains all of it.
--
-- Earlier drafts of this tried to be the instructions: what to convert, what
-- with, where to put it. None of that fits on a 400 pixel screen and none of it
-- has to, because the app now writes a README into the folder it is naming. This
-- only has to get somebody to that file.
--
-- The full path is left out on purpose. Data folder is what a person needs to go
-- looking for; com.reinsmidt.spindle is what they will see when they get there.
local INSTRUCTIONS <const> = {
    "See README in Data folder",
}


-- The speed readout, and the thing it is really for.
--
-- It appears only while the crank is being used, so an idle screen stays clean
-- and turning the crank is what reveals it. Once it is there, a number climbing
-- toward a familiar one is an invitation, and 45 is the number this whole app is
-- named after.
--
-- Held to the left of the adapter rather than under it, because the space under
-- it belongs to the heading and there are only 14 spare pixels on this screen.
-- Tied to the adapter rather than written down, so moving one moves the other
-- and the readout cannot end up floating beside nothing.
local RPM_READOUT_RIGHT <const> = ADAPTER_LEFT - 14
local RPM_READOUT_TOP <const> = ADAPTER_TOP + ADAPTER_SIZE // 2 - 11

local TARGET_RPM <const> = 45

-- Wide enough to be reachable by hand and narrow enough to feel found. At 45 rpm
-- the crank is turning 270 degrees a second, so this is about a sixth of a turn
-- a second either side of it.
local RPM_TOLERANCE <const> = 2.5

-- A hand on a crank is not steady, and an unsmoothed reading flickers several
-- rpm between frames, which makes the target impossible to sit on.
local SPEED_SMOOTHING <const> = 0.25

-- How long the readout stays up after the crank stops, so it does not vanish
-- the instant you pause.
local READOUT_LINGER_FRAMES <const> = 45

local DEGREES_PER_SECOND_IN_ONE_RPM <const> = 6


-- Centered by measuring the text rather than by counting characters, since
-- counting characters is what got the first layout wrong.
local function drawCentered(text, top)
    graphics.drawText(text, (400 - graphics.getTextSize(text)) // 2, top)
end


-- How fast the crank is turning, in rpm, and whether that happens to be 45.
local function drawSpeedReadout()
    if ScreenEmpty.framesSinceCranked >= READOUT_LINGER_FRAMES then
        return
    end

    local revolutionsPerMinute = math.abs(ScreenEmpty.smoothedDegreesPerSecond)
        / DEGREES_PER_SECOND_IN_ONE_RPM
    local label = string.format("%d rpm", math.floor(revolutionsPerMinute + 0.5))

    graphics.setFont(Typography.body)
    local labelWidth = graphics.getTextSize(label)
    local left = RPM_READOUT_RIGHT - labelWidth

    if math.abs(revolutionsPerMinute - TARGET_RPM) <= RPM_TOLERANCE then
        -- Landed on it. The readout inverts, which on a screen this size is
        -- more legible than anything drawn around the adapter and does not
        -- fight the heading for room.
        --
        -- Black fills and white glyphs, because the display is inverted on the
        -- way out, so this comes off the screen as a lit box with dark type.
        graphics.fillRect(left - 5, RPM_READOUT_TOP - 3, labelWidth + 10, 22)
        graphics.setImageDrawMode(graphics.kDrawModeFillWhite)
        graphics.drawText(label, left, RPM_READOUT_TOP)
        graphics.setImageDrawMode(graphics.kDrawModeCopy)
    else
        graphics.drawText(label, left, RPM_READOUT_TOP)
    end
end


function ScreenEmpty.enter()
    ScreenEmpty.angleInDegrees = 0
    ScreenEmpty.smoothedDegreesPerSecond = 0
    ScreenEmpty.framesSinceCranked = READOUT_LINGER_FRAMES
end


function ScreenEmpty.update()
    -- The crank takes over from the idle turn while it is moving, rather than
    -- adding to it. Adding would mean the adapter never quite stops when you
    -- hold the crank still, which reads as the crank not being connected to it.
    local crankDelta = playdate.getCrankChange()
    if crankDelta ~= 0 then
        ScreenEmpty.angleInDegrees = ScreenEmpty.angleInDegrees + crankDelta
        ScreenEmpty.framesSinceCranked = 0
    else
        ScreenEmpty.angleInDegrees = ScreenEmpty.angleInDegrees
            + IDLE_DEGREES_PER_SECOND / FRAMES_PER_SECOND
        ScreenEmpty.framesSinceCranked = ScreenEmpty.framesSinceCranked + 1
    end

    -- Smoothed rather than read straight off the frame. The idle turn is left
    -- out of it on purpose: the readout is a measure of what you are doing, and
    -- reporting 4 rpm at rest would make it look like a broken speedometer.
    local instantDegreesPerSecond = crankDelta * FRAMES_PER_SECOND
    ScreenEmpty.smoothedDegreesPerSecond =
        ScreenEmpty.smoothedDegreesPerSecond
        + (instantDegreesPerSecond - ScreenEmpty.smoothedDegreesPerSecond)
        * SPEED_SMOOTHING

    -- Nothing to go to. There is no library, so every other screen would be
    -- empty as well, and a button that appears to do nothing is worse than one
    -- that plainly does nothing.
    return nil
end


function ScreenEmpty.draw()
    -- Music rather than records or albums. A record is what this app is about
    -- and it is what the artwork is, but on its own the word can be read as a
    -- row in a file, which is the one reading that makes an empty screen sound
    -- like a fault. Albums is accurate and narrower, since playlists are here
    -- too. Music is what is actually missing.
    graphics.setFont(Typography.large)
    drawCentered("No music yet", HEADING_TOP)

    graphics.setFont(Typography.body)
    for lineNumber, line in ipairs(INSTRUCTIONS) do
        drawCentered(line, BODY_TOP + (lineNumber - 1) * BODY_LINE_HEIGHT)
    end

    -- The bare shape with nothing behind it, so it reads as a record rather
    -- than as a sleeve. The frames are cut out, meaning black plastic on
    -- nothing, and black is what the inverted display turns white.
    --
    -- Lua's modulo takes the sign of its divisor, so cranking backward past zero
    -- lands on the last frame rather than on a negative index.
    local frameNumber = math.floor(
        ScreenEmpty.angleInDegrees / SPIN_DEGREES_PER_FRAME) % SPIN_FRAME_COUNT

    -- Set explicitly, because artwork.lua draws covers inverted and whichever
    -- screen ran last leaves its own mode selected.
    graphics.setImageDrawMode(graphics.kDrawModeCopy)
    spinFrames:getImage(frameNumber + 1):draw(ADAPTER_LEFT, ADAPTER_TOP)

    drawSpeedReadout()
end
