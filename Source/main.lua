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
import "player"
import "session"
import "typography"
import "artwork"
import "screen_library"
import "screen_nowplaying"
import "screen_visualizer"
import "screen_pocket"
import "screen_empty"

local graphics <const> = playdate.graphics

-- Which screen is showing. Screens are plain modules with update and draw
-- functions; update returns the name of the screen to switch to, or nil to
-- stay put.
local screensByName = {
    library = ScreenLibrary,
    nowplaying = ScreenNowPlaying,
    visualizer = ScreenVisualizer,
    pocket = ScreenPocket,
    empty = ScreenEmpty,
}

local currentScreenName = "library"

-- Set when a library was present but could not be loaded, so the app can explain
-- what went wrong rather than showing an empty list.
--
-- Having no library at all is a separate thing and is not this. That is a new
-- install, it is what everybody sees the first time, and it goes to a screen of
-- its own rather than through here.
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


-- Explain a broken library, since an empty album list would leave the user
-- guessing. A library that is simply absent does not come here.
local function drawStartupError()
    graphics.clear()

    -- The fonts are set explicitly here rather than relying on whatever was set
    -- last. The asterisk markup that used to make this heading bold only works
    -- with a registered font family, and the app now draws with single fonts
    -- loaded by hand, so the large font is what makes a heading a heading.
    graphics.setFont(Typography.large)
    graphics.drawText("Spindle", 8, 10)

    graphics.setFont(Typography.body)
    graphics.drawText(Library.loadError or "The library could not be loaded.", 8, 44)
end


-- Nothing is added to the system menu.
--
-- Two things used to be. A "keep awake" checkbox, which only ever existed to
-- turn off something the app needs on: audio stops dead when the device locks,
-- so auto-lock is disabled at startup and nobody wants it back. And a "viz
-- timings" checkbox, which was a development aid and is switched off in
-- screen_visualizer.lua by a constant rather than by a menu item now.


-- ---------------------------------------------------------------------------
-- Startup
-- ---------------------------------------------------------------------------

playdate.display.setRefreshRate(30)
playdate.setAutoLockDisabled(true)

-- The system plays a clunk when the crank is deployed or docked. It belongs in a
-- game and it does not belong over a record, so it is off. The system turns it
-- back on by itself when this app terminates, so nothing leaks into the
-- launcher or into anything else.
playdate.setCrankSoundsDisabled(true)
graphics.setBackgroundColor(graphics.kColorWhite)

-- White on black, for the whole app, always.
--
-- This happens at the display level rather than in any drawing code, so nothing
-- has to know about it and it costs nothing. The alternative would have been
-- clearing to black and setting every draw color to white, which means touching
-- every screen and every visualizer for something available for free.
--
-- It was briefly a system menu checkbox. It is not a preference: it is what
-- Spindle looks like. Album artwork is the one thing that has to be flipped back
-- on the way in, which artwork.lua handles, because a negative of a face does
-- not read as a face.
--
-- Set before the library is loaded, so the screen explaining a missing library
-- is inverted too rather than being the one white thing anyone ever sees.
playdate.display.setInverted(true)

-- Seed the random number generator from the clock, so shuffle does not produce
-- the same order on every launch.
math.randomseed(playdate.getSecondsSinceEpoch())

if Library.load() then
    -- Pick up where the last session left off. Whether the music starts again
    -- by itself depends on how that session ended, which session.lua works out
    -- from the file it saved. When there is nothing to restore this does
    -- nothing and the app opens on the album list as before.
    if Session.restore() then
        switchToScreen("nowplaying")
    end
elseif Library.isMissing then
    -- A new install, which is not a failure. The empty screen explains how to
    -- get music on here, and it is a screen rather than a message because it is
    -- the only thing a first time user or a reviewer will see until they do.
    currentScreenName = "empty"
    ScreenEmpty.enter()
else
    startupFailed = true
end


-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

-- Audio does not survive the system menu or a device lock, so every one of
-- these is a moment where playback is about to be interrupted and the position
-- is about to stop being worth anything. Each saves the session, marked as an
-- interruption rather than a clean exit, so that whatever happens next the app
-- knows where it was.
--
-- gameWillTerminate is the one exception. It only fires when the user chose to
-- leave, so it is the single place the session is marked as having ended
-- cleanly, and that is what stops the app from starting the music again by
-- itself on the next launch.
--
-- The matching gameWillResume and deviceDidUnlock are not defined. They are
-- optional, coming back needs nothing done, and an empty function that the
-- system calls to do nothing is worse than no function at all.

function playdate.gameWillPause()
    Session.save(false)
end


function playdate.deviceWillLock()
    Session.save(false)
end


function playdate.deviceWillSleep()
    Session.save(false)
end


function playdate.gameWillTerminate()
    Session.save(true)
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

    -- Rewrites the session file every so often while music plays, so a flat
    -- battery costs at most half a minute of position rather than the whole
    -- track.
    Session.update()

    local screen = screensByName[currentScreenName]

    local requestedScreen = screen.update()
    if requestedScreen then
        switchToScreen(requestedScreen)
        screen = screensByName[currentScreenName]
    end

    -- Screens normally get a freshly cleared frame. Pocket mode takes that over
    -- so it can leave the previous frame on the display and draw nothing at all,
    -- which is where its saving comes from.
    if screen.ownsItsOwnClearing then
        screen.draw()
    else
        graphics.clear()
        screen.draw()
    end
end
