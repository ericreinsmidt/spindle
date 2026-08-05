-- Spindle: an album-first music player for the Playdate.
--
-- The library is prepared on a Mac by tools/ingest.py, which converts audio to
-- ADPCM, dithers artwork to 1-bit, precomputes the spectrum and beat data the
-- visualizers need, and writes a library.json index. This app reads that index
-- once at startup and does no scanning of its own.
--
-- Two hardware facts shape almost everything here. Audio stops when the device
-- is locked or the system menu opens, so playback only happens with the screen
-- on and the three minute auto-lock has to be disabled. And MP3 seeking is a
-- linear scan costing roughly ninety milliseconds per second of seek target,
-- which is why the library is ADPCM and why scrubbing is possible at all.

import "CoreLibs/graphics"

-- getCrankTicks lives in this CoreLib rather than being built in, and the
-- library browser uses it to turn crank movement into discrete row steps.
-- Without the import it is nil and the first frame throws.
import "CoreLibs/crank"

import "library"
import "analysis"
import "player"
import "screen_library"
import "screen_nowplaying"
import "screen_visualizer"

local graphics <const> = playdate.graphics

-- Which screen is showing. Screens are plain modules with update and draw
-- functions; update returns the name of the screen to switch to, or nil to
-- stay put.
local screensByName = {
    library = ScreenLibrary,
    nowplaying = ScreenNowPlaying,
    visualizer = ScreenVisualizer,
}

local currentScreenName = "library"

-- Set when the library could not be loaded, so the app can explain what to do
-- rather than showing an empty list.
local startupFailed = false


local function switchToScreen(screenName)
    if not screensByName[screenName] or screenName == currentScreenName then
        return
    end
    currentScreenName = screenName
    local screen = screensByName[screenName]
    if screen.enter then
        screen.enter()
    end
end


-- Explain a missing or broken library, since an empty album list would leave
-- the user guessing.
local function drawStartupError()
    graphics.clear()
    graphics.drawText("*Spindle*", 8, 10)
    graphics.drawText(Library.loadError or "The library could not be loaded.", 8, 44)
end


local function setUpSystemMenu()
    local systemMenu = playdate.getSystemMenu()

    -- Audio stops when the device locks, so the three minute auto-lock would
    -- silently kill playback part way through a record. It is disabled by
    -- default and exposed here in case someone wants the normal behaviour.
    systemMenu:addCheckmarkMenuItem("keep awake", true, function(shouldKeepAwake)
        playdate.setAutoLockDisabled(shouldKeepAwake)
    end)

    -- A development aid rather than something to leave on. Shows how long each
    -- visualizer takes to draw, against a 33 millisecond budget at 30Hz.
    systemMenu:addCheckmarkMenuItem("viz timings", false, function(shouldShow)
        ScreenVisualizer.showTimings = shouldShow
        if not shouldShow then
            ScreenVisualizer.writeTimingReport()
        end
    end)
end


-- ---------------------------------------------------------------------------
-- Startup
-- ---------------------------------------------------------------------------

playdate.display.setRefreshRate(30)
playdate.setAutoLockDisabled(true)
graphics.setBackgroundColor(graphics.kColorWhite)

-- Seed the random number generator from the clock, so shuffle does not produce
-- the same order on every launch.
math.randomseed(playdate.getSecondsSinceEpoch())

if Library.load() then
    setUpSystemMenu()
else
    startupFailed = true
end


-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

-- Audio does not survive the system menu or a device lock, so there is no
-- point pretending playback continues. These callbacks exist so the app knows
-- the interruption happened, which is what a future resume feature will use to
-- decide whether to start playing again automatically.

function playdate.gameWillPause()
end


function playdate.gameWillResume()
end


function playdate.deviceWillLock()
end


function playdate.deviceDidUnlock()
end


-- ---------------------------------------------------------------------------
-- Per-frame
-- ---------------------------------------------------------------------------

function playdate.update()
    if startupFailed then
        drawStartupError()
        return
    end

    -- The player handles crank scrub commits, pre-warming the next track, and
    -- the gapless swap at each track boundary.
    Player.update()

    local screen = screensByName[currentScreenName]

    local requestedScreen = screen.update()
    if requestedScreen then
        switchToScreen(requestedScreen)
        screen = screensByName[currentScreenName]
    end

    graphics.clear()
    screen.draw()
end
