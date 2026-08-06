-- The fullscreen visualizer screen.
--
-- This is where the crank stops being a scrub control and becomes part of the
-- visual. Every visualizer receives the crank movement and can do what it
-- likes with it: steer a flock, rotate a moire grid, wind an epicycle
-- mechanism faster. No other Playdate music player does anything with the
-- crank except scroll, so a visualizer you can play with is the thing that
-- makes this worth building.
--
-- Controls follow the design:
--   crank         drives whichever visualizer is showing, except on Scope,
--                 where it scrubs the track
--   left, right   seek by ten seconds, so you are never stranded here
--   up            switch to the next visualizer
--   down, B       back to now playing
--
-- Scope is the exception because it is the one visualizer that shows where you
-- are in a song rather than only what it sounds like right now. It asks for the
-- crank by declaring scrubsWithCrank, and this screen honours that, so no
-- visualizer has to know that playback exists.

import "visualizers"
import "player"
import "typography"
import "viz_geometry"
import "viz_life"
import "viz_meters"

ScreenVisualizer = {}

local graphics <const> = playdate.graphics

-- The order the picker steps through. Named here rather than depending on
-- import order and where each register call happens to sit.
Visualizers.setOrder({
    "Moire",
    "Radial",
    "Boids",
    "Slime",
    "Epicycles",
    "Harmonograph",
    "Automaton",
    "Chladni",
    "Spectrum",
    "Scope",
})

local SEEK_STEP_IN_SECONDS <const> = 10

-- How long the visualizer's name stays on screen after switching. Long enough
-- to read, short enough not to intrude on the thing you came here to look at.
local NAME_OVERLAY_DURATION_MILLISECONDS <const> = 1400

local selectedVisualizerIndex = 1
local frameNumber = 0

-- Crank movement for this frame, worked out in update and handed to the
-- visualizer in draw. It is zero on a visualizer that spent its crank on
-- scrubbing instead.
local crankDeltaThisFrame = 0

local nameOverlayExpiresAtMilliseconds = 0

-- Set when a visualizer throws, so one broken plugin shows a message instead
-- of taking the whole app down with it.
local visualizerErrorMessage = nil

-- Per visualizer draw timings, so the expensive ones can be identified rather
-- than guessed at. Keyed by name, holding a running total, a sample count and
-- the worst single frame seen.
local drawTimingsByName = {}

-- Whether to show the timing overlay. Off by default, since it is a
-- development aid rather than something to look at while listening.
ScreenVisualizer.showTimings = false

-- Where the timing report is written, inside the app's data folder.
local TIMING_REPORT_FILE_NAME <const> = "visualizer-timings.txt"

-- While the overlay is up the report is rewritten on this interval as well as
-- on the way out, so you can confirm the file is being produced without having
-- to leave the screen first.
local TIMING_REPORT_REWRITE_INTERVAL_MILLISECONDS <const> = 5000

local lastTimingReportAttemptAtMilliseconds = 0

-- What happened the last time the report was written, shown in the overlay.
ScreenVisualizer.timingReportStatus = "not written yet"


local function recordDrawTiming(visualizerName, milliseconds)
    local timing = drawTimingsByName[visualizerName]
    if not timing then
        timing = { totalMilliseconds = 0, sampleCount = 0, worstMilliseconds = 0 }
        drawTimingsByName[visualizerName] = timing
    end

    timing.totalMilliseconds = timing.totalMilliseconds + milliseconds
    timing.sampleCount = timing.sampleCount + 1
    if milliseconds > timing.worstMilliseconds then
        timing.worstMilliseconds = milliseconds
    end
end


-- Write what has been measured so far to a file that can be read off the
-- device, because reading numbers off a screen while a visualizer is animating
-- is not a reliable way to compare them.
--
-- This used to fail silently. It was only called on the way out of the screen,
-- it discarded the error playdate.file.open returns alongside a nil handle, and
-- so when the file did not turn up on the device there was nothing at all to
-- say why. It now records what happened, the overlay shows that, and the report
-- is rewritten periodically while the overlay is up rather than only on exit,
-- so a failure is visible while you are still standing in front of it.
function ScreenVisualizer.writeTimingReport()
    lastTimingReportAttemptAtMilliseconds = playdate.getCurrentTimeMilliseconds()

    local reportFile, openError =
        playdate.file.open(TIMING_REPORT_FILE_NAME, playdate.file.kFileWrite)
    if not reportFile then
        ScreenVisualizer.timingReportStatus = "write failed: " .. tostring(openError)
        return false
    end

    reportFile:write("visualizer draw cost, measured on device\n")
    reportFile:write("frame budget is 33ms at 30Hz\n\n")

    for _, visualizer in ipairs(Visualizers.registry) do
        local timing = drawTimingsByName[visualizer.name]
        if timing and timing.sampleCount > 0 then
            reportFile:write(string.format(
                "%-14s avg %5.1fms  worst %5.1fms  frames %d\n",
                visualizer.name,
                timing.totalMilliseconds / timing.sampleCount,
                timing.worstMilliseconds,
                timing.sampleCount))
        else
            reportFile:write(string.format("%-14s not measured\n", visualizer.name))
        end
    end

    reportFile:close()

    -- Read the size back rather than reporting success on the strength of the
    -- writes not having thrown. A file that exists and is zero bytes long looks
    -- exactly like a file that was never written when you go looking for it on
    -- the Mac, so the number is worth having.
    local writtenSize = playdate.file.getSize(TIMING_REPORT_FILE_NAME)
    if writtenSize and writtenSize > 0 then
        ScreenVisualizer.timingReportStatus =
            string.format("wrote %s, %d bytes", TIMING_REPORT_FILE_NAME, writtenSize)
        return true
    end

    ScreenVisualizer.timingReportStatus =
        TIMING_REPORT_FILE_NAME .. " came back empty after writing"
    return false
end


local function showVisualizerName()
    nameOverlayExpiresAtMilliseconds =
        playdate.getCurrentTimeMilliseconds() + NAME_OVERLAY_DURATION_MILLISECONDS
end


local function switchToVisualizer(index)
    -- Wrap the index here rather than relying on Visualizers.get to wrap it
    -- internally. Get does wrap, so the correct visualizer was always shown,
    -- but the raw counter kept climbing and the overlay ended up reading 11,
    -- 21, 31 and so on instead of returning to 1.
    local visualizerCount = Visualizers.count()
    if visualizerCount > 0 then
        selectedVisualizerIndex = ((index - 1) % visualizerCount) + 1
    else
        selectedVisualizerIndex = 1
    end

    visualizerErrorMessage = nil

    local visualizer = Visualizers.get(selectedVisualizerIndex)
    if visualizer and visualizer.reset then
        -- A visualizer that keeps state needs a chance to start fresh, since
        -- it may have been left mid animation when it was last shown.
        local resetSucceeded, resetError = pcall(function() visualizer:reset() end)
        if not resetSucceeded then
            visualizerErrorMessage = tostring(resetError)
        end
    end

    showVisualizerName()
end


function ScreenVisualizer.enter()
    -- Reset on entry so a visualizer that has been sitting idle since the last
    -- visit does not resume from stale state.
    switchToVisualizer(selectedVisualizerIndex)
end


function ScreenVisualizer.update()
    -- Decide where this frame's crank movement goes before anything else uses
    -- it. Most visualizers get it to play with, but one can ask for it to be
    -- spent on scrubbing the track instead by declaring scrubsWithCrank, and
    -- the screen is the only place that can honour that without a visualizer
    -- having to know that playback exists.
    --
    -- The threshold matches the now playing screen, so resting a hand on the
    -- crank does not creep the playhead along.
    local crankChange = playdate.getCrankChange()
    local currentVisualizer = Visualizers.get(selectedVisualizerIndex)

    if currentVisualizer and currentVisualizer.scrubsWithCrank then
        if math.abs(crankChange) > 0.5 then
            Player.addCrankScrub(crankChange)
        end
        -- Spent. The visualizer sees no movement, so nothing can react to the
        -- same turn twice.
        crankDeltaThisFrame = 0
    else
        crankDeltaThisFrame = crankChange
    end

    -- Keep the report up to date while the overlay is being watched, so the
    -- status line in it reflects a write that just happened rather than one
    -- from the last time the screen was left.
    if ScreenVisualizer.showTimings
        and playdate.getCurrentTimeMilliseconds() - lastTimingReportAttemptAtMilliseconds
            >= TIMING_REPORT_REWRITE_INTERVAL_MILLISECONDS then
        ScreenVisualizer.writeTimingReport()
    end

    if playdate.buttonJustPressed(playdate.kButtonUp) then
        switchToVisualizer(selectedVisualizerIndex + 1)
    end

    if playdate.buttonJustPressed(playdate.kButtonLeft) then
        Player.seekBy(-SEEK_STEP_IN_SECONDS)
    end

    if playdate.buttonJustPressed(playdate.kButtonRight) then
        Player.seekBy(SEEK_STEP_IN_SECONDS)
    end

    if playdate.buttonJustPressed(playdate.kButtonA) then
        Player.togglePause()
    end

    if playdate.buttonJustPressed(playdate.kButtonDown)
        or playdate.buttonJustPressed(playdate.kButtonB) then
        ScreenVisualizer.writeTimingReport()
        return "nowplaying"
    end

    return nil
end


function ScreenVisualizer.draw()
    frameNumber = frameNumber + 1

    local visualizer = Visualizers.get(selectedVisualizerIndex)
    if not visualizer then
        graphics.drawText("No visualizers registered", 100, 110)
        return
    end

    local context = Visualizers.buildContext(
        Player.currentAnalysis(),
        Player.position(),
        Player.length(),
        frameNumber,
        crankDeltaThisFrame
    )

    if visualizerErrorMessage then
        graphics.setFont(Typography.large)
        graphics.drawText(visualizer.name .. " failed", 20, 96)

        graphics.setFont(Typography.body)
        graphics.drawText(visualizerErrorMessage, 20, 120)
        graphics.drawText("up for the next visualizer", 20, 160)
        return
    end

    -- A visualizer is a plugin, and a plugin that throws should not take the
    -- player down with it. Catching here means a broken one shows a message
    -- and the rest keep working.
    local drawStartedAtMilliseconds = playdate.getCurrentTimeMilliseconds()
    local drawSucceeded, drawError = pcall(function() visualizer:draw(context) end)
    if not drawSucceeded then
        visualizerErrorMessage = tostring(drawError)
        return
    end
    recordDrawTiming(visualizer.name,
        playdate.getCurrentTimeMilliseconds() - drawStartedAtMilliseconds)

    -- Both overlays set the font explicitly. Whichever screen ran last leaves
    -- its own font selected, and the boxes here are sized by measuring the text,
    -- so an inherited font would size the box for one font and draw with
    -- another the moment the order of screens changed.
    graphics.setFont(Typography.body)

    if ScreenVisualizer.showTimings then
        local timing = drawTimingsByName[visualizer.name]
        local numbersLine = string.format("%.0fms avg  %.0fms worst  %d fps",
            timing.totalMilliseconds / timing.sampleCount,
            timing.worstMilliseconds,
            playdate.getFPS())

        -- The second line is the state of the report file. It is here rather
        -- than hidden behind a successful write, because the whole point is to
        -- be able to see that the file is not appearing.
        local statusLine = ScreenVisualizer.timingReportStatus

        local overlayWidth = math.max(
            Typography.body:getTextWidth(numbersLine),
            Typography.body:getTextWidth(statusLine))

        graphics.setColor(graphics.kColorWhite)
        graphics.fillRect(4, 198, overlayWidth + 10, 38)
        graphics.setColor(graphics.kColorBlack)
        graphics.drawRect(4, 198, overlayWidth + 10, 38)
        graphics.drawText(numbersLine, 9, 201)
        graphics.drawText(statusLine, 9, 217)
    end

    -- The name overlay after switching. It is drawn with a white box behind it
    -- because a visualizer may have filled the area with black, and text alone
    -- would be invisible.
    if playdate.getCurrentTimeMilliseconds() < nameOverlayExpiresAtMilliseconds then
        local label = string.format("%s   %d/%d",
            visualizer.name, selectedVisualizerIndex, Visualizers.count())
        local labelWidth = Typography.body:getTextWidth(label)

        graphics.setColor(graphics.kColorWhite)
        graphics.fillRect(6, 6, labelWidth + 12, 24)
        graphics.setColor(graphics.kColorBlack)
        graphics.drawRect(6, 6, labelWidth + 12, 24)
        graphics.drawText(label, 12, 10)
    end
end
