-- Pocket mode.
--
-- The screen has to stay on for audio to play at all, which is the hardware
-- fact the whole app is built around, so this cannot be a real lock. What it
-- can do is stop the device reacting to a pocket and stop it spending anything
-- on drawing, while the music keeps going.
--
-- Two things are therefore true at once here: every button is ignored, and the
-- screen is left exactly as it was rather than being redrawn each frame. The
-- display is memory-in-pixel, so holding a picture costs nothing, and the frames
-- this screen does not draw are the saving.
--
-- Getting out is holding A and B together for two seconds, because two specific
-- buttons held that long is not something a leg does. A full turn of the crank
-- was an unlock as well and has been taken out: anyone pocketing the device
-- closes the crank first, so it was a gesture for a situation that does not
-- arise, and it brought a whole idle-reset mechanism with it to stop partial
-- turns accumulating.
--
-- The refresh rate is deliberately left alone. Dropping it is the obvious way to
-- save more, and it would break gapless playback: the swap to the next track
-- happens on the frame the playhead passes the end, so at ten frames a second
-- that is up to a tenth of a second of silence between tracks. Measured battery
-- gain from the refresh rate is about 22 percent, which is not worth a gap you
-- can hear on every track boundary.

import "player"
import "library"
import "typography"
import "glyphs"

ScreenPocket = {}

local graphics <const> = playdate.graphics

-- Tells main not to clear the screen before calling draw, so a frame that draws
-- nothing leaves the previous one in place.
ScreenPocket.ownsItsOwnClearing = true

local UNLOCK_HOLD_MILLISECONDS <const> = 2000

local RING_CENTER_Y <const> = 214
local RING_RADIUS <const> = 11

local SCREEN_WIDTH <const> = 400

local unlockHoldStartedAtMilliseconds = nil

-- What was on screen the last time anything was drawn, so the frame can be
-- skipped when it would come out identical.
local drawnTrackFile = nil
local drawnUnlockFraction = -1


function ScreenPocket.enter()
    unlockHoldStartedAtMilliseconds = nil

    -- Force the next frame to draw, whatever was on screen before.
    drawnTrackFile = nil
    drawnUnlockFraction = -1
end


-- How far through the unlock hold we are, zero to one.
local function unlockProgress()
    if not unlockHoldStartedAtMilliseconds then
        return 0
    end

    local heldFor = playdate.getCurrentTimeMilliseconds() - unlockHoldStartedAtMilliseconds
    return math.min(1, heldFor / UNLOCK_HOLD_MILLISECONDS)
end


-- Draw part of a ring, filling clockwise from the top.
--
-- The points come from the midpoint circle algorithm, one octant worked out and
-- mirrored into eight, which is what makes a circle on a pixel grid look round
-- instead of lumpy. The first version stepped round in ten degree chunks joining
-- them with drawLine, and at eleven pixels across that is a visible polygon.
--
-- Each point is kept only if its angle falls inside the swept part, so the ring
-- is exactly as clean part way round as it is when complete.
local function drawProgressRing(centerX, centerY, radius, fraction)
    local sweptRadians = fraction * math.pi * 2

    local function plotIfSwept(pointX, pointY)
        -- Measured clockwise from straight up, which is where filling starts.
        local angle = math.atan(pointX - centerX, centerY - pointY)
        if angle < 0 then
            angle = angle + math.pi * 2
        end
        if angle <= sweptRadians then
            graphics.fillRect(pointX, pointY, 1, 1)
        end
    end

    -- Two radii, so the ring has some weight to it.
    for ringRadius = radius - 1, radius do
        local x = ringRadius
        local y = 0
        local decision = 1 - ringRadius

        while x >= y do
            plotIfSwept(centerX + x, centerY + y)
            plotIfSwept(centerX + y, centerY + x)
            plotIfSwept(centerX - x, centerY + y)
            plotIfSwept(centerX - y, centerY + x)
            plotIfSwept(centerX + x, centerY - y)
            plotIfSwept(centerX + y, centerY - x)
            plotIfSwept(centerX - x, centerY - y)
            plotIfSwept(centerX - y, centerY - x)

            y = y + 1
            if decision < 0 then
                decision = decision + 2 * y + 1
            else
                x = x - 1
                decision = decision + 2 * (y - x) + 1
            end
        end
    end
end


function ScreenPocket.update()
    local nowInMilliseconds = playdate.getCurrentTimeMilliseconds()

    -- A and B together, held. Both have to be down; letting go of either starts
    -- the two seconds again from nothing.
    if playdate.buttonIsPressed(playdate.kButtonA)
        and playdate.buttonIsPressed(playdate.kButtonB) then
        unlockHoldStartedAtMilliseconds = unlockHoldStartedAtMilliseconds or nowInMilliseconds
    else
        unlockHoldStartedAtMilliseconds = nil
    end

    if unlockProgress() >= 1 then
        return "nowplaying"
    end

    return nil
end


function ScreenPocket.draw()
    local entry = Player.currentEntry()
    local trackFile = entry and entry.track and entry.track.file or nil
    local progress = unlockProgress()

    -- Redraw only when something has actually changed: the track rolled over, or
    -- an unlock is part way through. Standing still is the normal case and costs
    -- nothing, which is the point of the whole screen.
    local progressChanged = math.abs(progress - drawnUnlockFraction) > 0.005
    if trackFile == drawnTrackFile and not progressChanged then
        return
    end

    drawnTrackFile = trackFile
    drawnUnlockFraction = progress

    graphics.clear()

    if entry then
        local titleWidth = SCREEN_WIDTH - 40

        graphics.setFont(Typography.large)
        local title = Typography.truncateToWidth(Typography.large, entry.track.title, titleWidth)
        graphics.drawText(title, (SCREEN_WIDTH - Typography.large:getTextWidth(title)) // 2, 74)

        graphics.setFont(Typography.body)
        local artist = Typography.truncateToWidth(
            Typography.body, entry.album.artist or "", titleWidth)
        graphics.drawText(artist, (SCREEN_WIDTH - Typography.body:getTextWidth(artist)) // 2, 102)
    else
        graphics.setFont(Typography.body)
        graphics.drawText("Nothing playing", 140, 84)
    end

    -- The transport glyph, so a glance says whether it is still going.
    local glyphLeft = (SCREEN_WIDTH - Glyphs.SIZE) // 2
    if Player.isPlaying() then
        Glyphs.drawPlay(glyphLeft, 134)
    else
        Glyphs.drawPause(glyphLeft, 134)
    end

    graphics.setFont(Typography.body)
    local hint = "hold A + B to unlock"
    graphics.drawText(hint, (SCREEN_WIDTH - Typography.body:getTextWidth(hint)) // 2, 186)

    -- The ring fills as the gesture is held, so it is obvious that holding is
    -- doing something rather than being ignored. A ring rather than a bar,
    -- because it reads at a glance without having to find either end of it.
    if progress > 0 then
        drawProgressRing(SCREEN_WIDTH // 2, RING_CENTER_Y, RING_RADIUS, progress)
    end
end
