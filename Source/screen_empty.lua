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
local ADAPTER_TOP <const> = 2
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

local HEADING_TOP <const> = 146
local BODY_TOP <const> = 176
local BODY_LINE_HEIGHT <const> = 18

-- Short lines, and short here means under about 39 characters, which is what a
-- 400 pixel screen holds at roughly 9.6 pixels a character.
--
-- This points at the documentation rather than reciting a step. It used to name
-- the folder the library is copied into, which is one step out of five and is
-- worse than naming none: somebody who has not converted anything yet cannot use
-- it, and somebody who has does not need it. A URL is the one thing that leads
-- to all of it, and it is short enough to read off the screen and type.
local INSTRUCTIONS <const> = {
    "It has to be converted on a computer.",
    "Steps and tools at",
    "github.com/ericreinsmidt/spindle",
}


-- Centered by measuring the text rather than by counting characters, since
-- counting characters is what got the first layout wrong.
local function drawCentered(text, top)
    graphics.drawText(text, (400 - graphics.getTextSize(text)) // 2, top)
end


function ScreenEmpty.enter()
    ScreenEmpty.angleInDegrees = 0
end


function ScreenEmpty.update()
    -- The crank takes over from the idle turn while it is moving, rather than
    -- adding to it. Adding would mean the adapter never quite stops when you
    -- hold the crank still, which reads as the crank not being connected to it.
    local crankDelta = playdate.getCrankChange()
    if crankDelta ~= 0 then
        ScreenEmpty.angleInDegrees = ScreenEmpty.angleInDegrees + crankDelta
    else
        ScreenEmpty.angleInDegrees = ScreenEmpty.angleInDegrees
            + IDLE_DEGREES_PER_SECOND / FRAMES_PER_SECOND
    end

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
end
