-- Drawing pictures so they stay pictures on an inverted display.
--
-- Spindle runs white on black, set once at startup with
-- playdate.display.setInverted. That flips the whole display after everything
-- has been drawn, which is what makes it free: no drawing code has to know
-- about it. It is right for type and line work, and wrong for a photograph. An
-- inverted album cover is a negative, and a negative of a face does not read as
-- a face.
--
-- So covers are flipped on the way in, and the display's flip on the way out
-- cancels it. kDrawModeInverted is the image draw mode that does it, so this
-- costs nothing beyond setting a mode either side of the draw.
--
-- Album art is the only thing treated this way. Everything else on screen is
-- type or line work, which is supposed to follow the setting.
--
-- This was a toggle for a while, with a flag saying which way round the display
-- currently was and a branch in each of these. Inversion is now what the app
-- looks like rather than a preference, so the flag could only ever hold one
-- value and the branches have gone with it.

import "CoreLibs/graphics"

Artwork = {}

local graphics <const> = playdate.graphics


-- Draw a picture the right way up on a display that is about to flip it.
function Artwork.draw(image, left, top)
    graphics.setImageDrawMode(graphics.kDrawModeInverted)
    image:draw(left, top)
    graphics.setImageDrawMode(graphics.kDrawModeCopy)
end


-- The colours a picture's own background and foreground should be drawn in.
--
-- These exist for the stand-in drawn when a record has no cover, so that it sits
-- on the same coloured ground a real cover does. Without them, albums with
-- artwork and albums without would read opposite ways round down a single list.
--
-- Both are the opposite of what they say, because the display flips them again
-- before anyone sees them. Paper drawn black arrives white.
function Artwork.paperColor()
    return graphics.kColorBlack
end


function Artwork.inkColor()
    return graphics.kColorWhite
end
