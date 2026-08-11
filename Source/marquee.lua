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
local PAUSE_MILLISECONDS <const> = 1000

-- How fast it slides, measured against the clock rather than against frames.
--
-- This was pixels per frame, which is the obvious way to write it and is wrong
-- on this device. A fixed step per frame is only a fixed speed if the frames are
-- evenly spaced, and on hardware the album list runs at about 19 frames a second
-- with each frame taking anywhere from 48 to 55 milliseconds. Measured with the
-- marquee alternating on and off, the median frame was 53 milliseconds either
-- way, so the list has always been that slow and nothing on it moved before to
-- show it.
--
-- Driving from the clock means the text covers the same ground per second
-- whatever the frame rate does. The position still lands on a whole pixel, so it
-- is not perfectly smooth, but the error is under half a pixel rather than the
-- fourteen percent swing in speed that came of trusting the frame counter.
local SLIDE_PIXELS_PER_MILLISECOND <const> = 60 / 1000

-- A gap this long between frames means something interrupted us: a screen
-- change, the system menu, a stall. Time that passed while nobody was looking is
-- not time the text should have been moving.
local LONGEST_CREDIBLE_FRAME_MILLISECONDS <const> = 250

-- The blank between the end of one pass and the start of the next.
local GAP_PIXELS <const> = 44


local function slotFor(key, text)
    local slot = slots[key]
    if not slot or slot.text ~= text then
        slot = { text = text, travelled = 0, waited = 0, sliding = false, lastAt = nil }
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
    local now = playdate.getCurrentTimeMilliseconds()
    local sinceLastFrame = now - (slot.lastAt or now)
    slot.lastAt = now

    -- A gap far longer than a frame means this was not on screen for part of it.
    -- Counting that time would make a title jump forward on return, as though it
    -- had been scrolling to an empty room.
    if sinceLastFrame > LONGEST_CREDIBLE_FRAME_MILLISECONDS then
        sinceLastFrame = 0
    end

    if not slot.sliding then
        slot.waited = slot.waited + sinceLastFrame
        if slot.waited >= PAUSE_MILLISECONDS then
            slot.waited = 0
            slot.sliding = true
        end
        return
    end

    slot.travelled = slot.travelled + sinceLastFrame * SLIDE_PIXELS_PER_MILLISECOND
    if slot.travelled >= cycleWidth then
        slot.travelled = 0
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

    -- Text can only be drawn on a pixel, so the position it has travelled to is
    -- rounded here rather than being kept rounded. Rounding the running total
    -- instead would throw away the fraction every frame and the text would creep
    -- slower than it should.
    local offset = math.floor(slot.travelled)

    -- Clipped rather than trusted to stop at the edge. The text is wider than the
    -- space by definition, so without this it would run over whatever sits beside
    -- it, which on the album list is the cover of the row below.
    --
    -- Narrowed into whatever clip the caller already had, and put back
    -- afterwards, rather than set and then cleared. Clearing it threw away the
    -- caller's clip: the album list clips its rows to the area below the heading
    -- and then draws them a second time clipped to the selection bar, and a
    -- marquee in the middle of that released both. Every row after the selected
    -- one was then drawn unclipped, and in the white pass that painted white text
    -- over the black text already there, which read as a row losing its title.
    local previousLeft, previousTop, previousWidth, previousHeight =
        graphics.getClipRect()

    local clipLeft = math.max(left, previousLeft)
    local clipTop = math.max(top, previousTop)
    local clipRight = math.min(left + width, previousLeft + previousWidth)
    local clipBottom = math.min(top + height, previousTop + previousHeight)

    if clipRight <= clipLeft or clipBottom <= clipTop then
        -- None of it is visible. The slot has already been advanced, so it keeps
        -- time while it is hidden rather than resuming from wherever it stopped.
        return
    end

    graphics.setClipRect(clipLeft, clipTop, clipRight - clipLeft, clipBottom - clipTop)
    graphics.drawText(text, left - offset, top)

    -- The second copy is what makes the loop seamless: once the first has slid
    -- far enough left to leave a hole on the right, the next pass is already
    -- coming into it. Only drawn when that hole exists, so a marquee costs one
    -- draw for most of its cycle rather than two for all of it.
    if offset > cycleWidth - width then
        graphics.drawText(text, left - offset + cycleWidth, top)
    end

    graphics.setClipRect(previousLeft, previousTop, previousWidth, previousHeight)
end


-- Forget every slot.
--
-- Called when a screen is entered, so arriving at a list does not find a title
-- half slid from the last time it was open.
function Marquee.reset()
    slots = {}
end
