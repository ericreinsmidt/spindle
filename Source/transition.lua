-- Sliding one screen out while the next slides in.
--
-- Screens used to replace each other between one frame and the next, which makes
-- the app read as a set of unrelated pictures rather than as one place you move
-- around inside. A slide says where the new screen came from, and after a few
-- goes you know where things are relative to each other without being told.
--
-- The direction carries that meaning and is not decoration. Going further in
-- pushes left, coming back pops right, and the visualizer arrives from above
-- because up is the button that fetches it.
--
-- The outgoing screen is a photograph, not a live screen. It is captured once at
-- the moment of the switch and then slid about as an image, so nothing has to
-- keep two screens updating at once, and a screen cannot be halfway through
-- something while it leaves.

Transition = {}

local graphics <const> = playdate.graphics

local SCREEN_WIDTH <const> = 400
local SCREEN_HEIGHT <const> = 240

-- Short on purpose.
--
-- At 30 frames a second this is six frames, which is few enough that it reads as
-- one movement rather than an animation you sit through. Every navigation in the
-- app pays this, and a transition that feels generous the first time is tiresome
-- by the fifth.
local DURATION_MILLISECONDS <const> = 200

local outgoingScreen = nil
local incomingCanvas = nil
local startedAt = nil
local directionX, directionY = 0, 0


-- Fast at first and slowing into place, which is the same shape the lists use.
-- A linear slide over six frames reads as a jump that happens to take a moment.
local function easedProgress(fraction)
    local remaining = 1 - fraction
    return 1 - remaining * remaining * remaining
end


-- Start sliding, with the new screen entering from the given direction.
--
-- x of 1 means it comes from the right, so the picture moves left. y of -1 means
-- it comes from the top, so the picture moves up. Called before the new screen
-- has drawn anything, because the frame buffer still holds the old one and that
-- is what gets photographed.
function Transition.begin(fromX, fromY)
    outgoingScreen = graphics.getWorkingImage()
    directionX, directionY = fromX, fromY
    startedAt = playdate.getCurrentTimeMilliseconds()

    if not incomingCanvas then
        incomingCanvas = graphics.image.new(SCREEN_WIDTH, SCREEN_HEIGHT)
    end
end


function Transition.isRunning()
    return startedAt ~= nil
end


-- Stop immediately and let the new screen draw itself normally.
--
-- Anything that changes screens while one is already sliding cancels rather than
-- queues. Two transitions running into each other is worse than none.
function Transition.cancel()
    startedAt = nil
    outgoingScreen = nil
end


-- Draw one frame of the slide. drawIncoming is handed a cleared canvas and
-- should draw the new screen into it exactly as it would draw to the display.
--
-- Returns false once the slide is over, so the caller can go back to drawing
-- straight to the screen.
function Transition.draw(drawIncoming)
    if not startedAt then
        return false
    end

    local elapsed = playdate.getCurrentTimeMilliseconds() - startedAt
    if elapsed >= DURATION_MILLISECONDS then
        Transition.cancel()
        return false
    end

    local slid = easedProgress(elapsed / DURATION_MILLISECONDS)

    -- The new screen is drawn into an image rather than to the display at an
    -- offset. An offset would have to be applied to the clip rectangles the
    -- library screen sets as well, and anything that forgot would clip against
    -- the wrong part of the screen. Drawing into an image keeps every screen's
    -- coordinates meaning what they have always meant.
    graphics.pushContext(incomingCanvas)
        graphics.clear()
        drawIncoming()
    graphics.popContext()

    graphics.clear()

    incomingCanvas:draw(
        directionX * SCREEN_WIDTH * (1 - slid),
        directionY * SCREEN_HEIGHT * (1 - slid))

    outgoingScreen:draw(
        -directionX * SCREEN_WIDTH * slid,
        -directionY * SCREEN_HEIGHT * slid)

    return true
end
