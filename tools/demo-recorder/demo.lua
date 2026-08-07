-- TEMPORARY. The demo recorder. Delete this file, its import in main.lua, the
-- call to Demo.install at the bottom of main.lua, and the two debug accessors
-- at the end of screen_library.lua once the video has been made.
--
-- This drives the real app through a scripted sequence of button presses and
-- crank movement, writing every frame out as a PNG. It is not a screen
-- recording. Nothing is captured from the display; the app draws its own frames
-- and hands them over one at a time, so the result is exact regardless of how
-- slowly the Simulator produced them.
--
-- That last point is the whole reason this exists. Writing a PNG every frame
-- drops the Simulator well below thirty a second, and a screen recording of
-- that is a recording of the Simulator struggling. It also means anything that
-- reads the clock runs several times too fast in the finished video, because
-- the clock keeps real time while the frames crawl.
--
-- So the clock is replaced as well. playdate.getCurrentTimeMilliseconds is
-- overridden to advance by exactly one frame's worth per frame, and everything
-- downstream of it follows: the playhead, the crank scrub rate limiter, the
-- hold timers on now playing, the visualizer name overlay. One override rather
-- than one per feature, because the player derives its position from the clock
-- rather than keeping its own.
--
-- The audio the Simulator plays during a run is worth ignoring. It comes out at
-- real speed while the frames crawl, so it will sound wrong. It is not being
-- recorded. The finished video takes its sound from the original file that the
-- .pda was converted from, lined up using the numbers written into the manifest.

import "CoreLibs/graphics"

Demo = {}

-- The one switch. False leaves the app completely alone.
Demo.ENABLED = true

local graphics <const> = playdate.graphics

local FRAMES_PER_SECOND <const> = 30
local MILLISECONDS_PER_FRAME <const> = 1000 / FRAMES_PER_SECOND

-- Frames are written to the development machine rather than into the Playdate
-- filesystem, which is why the path starts with a tilde. The folder has to exist
-- already, because this cannot create one on the host.
local FRAME_FOLDER <const> = "~/spindle-demo/"

-- The manifest goes into the app's data folder, where it can be read back off
-- the Simulator's disk. It carries the numbers the muxing step needs.
local MANIFEST_FILE_NAME <const> = "demo-manifest.txt"

-- How long a scripted press lasts. Three frames rather than one, because two
-- of the app's controls act on release rather than on press, and a release the
-- screen never saw a matching press for is deliberately ignored.
local PRESS_LENGTH_IN_FRAMES <const> = 3

-- A ceiling on the scroll steps, so that a library where nothing is playable
-- cannot spin forever.
local SCROLL_LIMIT_IN_SECONDS <const> = 15

-- A floor on them as well, so that the list is always seen moving.
--
-- Without this the first version stopped on its first frame, because the top row
-- of the list is a playlist and a playlist's first track resolves perfectly
-- well. The step did what it was told and the demo opened without ever
-- scrolling, which is not what a shelf of records should look like.
local MINIMUM_SCROLL_IN_SECONDS <const> = 2.5


-- The script.
--
-- Each step lasts a number of seconds, optionally starts with a button press,
-- and optionally turns the crank at a number of degrees per second. Steps run
-- in order and the whole thing is deterministic, so the same script produces
-- the same video every time.
--
-- The visualizer section presses up between each one, which is what steps
-- through the picker, and gives each a crank speed that suits it. Spectrum gets
-- none because it is the one that ignores the crank.
--
-- Nothing here may move the playhead other than playing the track. The sound in
-- the finished video is the original file played straight through, so anything
-- that jumps the position puts the picture and the sound permanently out of step
-- from that moment on. That rules out crank scrubbing on now playing, the ten
-- second seeks on the visualizer screen, and pausing, all of which are real
-- features and none of which can be shown this way. Scrubbing was in an earlier
-- version of this script and is what the rule was learned from.
local timeline <const> = {
    { seconds = 1.5 },                                    -- the album list, held still
    { crank = 220, scrollUntilPlayable = true },          -- run down the shelf
    { seconds = 1.2 },
    { press = "a", seconds = 1.8 },                       -- open the record
    { crank = 130, scrollTracksUntilPlayable = true },    -- down the track list
    { seconds = 0.8 },
    { press = "a", seconds = 9.5 },                       -- play it, and sit on now playing

    { press = "up", seconds = 2.0 },                      -- into the visualizers, on Sleeve
    { crank = 130, seconds = 4.0 },
    { press = "up", crank = 220, seconds = 4.5 },         -- Garden o' Sound
    { press = "up", seconds = 4.0 },                      -- Maigasa
    { press = "up", crank = 160, seconds = 5.0 },         -- Koi
    { press = "up", crank = 130, seconds = 4.5 },         -- Slime
    { press = "up", crank = 260, seconds = 5.5 },         -- Spirograph
    { press = "up", crank = 100, seconds = 4.0 },         -- Triforce
    { press = "up", crank = 70,  seconds = 5.0 },         -- Haring
    { press = "up", seconds = 3.0 },                      -- Spectrum

    { press = "down", seconds = 3.5 },                    -- back to now playing
}


local buttonsByName <const> = {
    a = playdate.kButtonA,
    b = playdate.kButtonB,
    up = playdate.kButtonUp,
    down = playdate.kButtonDown,
    left = playdate.kButtonLeft,
    right = playdate.kButtonRight,
}


-- Where the run has got to.
local frameNumber = 0
local virtualClockInMilliseconds = 0
local stepIndex = 1
local framesLeftInStep = nil
local framesScrolledSoFar = 0
local stepHasStarted = false
local hasFinished = false

-- What the app is told about the buttons this frame.
local heldButtons = {}
local pressedThisFrame = {}
local releasedThisFrame = {}
local runningPress = nil

-- Crank state. The angle accumulates so that tick counting can work the way the
-- real one does, by asking how far it has turned since it was last asked.
local crankDeltaThisFrame = 0
local crankAngleInDegrees = 0
local angleAtLastTick = 0

-- Recorded when the music actually starts, which is what lines the audio up
-- against the frames later.
local playbackStartFrame = nil
local playbackStartPositionInSeconds = 0


-- Is this collection something that will actually make a sound?
--
-- The Simulator's data folder usually holds artwork for the whole library but
-- audio for only part of it, since the audio is a gigabyte and the artwork is
-- not. An album with no audio looks completely normal in the list and plays
-- nothing, which would be a silent demo, so the scroll step keeps going until
-- it finds one whose first track is really there.
local function entryIsPlayable(entry)
    return entry ~= nil
        and entry.track ~= nil
        and entry.track.file ~= nil
        and playdate.file.exists(entry.track.file)
end


-- A record rather than a playlist, and one that will make a sound.
--
-- Playlists are excluded on purpose. They are a real feature and worth showing,
-- but this is an album-first player and the demo should open on a record.
local function collectionIsPlayableAlbum(collection)
    if not collection or collection.isPlaylist or not collection.entries then
        return false
    end

    return entryIsPlayable(collection.entries[1])
end


local function selectedCollectionIsPlayableAlbum()
    if not ScreenLibrary.debugCollections then
        return true
    end

    local collections = ScreenLibrary.debugCollections()
    return collectionIsPlayableAlbum(collections[ScreenLibrary.debugSelectedIndex()])
end


-- The same question for the track list, since an album whose first track is
-- present may still be missing the rest, and stopping the crank on a silent
-- track would give a demo with a picture and no sound.
local function selectedTrackIsPlayable()
    if not ScreenLibrary.debugOpenedCollection then
        return true
    end

    local collection = ScreenLibrary.debugOpenedCollection()
    if not collection or not collection.entries then
        return false
    end

    return entryIsPlayable(collection.entries[ScreenLibrary.debugSelectedTrackIndex()])
end


-- Take one frame off whichever press is running, and report the result to the
-- app the way the real button functions would.
local function advanceButtons()
    pressedThisFrame = {}
    releasedThisFrame = {}

    if not runningPress then
        return
    end

    if not heldButtons[runningPress.button] then
        heldButtons[runningPress.button] = true
        pressedThisFrame[runningPress.button] = true
    end

    runningPress.framesLeft = runningPress.framesLeft - 1
    if runningPress.framesLeft <= 0 then
        heldButtons[runningPress.button] = nil
        releasedThisFrame[runningPress.button] = true
        runningPress = nil
    end
end


-- Begin the step the run has reached, and return it. Returns nil once the
-- script has been played out.
local function currentStep()
    local step = timeline[stepIndex]
    if not step then
        return nil
    end

    if not stepHasStarted then
        stepHasStarted = true

        if step.press then
            runningPress = {
                button = buttonsByName[step.press],
                framesLeft = PRESS_LENGTH_IN_FRAMES,
            }
        end

        if step.scrollUntilPlayable or step.scrollTracksUntilPlayable then
            framesLeftInStep = math.floor(SCROLL_LIMIT_IN_SECONDS * FRAMES_PER_SECOND)
            framesScrolledSoFar = 0
        else
            framesLeftInStep = math.floor((step.seconds or 0) * FRAMES_PER_SECOND)
        end
    end

    return step
end


local function finishStep()
    stepIndex = stepIndex + 1
    stepHasStarted = false
    framesLeftInStep = nil
end


local function writeManifest()
    local manifest = playdate.file.open(MANIFEST_FILE_NAME, playdate.file.kFileWrite)
    if not manifest then
        return
    end

    local entry = Player.currentEntry()
    local album = entry and entry.album
    local track = entry and entry.track

    manifest:write(string.format("framesPerSecond %d\n", FRAMES_PER_SECOND))
    manifest:write(string.format("frameCount %d\n", frameNumber))
    manifest:write(string.format("playbackStartFrame %d\n", playbackStartFrame or 0))
    manifest:write(string.format("playbackStartPosition %.3f\n", playbackStartPositionInSeconds))

    -- Where the playhead finished. The muxing step compares this against how
    -- many frames went by, which is what proves the audio and the picture stayed
    -- in step. If the script ever scrubs, seeks or pauses again, the two numbers
    -- part company and the tool says so instead of quietly producing a video
    -- that drifts.
    manifest:write(string.format("playbackEndPosition %.3f\n", Player.position()))
    manifest:write(string.format("albumArtist %s\n", album and album.artist or "unknown"))
    manifest:write(string.format("albumTitle %s\n", album and album.title or "unknown"))
    manifest:write(string.format("trackTitle %s\n", track and track.title or "unknown"))
    manifest:write(string.format("trackFile %s\n", track and track.file or "unknown"))

    manifest:close()
end


-- Replace the app's per frame function with one that feeds it scripted input on
-- a scripted clock, then writes out what it drew.
--
-- Called from the bottom of main.lua rather than at import, because the function
-- being wrapped does not exist until main.lua has finished defining it.
function Demo.install()
    local appUpdate = playdate.update

    playdate.getCurrentTimeMilliseconds = function()
        return math.floor(virtualClockInMilliseconds)
    end

    playdate.buttonJustPressed = function(button)
        return pressedThisFrame[button] == true
    end

    playdate.buttonIsPressed = function(button)
        return heldButtons[button] == true
    end

    playdate.buttonJustReleased = function(button)
        return releasedThisFrame[button] == true
    end

    playdate.getCrankChange = function()
        return crankDeltaThisFrame, crankDeltaThisFrame
    end

    -- The library list scrolls on ticks rather than on raw degrees, so this has
    -- to count them the same way the real one does: hand back a tick every time
    -- the accumulated angle has moved another notch, in whichever direction.
    playdate.getCrankTicks = function(ticksPerRevolution)
        local degreesPerTick = 360 / ticksPerRevolution
        local ticks = 0

        while crankAngleInDegrees - angleAtLastTick >= degreesPerTick do
            angleAtLastTick = angleAtLastTick + degreesPerTick
            ticks = ticks + 1
        end
        while crankAngleInDegrees - angleAtLastTick <= -degreesPerTick do
            angleAtLastTick = angleAtLastTick - degreesPerTick
            ticks = ticks - 1
        end

        return ticks
    end

    playdate.update = function()
        if hasFinished then
            return
        end

        local step = currentStep()
        if not step then
            hasFinished = true
            writeManifest()
            return
        end

        frameNumber = frameNumber + 1
        virtualClockInMilliseconds = virtualClockInMilliseconds + MILLISECONDS_PER_FRAME

        advanceButtons()

        crankDeltaThisFrame = (step.crank or 0) / FRAMES_PER_SECOND
        crankAngleInDegrees = crankAngleInDegrees + crankDeltaThisFrame

        appUpdate()

        -- Noted the first time the music is actually running, which is the
        -- frame the audio has to be lined up against in the finished video.
        if not playbackStartFrame and Player.isPlaying() then
            playbackStartFrame = frameNumber
            playbackStartPositionInSeconds = Player.position()
        end

        playdate.simulator.writeToFile(
            graphics.getWorkingImage(),
            string.format("%sframe-%05d.png", FRAME_FOLDER, frameNumber))

        framesLeftInStep = framesLeftInStep - 1

        if step.scrollUntilPlayable or step.scrollTracksUntilPlayable then
            -- These steps end when they have found something worth playing
            -- rather than after a fixed time, so the demo never opens a record
            -- or picks a track with no audio behind it. The minimum keeps the
            -- list moving for long enough to be seen either way, and the
            -- countdown is the ceiling that stops a library with nothing
            -- playable in it from scrolling forever.
            framesScrolledSoFar = framesScrolledSoFar + 1

            local hasScrolledEnough =
                framesScrolledSoFar >= MINIMUM_SCROLL_IN_SECONDS * FRAMES_PER_SECOND

            local hasFoundOne
            if step.scrollTracksUntilPlayable then
                hasFoundOne = selectedTrackIsPlayable()
            else
                hasFoundOne = selectedCollectionIsPlayableAlbum()
            end

            if (hasScrolledEnough and hasFoundOne) or framesLeftInStep <= 0 then
                finishStep()
            end
        elseif framesLeftInStep <= 0 then
            finishStep()
        end
    end
end
