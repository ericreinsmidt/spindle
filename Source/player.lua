-- The playback engine.
--
-- Two things here are unusual, and both come from measurements taken on real
-- hardware rather than from preference.
--
-- First, the playhead is tracked locally as a start position plus elapsed wall
-- clock time, rather than being read back from the fileplayer. On MP3 the
-- getOffset and getLength calls return wrong values after a seek, and although
-- the library is ADPCM now, tracking it ourselves is both accurate and free.
--
-- Second, gapless playback works by pre-warming the next track on a sound
-- channel whose volume is zero, then swapping the two channel volumes at the
-- track boundary. The distinction that makes this work is that calling
-- setVolume(0) on a player stops it decoding entirely, so a player cannot be
-- pre-warmed by muting it. Muting the channel it sits on does not stop the
-- decoder. Two ADPCM players coexist happily, both decoding at real time, and
-- the swap is instant and silent.

import "library"
import "analysis"

Player = {}

local sound <const> = playdate.sound

-- How long before the end of a track to start warming the next one. The warm
-- costs about 85 milliseconds of blocking work, so it wants to happen well
-- away from the boundary where a stutter would be audible.
local PREWARM_LEAD_IN_SECONDS <const> = 10

-- Crank scrubbing accumulates and commits on this interval rather than every
-- frame. Committing a seek per frame hammered the storage layer badly enough
-- to hard fault the device during Phase 0.
local SCRUB_COMMIT_INTERVAL_MILLISECONDS <const> = 150

-- How far a full revolution of the crank moves the playhead.
local SCRUB_SECONDS_PER_CRANK_REVOLUTION <const> = 30

Player.PLAY_MODE_IN_ORDER = 1
Player.PLAY_MODE_SHUFFLE_TRACKS = 2
Player.PLAY_MODE_SHUFFLE_ALBUMS = 3

Player.PLAY_MODE_NAMES = {
    [Player.PLAY_MODE_IN_ORDER] = "in order",
    [Player.PLAY_MODE_SHUFFLE_TRACKS] = "shuffle tracks",
    [Player.PLAY_MODE_SHUFFLE_ALBUMS] = "shuffle albums",
}

-- The list of entries currently queued for playback, and where we are in it.
-- Each entry is a table holding an album and a track, as built by library.lua.
local playbackList = {}
local positionInPlaybackList = 1

-- The audible player and the channel it sits on.
local activePlayer = nil
local activeChannel = nil

-- The next track, already created and decoding silently on a muted channel,
-- ready to be swapped in. warmedForPlaybackPosition records which entry it
-- holds, so a change of track invalidates it rather than playing the wrong
-- song.
local warmedPlayer = nil
local warmedChannel = nil
local warmedForPlaybackPosition = nil

-- Locally tracked playhead.
local playheadBaseInSeconds = 0
local playheadClockInMilliseconds = 0
local isCurrentlyPlaying = false

-- Cached details of the track that is playing, so nothing needs to be read
-- back from the player during normal operation.
local currentTrackLengthInSeconds = 0
local currentAnalysis = nil

-- Crank scrubbing state.
local pendingScrubInSeconds = 0
local lastScrubCommitInMilliseconds = 0

Player.playMode = Player.PLAY_MODE_IN_ORDER


-- ---------------------------------------------------------------------------
-- Playhead
-- ---------------------------------------------------------------------------

local function currentTimeInMilliseconds()
    return playdate.getCurrentTimeMilliseconds()
end


function Player.position()
    if not isCurrentlyPlaying then
        return playheadBaseInSeconds
    end
    local elapsedMilliseconds = currentTimeInMilliseconds() - playheadClockInMilliseconds
    return playheadBaseInSeconds + elapsedMilliseconds / 1000
end


function Player.length()
    return currentTrackLengthInSeconds
end


function Player.isPlaying()
    return isCurrentlyPlaying
end


function Player.currentEntry()
    return playbackList[positionInPlaybackList]
end


function Player.currentAnalysis()
    return currentAnalysis
end


function Player.hasTrackLoaded()
    return activePlayer ~= nil
end


local function setPlayheadTo(positionInSeconds)
    playheadBaseInSeconds = positionInSeconds
    playheadClockInMilliseconds = currentTimeInMilliseconds()
end


-- ---------------------------------------------------------------------------
-- Creating and discarding players
-- ---------------------------------------------------------------------------

-- Build a fileplayer for a track and attach it to its own channel, so its
-- volume can be controlled independently of anything else that is playing.
-- The player itself is left at full volume, because muting the player stops it
-- decoding. Channel volume is what gets adjusted.
local function createPlayerForTrack(track, channelVolume)
    local filePlayer = sound.fileplayer.new(track.file)
    if not filePlayer then
        return nil, nil
    end

    local channel = sound.channel.new()
    channel:setVolume(channelVolume)
    channel:addSource(filePlayer)

    filePlayer:setVolume(1)
    filePlayer:play(1)

    return filePlayer, channel
end


local function discardPlayer(filePlayer, channel)
    if filePlayer then
        filePlayer:setFinishCallback(nil)
        filePlayer:stop()
    end
    if channel then
        channel:remove()
    end
end


local function discardWarmedPlayer()
    discardPlayer(warmedPlayer, warmedChannel)
    warmedPlayer = nil
    warmedChannel = nil
    warmedForPlaybackPosition = nil
end


-- ---------------------------------------------------------------------------
-- Starting playback
-- ---------------------------------------------------------------------------

-- Begin playing whichever entry sits at the given position in the playback
-- list. startAtSeconds allows resuming part way through, which is how the app
-- restores a session.
local function startEntryAt(playbackPosition, startAtSeconds)
    local entry = playbackList[playbackPosition]
    if not entry then
        return false
    end

    discardPlayer(activePlayer, activeChannel)
    discardWarmedPlayer()

    local filePlayer, channel = createPlayerForTrack(entry.track, 1)
    if not filePlayer then
        activePlayer = nil
        activeChannel = nil
        return false
    end

    activePlayer = filePlayer
    activeChannel = channel
    positionInPlaybackList = playbackPosition

    -- getLength is accurate here, before any seek has touched the player, so
    -- it is read exactly once and cached. The value from the index is used as
    -- a fallback in case the player cannot report one.
    currentTrackLengthInSeconds = activePlayer:getLength() or entry.track.duration or 0

    if startAtSeconds and startAtSeconds > 0 then
        activePlayer:setOffset(startAtSeconds)
        setPlayheadTo(startAtSeconds)
    else
        setPlayheadTo(0)
    end

    isCurrentlyPlaying = true
    pendingScrubInSeconds = 0

    currentAnalysis = Analysis.load(entry.track.analysis)

    return true
end


-- Play a list of entries, starting at the given position. This is the entry
-- point every screen uses: choosing a track from an album passes that album's
-- whole track list, so playback continues through the record.
function Player.playList(entries, startPosition)
    playbackList = entries or {}
    if #playbackList == 0 then
        return false
    end

    startPosition = startPosition or 1

    if Player.playMode == Player.PLAY_MODE_SHUFFLE_TRACKS then
        -- Shuffle everything, but keep whatever the user actually chose as the
        -- first thing that plays. Picking a song and getting a different one
        -- would be surprising, even in shuffle.
        local chosenEntry = playbackList[startPosition]
        playbackList = Library.shuffled(playbackList)

        for index, entry in ipairs(playbackList) do
            if entry == chosenEntry then
                playbackList[index] = playbackList[1]
                playbackList[1] = chosenEntry
                break
            end
        end

        startPosition = 1
    end

    return startEntryAt(startPosition, 0)
end


-- ---------------------------------------------------------------------------
-- Transport
-- ---------------------------------------------------------------------------

function Player.togglePause()
    if not activePlayer then
        return
    end

    if isCurrentlyPlaying then
        -- Freeze the playhead before pausing, so it stops advancing.
        playheadBaseInSeconds = Player.position()
        isCurrentlyPlaying = false
        activePlayer:pause()
    else
        activePlayer:play(1)
        setPlayheadTo(playheadBaseInSeconds)
        isCurrentlyPlaying = true
    end
end


-- Move the playhead to an absolute position. On ADPCM this costs about one
-- millisecond, which is why scrubbing is viable at all.
function Player.seekTo(targetInSeconds)
    if not activePlayer or currentTrackLengthInSeconds <= 0 then
        return
    end

    local clampedTarget = targetInSeconds
    if clampedTarget < 0 then
        clampedTarget = 0
    end
    -- Stop just short of the very end, so seeking to the end does not
    -- immediately trigger a track change.
    if clampedTarget > currentTrackLengthInSeconds - 1 then
        clampedTarget = currentTrackLengthInSeconds - 1
    end

    activePlayer:setOffset(clampedTarget)
    setPlayheadTo(clampedTarget)

    -- A seek invalidates any pre-warmed next track, because the boundary it
    -- was warmed for may no longer be close.
    discardWarmedPlayer()
end


function Player.seekBy(offsetInSeconds)
    Player.seekTo(Player.position() + offsetInSeconds)
end


-- Accumulate crank movement for scrubbing. The commit is rate limited by
-- Player.update rather than happening here, because committing a seek on every
-- frame hard faulted the device during Phase 0.
function Player.addCrankScrub(crankChangeInDegrees)
    if not activePlayer then
        return
    end
    pendingScrubInSeconds = pendingScrubInSeconds
        + (crankChangeInDegrees / 360) * SCRUB_SECONDS_PER_CRANK_REVOLUTION
end


-- Choose what plays after the current entry, honouring the play mode. Returns
-- the playback list position to move to, or nil when playback should stop.
local function nextPlaybackPosition()
    if Player.playMode == Player.PLAY_MODE_SHUFFLE_ALBUMS
        and positionInPlaybackList >= #playbackList then
        -- The record finished, so put on another one at random.
        local nextAlbum = Library.randomAlbum()
        if nextAlbum then
            playbackList = Library.playbackListForAlbum(nextAlbum)
            return 1
        end
    end

    if positionInPlaybackList < #playbackList then
        return positionInPlaybackList + 1
    end

    return nil
end


function Player.skipToNext()
    local nextPosition = nextPlaybackPosition()
    if nextPosition then
        startEntryAt(nextPosition, 0)
    end
end


function Player.skipToPrevious()
    -- Matching every other music player: pressing back part way through a
    -- track restarts it, and only goes to the previous track if you are
    -- already near the beginning.
    if Player.position() > 3 then
        Player.seekTo(0)
        return
    end

    if positionInPlaybackList > 1 then
        startEntryAt(positionInPlaybackList - 1, 0)
    else
        Player.seekTo(0)
    end
end


function Player.cyclePlayMode()
    Player.playMode = Player.playMode + 1
    if Player.playMode > Player.PLAY_MODE_SHUFFLE_ALBUMS then
        Player.playMode = Player.PLAY_MODE_IN_ORDER
    end

    -- Switching into track shuffle reshuffles what is left, keeping whatever
    -- is currently playing where it is so the music does not jump.
    if Player.playMode == Player.PLAY_MODE_SHUFFLE_TRACKS then
        local currentEntry = playbackList[positionInPlaybackList]
        playbackList = Library.shuffled(playbackList)
        for index, entry in ipairs(playbackList) do
            if entry == currentEntry then
                playbackList[index] = playbackList[positionInPlaybackList]
                playbackList[positionInPlaybackList] = currentEntry
                break
            end
        end
    end

    discardWarmedPlayer()
end


function Player.playModeName()
    return Player.PLAY_MODE_NAMES[Player.playMode]
end


-- ---------------------------------------------------------------------------
-- Per-frame work
-- ---------------------------------------------------------------------------

-- Prepare the next track so the transition can be instant. The new player is
-- created on a muted channel at full player volume, which is the combination
-- that decodes silently.
local function warmNextTrack()
    local upcomingPosition = nextPlaybackPosition()
    if not upcomingPosition then
        return
    end

    local upcomingEntry = playbackList[upcomingPosition]
    if not upcomingEntry then
        return
    end

    local filePlayer, channel = createPlayerForTrack(upcomingEntry.track, 0)
    if not filePlayer then
        return
    end

    warmedPlayer = filePlayer
    warmedChannel = channel
    warmedForPlaybackPosition = upcomingPosition
end


-- Swap the warmed player in. Because it has been decoding silently since it
-- was warmed, it is some seconds into the track by now, so it gets seeked back
-- to the start first. On ADPCM that costs about a millisecond.
local function swapToWarmedTrack()
    local upcomingEntry = playbackList[warmedForPlaybackPosition]
    if not upcomingEntry then
        discardWarmedPlayer()
        return
    end

    warmedPlayer:setOffset(0)
    warmedChannel:setVolume(1)

    discardPlayer(activePlayer, activeChannel)

    activePlayer = warmedPlayer
    activeChannel = warmedChannel
    positionInPlaybackList = warmedForPlaybackPosition

    warmedPlayer = nil
    warmedChannel = nil
    warmedForPlaybackPosition = nil

    currentTrackLengthInSeconds = upcomingEntry.track.duration or 0
    setPlayheadTo(0)
    isCurrentlyPlaying = true

    currentAnalysis = Analysis.load(upcomingEntry.track.analysis)
end


-- Called once per frame. Handles crank scrub commits, pre-warming, and the
-- track boundary.
function Player.update()
    if not activePlayer then
        return
    end

    -- Commit any accumulated crank movement, rate limited.
    local nowInMilliseconds = currentTimeInMilliseconds()
    if pendingScrubInSeconds ~= 0
        and nowInMilliseconds - lastScrubCommitInMilliseconds >= SCRUB_COMMIT_INTERVAL_MILLISECONDS then
        local scrubTarget = Player.position() + pendingScrubInSeconds
        pendingScrubInSeconds = 0
        lastScrubCommitInMilliseconds = nowInMilliseconds
        Player.seekTo(scrubTarget)
    end

    if not isCurrentlyPlaying then
        return
    end

    local position = Player.position()

    -- Warm the next track once the current one is close enough to the end.
    if not warmedPlayer
        and currentTrackLengthInSeconds > PREWARM_LEAD_IN_SECONDS
        and position >= currentTrackLengthInSeconds - PREWARM_LEAD_IN_SECONDS then
        warmNextTrack()
    end

    -- Swap at the boundary.
    if position >= currentTrackLengthInSeconds then
        if warmedPlayer then
            swapToWarmedTrack()
        else
            local nextPosition = nextPlaybackPosition()
            if nextPosition then
                startEntryAt(nextPosition, 0)
            else
                -- Nothing left to play, so stop cleanly at the end.
                isCurrentlyPlaying = false
                playheadBaseInSeconds = currentTrackLengthInSeconds
            end
        end
    end
end


-- Stop everything and release both players. Used when the app is shutting down
-- or the library is being reloaded.
function Player.stop()
    discardPlayer(activePlayer, activeChannel)
    discardWarmedPlayer()
    activePlayer = nil
    activeChannel = nil
    isCurrentlyPlaying = false
end
