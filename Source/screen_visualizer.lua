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
--   crank         drives whichever visualizer is showing
--   left, right   seek by ten seconds, so you are never stranded here
--   up            switch to the next visualizer
--   down, B       back to now playing

import "visualizers"
import "player"
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
function ScreenVisualizer.writeTimingReport()
    local reportFile = playdate.file.open("visualizer-timings.txt", playdate.file.kFileWrite)
    if not reportFile then
        return
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
        frameNumber
    )

    if visualizerErrorMessage then
        graphics.drawText("*" .. visualizer.name .. " failed*", 20, 96)
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

    if ScreenVisualizer.showTimings then
        local timing = drawTimingsByName[visualizer.name]
        local overlay = string.format("%.0fms avg  %.0fms worst  %d fps",
            timing.totalMilliseconds / timing.sampleCount,
            timing.worstMilliseconds,
            playdate.getFPS())

        local overlayWidth = graphics.getTextSize(overlay)
        graphics.setColor(graphics.kColorWhite)
        graphics.fillRect(4, 214, overlayWidth + 10, 22)
        graphics.setColor(graphics.kColorBlack)
        graphics.drawRect(4, 214, overlayWidth + 10, 22)
        graphics.drawText(overlay, 9, 217)
    end

    -- The name overlay after switching. It is drawn with a white box behind it
    -- because a visualizer may have filled the area with black, and text alone
    -- would be invisible.
    if playdate.getCurrentTimeMilliseconds() < nameOverlayExpiresAtMilliseconds then
        local label = string.format("%s   %d/%d",
            visualizer.name, selectedVisualizerIndex, Visualizers.count())
        local labelWidth = graphics.getTextSize(label)

        graphics.setColor(graphics.kColorWhite)
        graphics.fillRect(6, 6, labelWidth + 12, 24)
        graphics.setColor(graphics.kColorBlack)
        graphics.drawRect(6, 6, labelWidth + 12, 24)
        graphics.drawText(label, 12, 10)
    end
end
