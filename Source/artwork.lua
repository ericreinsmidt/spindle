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


-- The adapter on its own, for wherever a cover is wanted and there is none.
--
-- A playlist has no artwork, and neither does an album whose files carried none.
-- Both get the 45 adapter the app is named for, generated from the same
-- photograph as the logo and the launcher art, so it is the real shape rather
-- than a circle and three spokes standing in for it.
--
-- A playlist used to borrow the cover of whatever it opened with. That was free
-- and it was wrong: it makes a playlist look like that album, which is exactly
-- the thing it is not.
--
-- Loaded once at import. Two of them, because a cover is drawn at two sizes and
-- shrinking the large one would be resampling a 1-bit image, which is what
-- turns artwork into noise.
local coverMarks <const> = {
    [60] = graphics.image.new("adapter-60"),
    [140] = graphics.image.new("adapter-140"),
}


-- Draw the adapter mark in a cover's place, at whichever of the two sizes is
-- being asked for.
--
-- Flipped exactly as a real cover is, so a list of albums and playlists reads
-- consistently rather than having one row the opposite way round from the rest.
function Artwork.drawCoverMark(left, top, size)
    local mark = coverMarks[size]
    if mark then
        Artwork.draw(mark, left, top)
        return true
    end
    return false
end
