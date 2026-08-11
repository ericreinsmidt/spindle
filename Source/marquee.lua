-- Text too long for its space, slid back and forth so all of it can be read.
--
-- Truncating with an ellipsis loses the end of the title, which on a music
-- player is often the part that distinguishes one thing from another: two live
-- versions of the same song, a remaster, which disc a track is on. The room to
-- print it does not exist, so the only way to show it is over time.
--
-- Ping pong rather than a wrapping marquee. A wrap runs the end of the line into
-- the beginning of it, and for a couple of frames you read a sentence that was
-- never written. Sliding back the way it came never shows text that is not
-- there, and it makes the two ends of the string the resting states, which is
-- where the eye wants them.
--
-- The pause at each end is what makes it legible rather than restless. Without
-- it the text reverses the instant it arrives, so the end of a title is on
-- screen for one frame and you have to wait for another pass to read it.

Marquee = {}

local graphics <const> = playdate.graphics

-- Keyed by where on the screen it is drawn rather than by what it says, because
-- only a few things scroll at once and they are always the same few: the
-- selected row, the header, the lines on now playing. That bounds this table at
-- a handful of entries no matter how large the library is. Changing what a slot
-- says resets that slot, which is what makes moving the selection start the new
-- title from the beginning.
local slots = {}

local FRAMES_PER_SECOND <const> = 30

-- How long it sits still at each end.
local PAUSE_FRAMES <const> = 30

-- How fast it slides, in pixels a second. Slow enough to read while it moves,
-- which is the only speed worth having: too fast and you wait for the pause
-- anyway, which makes the movement decoration rather than function.
--
-- 26 was the first try and it is too slow. A long album title overflows its row
-- by around 250 pixels, which took ten seconds each way, and a row in a list you
-- are cranking past does not get ten seconds. 45 covers the same overflow in
-- five and a half and is still comfortably readable while moving.
local SLIDE_PIXELS_PER_SECOND <const> = 45
local SLIDE_PIXELS_PER_FRAME <const> = SLIDE_PIXELS_PER_SECOND / FRAMES_PER_SECOND


local function slotFor(key, text)
    local slot = slots[key]
    if not slot or slot.text ~= text then
        slot = { text = text, offset = 0, waited = 0, atStart = true, sliding = false }
        slots[key] = slot
    end
    return slot
end


-- Move one slot along by a frame.
--
-- Advanced from draw rather than from a screen's update, because a marquee that
-- is not on screen should not be moving, and being drawn is the only reliable
-- signal for that.
local function advance(slot, overflow)
    if not slot.sliding then
        slot.waited = slot.waited + 1
        if slot.waited >= PAUSE_FRAMES then
            slot.waited = 0
            slot.sliding = true
        end
        return
    end

    local direction = slot.atStart and 1 or -1
    slot.offset = slot.offset + SLIDE_PIXELS_PER_FRAME * direction

    if slot.offset >= overflow then
        slot.offset = overflow
        slot.atStart = false
        slot.sliding = false
    elseif slot.offset <= 0 then
        slot.offset = 0
        slot.atStart = true
        slot.sliding = false
    end
end


-- Draw text in a fixed width, sliding it if it does not fit.
--
-- key identifies the place on screen, not the string. height is the band to clip
-- to, which has to be given because the clip has to cover the line and nothing
-- above or below it.
--
-- Returns nothing. Anything that fits is simply drawn, so this can replace a
-- truncating draw everywhere rather than only where overflow is expected.
function Marquee.draw(key, font, text, left, top, width, height)
    if not text or text == "" then
        return
    end

    graphics.setFont(font)

    local textWidth = font:getTextWidth(text)
    if textWidth <= width then
        -- Drop the slot rather than leaving it. A title that fits now may not be
        -- what is there next time, and a stale offset would make the next long
        -- one start part way along.
        slots[key] = nil
        graphics.drawText(text, left, top)
        return
    end

    local slot = slotFor(key, text)
    local overflow = textWidth - width
    advance(slot, overflow)

    -- Clipped rather than trusted to stop at the edge. The text is wider than the
    -- space by definition, so without this it would run over whatever sits beside
    -- it, which on the album list is the cover of the row below.
    graphics.setClipRect(left, top, width, height)
    graphics.drawText(text, left - slot.offset, top)
    graphics.clearClipRect()
end


-- Forget every slot.
--
-- Called when a screen is entered, so arriving at a list does not find a title
-- half slid from the last time it was open.
function Marquee.reset()
    slots = {}
end
