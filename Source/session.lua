-- Remembering what was playing, and picking it up again on the next launch.
--
-- A Playdate gets put down in the middle of a record far more often than it
-- gets used through to the end of one, and the screen has to stay on for audio
-- to play at all, so sessions here are short and get interrupted constantly.
-- Coming back to the top of the album list every time loses your place in a way
-- that no other music player would.
--
-- The saved state is a small JSON file written next to the library with
-- playdate.datastore, the same mechanism library.json is read with.
--
-- Whether the music starts again by itself depends on how the last session
-- ended, which is the part worth being careful about. Quitting deliberately
-- from the system menu means you were finished, so it comes back paused.
-- Running the battery flat, or the app falling over, means you were not
-- finished, so it picks up where it stopped. playdate.gameWillTerminate is what
-- separates the two: it fires on a deliberate exit, and it does not fire when
-- the device dies underneath the app. So the file is written with the exit
-- marked as unclean all the way through playback, and only rewritten as clean
-- on the way out.

import "library"
import "player"

Session = {}

local SESSION_FILE_NAME <const> = "session"

-- Bumped whenever the shape of the saved record changes. A file from an older
-- version is discarded rather than guessed at, which costs one lost resume and
-- avoids restoring nonsense.
local SESSION_FORMAT_VERSION <const> = 1

-- How often the position is written while music is playing. Writing every frame
-- would hammer the flash for no benefit, and writing only on the way out would
-- lose a whole track's worth of position whenever the battery gave out. Thirty
-- seconds is close enough that you come back somewhere you recognize.
local HEARTBEAT_INTERVAL_MILLISECONDS <const> = 30 * 1000

-- How long the last save took, and the worst one so far, both in milliseconds.
--
-- Written into the record itself rather than reported anywhere, because this is
-- here to answer one question: whether the periodic save is what can be heard as
-- an occasional hitch in the music. This device's storage is slow, the save
-- happens every thirty seconds while playing, and a stutter every thirty seconds
-- is exactly the shape of the complaint. Guessing at that would be guessing;
-- these two numbers turn it into a reading, taken on the hardware, under real
-- playback, at no cost worth measuring.
--
-- If it turns out to be a millisecond, the hitch is something else and these can
-- go. If it turns out to be two hundred, the save has to stop happening while
-- the music is playing.
local lastSaveDurationInMilliseconds = 0
local worstSaveDurationInMilliseconds = 0

local lastSaveInMilliseconds = 0


-- Find the album a saved session was playing. Matched on artist and title
-- rather than on position in the list, because the list is sorted at load time
-- and adding one record shifts everything after it.
local function findAlbumByArtistAndTitle(artist, title)
    for _, album in ipairs(Library.albums) do
        if album.artist == artist and album.title == title then
            return album
        end
    end
    return nil
end


-- Keep a value read from the file inside the range of modes the player
-- actually has, so a corrupted or hand edited file cannot leave the player in a
-- mode that does not exist.
local function clampToRange(value, lowest, highest, fallback)
    if type(value) ~= "number" or value < lowest or value > highest then
        return fallback
    end
    return math.floor(value)
end


-- Write the current state.
--
-- endedCleanly should only be true when the user chose to leave, which in
-- practice means gameWillTerminate. Everything else, including the device
-- locking and the system menu opening, is an interruption.
function Session.save(endedCleanly)
    local entry = Player.currentEntry()
    if not entry or not entry.album or not entry.track then
        return false
    end

    local record = {
        version = SESSION_FORMAT_VERSION,
        albumArtist = entry.album.artist,
        albumTitle = entry.album.title,
        -- The track's index within its album, not its position in the playback
        -- list. Those differ once the list has been shuffled, and restoring
        -- rebuilds the list from the album, so the album's own numbering is the
        -- one that survives.
        trackIndex = entry.trackIndex,
        trackFile = entry.track.file,
        positionInSeconds = Player.position(),
        wasPlaying = Player.isPlaying(),
        playMode = Player.playMode,
        repeatMode = Player.repeatMode,
        endedCleanly = endedCleanly and true or false,

        -- How long the previous save took, since a save cannot time itself.
        saveMilliseconds = lastSaveDurationInMilliseconds,
        worstSaveMilliseconds = worstSaveDurationInMilliseconds,
    }

    -- The third argument turns pretty printing off. This file is rewritten
    -- every thirty seconds while music plays, and indentation would triple the
    -- size of something nobody is ever going to read.
    local startedAtMilliseconds = playdate.getCurrentTimeMilliseconds()
    local writeSucceeded = pcall(playdate.datastore.write, record, SESSION_FILE_NAME, false)

    lastSaveInMilliseconds = playdate.getCurrentTimeMilliseconds()
    lastSaveDurationInMilliseconds = lastSaveInMilliseconds - startedAtMilliseconds
    if lastSaveDurationInMilliseconds > worstSaveDurationInMilliseconds then
        worstSaveDurationInMilliseconds = lastSaveDurationInMilliseconds
    end
    return writeSucceeded
end


-- Read the saved state back and put the player where it was. Returns true when
-- something was actually restored, so the caller knows whether to open on the
-- now playing screen or on the album list.
function Session.restore()
    if not playdate.file.exists(SESSION_FILE_NAME .. ".json") then
        return false
    end

    local readSucceeded, record = pcall(playdate.datastore.read, SESSION_FILE_NAME)
    if not readSucceeded or type(record) ~= "table" then
        return false
    end

    if record.version ~= SESSION_FORMAT_VERSION then
        return false
    end

    local album = findAlbumByArtistAndTitle(record.albumArtist, record.albumTitle)
    if not album or #album.tracks == 0 then
        return false
    end

    -- The saved track index is only trustworthy if the same track is still
    -- sitting at it. Re-ingesting with different tags, or with a sidecar added,
    -- can reorder a record, so the file path is checked first and searched for
    -- if it does not match.
    local trackIndex = record.trackIndex
    local trackAtSavedIndex = trackIndex and album.tracks[trackIndex]
    if not trackAtSavedIndex or trackAtSavedIndex.file ~= record.trackFile then
        trackIndex = nil
        for index, track in ipairs(album.tracks) do
            if track.file == record.trackFile then
                trackIndex = index
                break
            end
        end
    end

    if not trackIndex then
        return false
    end

    Player.playMode = clampToRange(record.playMode,
        Player.PLAY_MODE_IN_ORDER, Player.PLAY_MODE_SHUFFLE_ALBUMS,
        Player.PLAY_MODE_IN_ORDER)

    Player.repeatMode = clampToRange(record.repeatMode,
        Player.REPEAT_OFF, Player.REPEAT_TRACK,
        Player.REPEAT_OFF)

    -- Start playing again only if the music was playing when the session ended
    -- and the session ended against the user's will.
    local shouldPlay = record.wasPlaying == true and record.endedCleanly ~= true

    local positionInSeconds = record.positionInSeconds
    if type(positionInSeconds) ~= "number" or positionInSeconds < 0 then
        positionInSeconds = 0
    end

    local restored = Player.restore(
        Library.playbackListForAlbum(album),
        trackIndex,
        positionInSeconds,
        shouldPlay)

    if restored then
        lastSaveInMilliseconds = playdate.getCurrentTimeMilliseconds()
    end

    return restored
end


-- Called once per frame. Rewrites the session file on the heartbeat interval,
-- and only while music is actually playing, since a paused player is not
-- getting any further from where it was last saved.
function Session.update()
    if not Player.isPlaying() then
        return
    end

    local nowInMilliseconds = playdate.getCurrentTimeMilliseconds()
    if nowInMilliseconds - lastSaveInMilliseconds >= HEARTBEAT_INTERVAL_MILLISECONDS then
        Session.save(false)
    end
end
