-- Text too long for its space, slid back and forth so all of it can be read.
--
-- Truncating with an ellipsis loses the end of the title, which on a music
-- player is often the part that distinguishes one thing from another: two live
-- versions of the same song, a remaster, which disc a track is on. The room to
-- print it does not exist, so the only way to show it is over time.
--
-- It scrolls one way and comes back around, with a gap between the end and the
-- beginning of the next pass.
--
-- Ping pong was tried first and reads worse. Reversing puts the text through
-- zero speed twice a cycle, so the eye is asked to change direction with it, and
-- half the passes are travelling the wrong way for reading. One direction is the
-- direction you read in, and it never stops meaning the same thing.
--
-- The gap is what makes a wrap legible. Without it the end of the line runs
-- straight into its beginning and for a moment you read a sentence nobody wrote.
-- With it, the break is obvious and the loop reads as a loop.
--
-- The pause at the start of each pass is kept from the ping pong version, and it
-- is the part that matters most. The beginning of a title is the part you need
-- and it is the part a scroll would otherwise show you least of.

Marquee = {}

local graphics <const> = playdate.graphics

-- Keyed by where on the screen it is drawn rather than by what it says, because
-- only a few things scroll at once and they are always the same few: the
-- selected row, the header, the lines on now playing. That bounds this table at
-- a handful of entries no matter how large the library is. Changing what a slot
-- says resets that slot, which is what makes moving the selection start the new
-- title from the beginning.
local slots = {}

-- How long it holds still at the start of each pass.
local PAUSE_FRAMES <const> = 30

-- How far it moves each frame, in whole pixels.
--
-- Whole pixels is the point of this number, not a detail of it. The screen can
-- only draw text on a pixel, so a speed that is not a whole number of pixels a
-- frame gets rounded on the way out and the text moves in an uneven stutter. The
-- first version of this was 45 pixels a second, which at 30 frames a second is
-- 1.5 a frame, and it landed as one pixel, two pixels, one, two, forever. That
-- read as a hitch because it was one.
--
-- So the speed is written as pixels a frame and has to stay an integer. Two is
-- 60 a second, which crosses a long album title in about eight seconds.
local SLIDE_PIXELS_PER_FRAME <const> = 2

-- The blank between the end of one pass and the start of the next.
local GAP_PIXELS <const> = 44


local function slotFor(key, text)
    local slot = slots[key]
    if not slot or slot.text ~= text then
        slot = { text = text, offset = 0, waited = 0, sliding = false }
        slots[key] = slot
    end
    return slot
end


-- Move one slot along by a frame.
--
-- Advanced from draw rather than from a screen's update, because a marquee that
-- is not on screen should not be moving, and being drawn is the only reliable
-- signal for that.
--
-- cycleWidth is the text plus the gap after it, so returning to zero puts the
-- next pass exactly where the previous one started and the loop has no seam.
local function advance(slot, cycleWidth)
    if not slot.sliding then
        slot.waited = slot.waited + 1
        if slot.waited >= PAUSE_FRAMES then
            slot.waited = 0
            slot.sliding = true
        end
        return
    end

    slot.offset = slot.offset + SLIDE_PIXELS_PER_FRAME
    if slot.offset >= cycleWidth then
        slot.offset = 0
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
    local cycleWidth = textWidth + GAP_PIXELS
    advance(slot, cycleWidth)

    -- Clipped rather than trusted to stop at the edge. The text is wider than the
    -- space by definition, so without this it would run over whatever sits beside
    -- it, which on the album list is the cover of the row below.
    graphics.setClipRect(left, top, width, height)
    graphics.drawText(text, left - slot.offset, top)

    -- The second copy is what makes the loop seamless: once the first has slid
    -- far enough left to leave a hole on the right, the next pass is already
    -- coming into it. Only drawn when that hole exists, so a marquee costs one
    -- draw for most of its cycle rather than two for all of it.
    if slot.offset > cycleWidth - width then
        graphics.drawText(text, left - slot.offset + cycleWidth, top)
    end

    graphics.clearClipRect()
end


-- Forget every slot.
--
-- Called when a screen is entered, so arriving at a list does not find a title
-- half slid from the last time it was open.
function Marquee.reset()
    slots = {}
end
