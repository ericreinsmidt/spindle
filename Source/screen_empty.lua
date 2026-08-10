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
end


function ScreenEmpty.update()
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

    -- Drawn the way a cover is drawn, flip and all, so it reads as a blank
    -- sleeve sitting where a record would be rather than as an icon.
    Artwork.drawCoverMark(
        (400 - ADAPTER_SIZE) // 2, ADAPTER_TOP, ADAPTER_SIZE)
end
