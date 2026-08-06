-- The fonts the screens draw with, loaded once and shared.
--
-- The default drawing font is fine for dense technical text and too light for
-- a list you are meant to read at arm's length on a reflective screen with no
-- backlight. Both fonts here ship with the SDK. Roobert is the Playdate's own
-- interface font, so the app looks like it belongs on the device rather than
-- like it brought its own styling with it.
--
-- Two sizes, used consistently everywhere:
--
--   large   21 pixels, for the one thing a screen is about: an album title, a
--           track title, the name of what is playing
--   body    18 pixels and bold, for everything else
--
-- Both are heavier than the default, which matters more than the size does. A
-- 1-bit screen has no antialiasing, so a light weight loses strokes entirely
-- rather than merely looking thin.

Typography = {}

local graphics <const> = playdate.graphics

-- Loading a font can fail if the file did not make it into the build, and a nil
-- font passed to setFont throws on the first frame. Falling back to the system
-- font means a missing file makes the app look wrong rather than making it
-- refuse to start.
local function loadFontOrFallBack(path)
    local loadedFont = graphics.font.new(path)
    if loadedFont then
        return loadedFont
    end
    return graphics.getSystemFont()
end

Typography.large = loadFontOrFallBack("fonts/Roobert-20-Medium")
Typography.body = loadFontOrFallBack("fonts/Roobert-11-Bold")


-- Shorten text until it fits inside the given width, adding an ellipsis when
-- anything was removed.
--
-- Every list on a small screen needs this. Album and track titles regularly run
-- past the space they are given, and without trimming they draw straight over
-- whatever sits to their right, which on the album list is the scroll bar and
-- on the track list is the running time.
--
-- The search walks backwards one character at a time rather than doing anything
-- clever, because the strings are short and this runs only for the handful of
-- rows actually on screen.
function Typography.truncateToWidth(font, text, availableWidth)
    if not text or text == "" then
        return ""
    end

    if font:getTextWidth(text) <= availableWidth then
        return text
    end

    local ellipsis = "..."
    local ellipsisWidth = font:getTextWidth(ellipsis)

    for characterCount = #text - 1, 1, -1 do
        local candidate = string.sub(text, 1, characterCount)
        if font:getTextWidth(candidate) + ellipsisWidth <= availableWidth then
            return candidate .. ellipsis
        end
    end

    return ellipsis
end


-- Draw text at a left edge, vertically centred inside a band.
--
-- Centring by hand was where the old layout went wrong. Rows drew their text at
-- the top of the band and left the leftover space underneath, so the highlight
-- looked like it sat lower than the text it was highlighting. Measuring the
-- font rather than assuming a height fixes it for every font and every band
-- size at once.
function Typography.drawCentredInBand(font, text, left, bandTop, bandHeight)
    graphics.setFont(font)
    graphics.drawText(text, left, bandTop + (bandHeight - font:getHeight()) // 2)
end
