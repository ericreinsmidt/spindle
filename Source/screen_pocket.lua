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
-- Getting out needs a gesture a pocket will not produce by accident. Holding A
-- and B together for two seconds is the primary one, because two specific
-- buttons held for that long is not something a leg does. A full turn of the
-- crank works as well, for when it is already extended, and it is equally
-- unlikely to happen on its own.
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

-- A full revolution, in degrees. Accumulated as absolute movement so it does not
-- matter which way it is turned.
local UNLOCK_CRANK_DEGREES <const> = 360

-- Crank progress is thrown away if the crank stops, so a pocket nudging it a few
-- degrees at a time over several minutes never adds up to an unlock.
local CRANK_IDLE_RESET_MILLISECONDS <const> = 1200

local SCREEN_WIDTH <const> = 400
local SCREEN_HEIGHT <const> = 240

local unlockHoldStartedAtMilliseconds = nil
local crankDegreesTurned = 0
local lastCrankMovementAtMilliseconds = 0

-- What was on screen the last time anything was drawn, so the frame can be
-- skipped when it would come out identical.
local drawnTrackFile = nil
local drawnUnlockFraction = -1


function ScreenPocket.enter()
    unlockHoldStartedAtMilliseconds = nil
    crankDegreesTurned = 0
    lastCrankMovementAtMilliseconds = playdate.getCurrentTimeMilliseconds()

    -- Force the next frame to draw, whatever was on screen before.
    drawnTrackFile = nil
    drawnUnlockFraction = -1
end


-- How far through the unlock gesture we are, zero to one. Whichever of the two
-- gestures is further along wins, so they can be used interchangeably without
-- either interfering with the other.
local function unlockProgress()
    local nowInMilliseconds = playdate.getCurrentTimeMilliseconds()

    local holdFraction = 0
    if unlockHoldStartedAtMilliseconds then
        holdFraction = (nowInMilliseconds - unlockHoldStartedAtMilliseconds)
            / UNLOCK_HOLD_MILLISECONDS
    end

    local crankFraction = crankDegreesTurned / UNLOCK_CRANK_DEGREES

    return math.min(1, math.max(holdFraction, crankFraction))
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

    -- A full turn of the crank, in either direction.
    local crankChange = math.abs(playdate.getCrankChange())
    if crankChange > 0.5 then
        crankDegreesTurned = crankDegreesTurned + crankChange
        lastCrankMovementAtMilliseconds = nowInMilliseconds
    elseif nowInMilliseconds - lastCrankMovementAtMilliseconds
        > CRANK_IDLE_RESET_MILLISECONDS then
        crankDegreesTurned = 0
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
    -- doing something rather than being ignored. It is drawn as a widening arc
    -- from the top rather than a bar, because a ring reads at a glance without
    -- having to find either end of it.
    if progress > 0 then
        local centreX = SCREEN_WIDTH // 2
        local centreY = SCREEN_HEIGHT - 26
        local radius = 12

        graphics.setLineWidth(3)
        local previousX, previousY
        for step = 0, math.floor(progress * 36) do
            local radians = math.rad(-90 + step * 10)
            local pointX = centreX + math.cos(radians) * radius
            local pointY = centreY + math.sin(radians) * radius
            if previousX then
                graphics.drawLine(previousX, previousY, pointX, pointY)
            end
            previousX, previousY = pointX, pointY
        end
        graphics.setLineWidth(1)
    end
end
