-- Drawing pictures so they stay pictures when the screen is inverted.
--
-- playdate.display.setInverted flips the whole display after everything has
-- been drawn, which is what makes it free: no drawing code has to know about it.
-- That is exactly right for text and line work, and wrong for a photograph. An
-- inverted album cover is a negative, and a negative of a face does not read as
-- a face.
--
-- The fix is to flip the artwork on the way in, so the display's flip on the way
-- out cancels it and the cover comes out looking like a cover on a screen that
-- is otherwise white on black. kDrawModeInverted is the image draw mode that
-- does it, so this costs nothing beyond setting a mode either side of the draw.
--
-- Album art is the only thing treated this way. Everything else on screen is
-- type or line work, which reads perfectly well either way round and is
-- supposed to follow the setting.

import "CoreLibs/graphics"

Artwork = {}

local graphics <const> = playdate.graphics

-- Whether the display is currently inverted. Tracked here rather than asked of
-- the display every time something is drawn, because the app is the only thing
-- that changes it and a field read is cheaper than a call into the firmware on
-- every frame.
Artwork.displayIsInverted = false


function Artwork.setDisplayInverted(shouldInvert)
    Artwork.displayIsInverted = shouldInvert and true or false
    playdate.display.setInverted(Artwork.displayIsInverted)
end


-- Draw a picture the right way up whichever way round the screen is.
function Artwork.draw(image, left, top)
    if Artwork.displayIsInverted then
        graphics.setImageDrawMode(graphics.kDrawModeInverted)
    else
        graphics.setImageDrawMode(graphics.kDrawModeCopy)
    end

    image:draw(left, top)

    graphics.setImageDrawMode(graphics.kDrawModeCopy)
end


-- The colour a picture's background should be drawn in.
--
-- These exist for the stand-in drawn when a record has no cover. It has to sit
-- on the same coloured ground as a real cover does, otherwise inverting the
-- screen would leave albums with artwork looking one way and albums without
-- looking the other, which is worse than either.
--
-- Both are the opposite of what they say when the display is inverted, because
-- the display will flip them again before anyone sees them.
function Artwork.paperColor()
    if Artwork.displayIsInverted then
        return graphics.kColorBlack
    end
    return graphics.kColorWhite
end


function Artwork.inkColor()
    if Artwork.displayIsInverted then
        return graphics.kColorWhite
    end
    return graphics.kColorBlack
end
