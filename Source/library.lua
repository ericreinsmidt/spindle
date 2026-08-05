-- Loading and navigating the music library.
--
-- The library index is produced by tools/ingest.py and lives in the data
-- folder as library.json. It is read with playdate.datastore, which is the
-- only mechanism that can reach a file a build tool wrote. Executing a
-- library.lua or a compiled library.pdz does not work, because
-- playdate.file.run resolves paths against the game bundle rather than the
-- data folder.
--
-- The index deliberately holds metadata only. Per-track spectrum, onset and
-- waveform data lives in binary sidecar files, loaded on demand by analysis.lua
-- when a track is actually selected.

Library = {}

local LIBRARY_INDEX_NAME <const> = "library"

-- Every album from the index, in the order ingest emitted them.
Library.albums = {}

-- A flattened view of every track in the library, used by shuffle and by any
-- screen that needs to walk tracks without descending through albums. Each
-- entry holds the track itself plus a reference back to its album, so artist
-- and artwork stay available without a second lookup.
Library.allTracks = {}

-- Set when loading fails, so the app can explain itself rather than showing an
-- empty list and leaving the user to guess.
Library.loadError = nil


-- Sort albums the way a record shelf is usually organised, by artist and then
-- by album title, rather than by whatever order the folders happened to be
-- walked in.
local function sortAlbumsByArtistThenTitle(albums)
    table.sort(albums, function(firstAlbum, secondAlbum)
        local firstArtist = string.lower(firstAlbum.artist or "")
        local secondArtist = string.lower(secondAlbum.artist or "")
        if firstArtist ~= secondArtist then
            return firstArtist < secondArtist
        end
        return string.lower(firstAlbum.title or "") < string.lower(secondAlbum.title or "")
    end)
end


-- Read library.json and build the album list and the flattened track list.
-- Returns true when a usable library was loaded.
function Library.load()
    Library.albums = {}
    Library.allTracks = {}
    Library.loadError = nil

    if not playdate.file.exists(LIBRARY_INDEX_NAME .. ".json") then
        Library.loadError =
            "No library found.\n\nRun tools/ingest.py and copy the result into\n" ..
            "/Data/com.reinsmidt.spindle/"
        return false
    end

    local readSucceeded, indexOrError = pcall(playdate.datastore.read, LIBRARY_INDEX_NAME)
    if not readSucceeded then
        Library.loadError = "library.json could not be read:\n" .. tostring(indexOrError)
        return false
    end

    if type(indexOrError) ~= "table" or type(indexOrError.albums) ~= "table" then
        Library.loadError = "library.json did not contain an album list."
        return false
    end

    Library.albums = indexOrError.albums
    sortAlbumsByArtistThenTitle(Library.albums)

    for albumIndex, album in ipairs(Library.albums) do
        -- Guard against an album entry with no tracks, which would otherwise
        -- produce a selectable but empty row.
        album.tracks = album.tracks or {}

        for trackIndex, track in ipairs(album.tracks) do
            table.insert(Library.allTracks, {
                album = album,
                albumIndex = albumIndex,
                track = track,
                trackIndex = trackIndex,
            })
        end
    end

    if #Library.allTracks == 0 then
        Library.loadError = "The library contains no playable tracks."
        return false
    end

    return true
end


-- Build a playback list from every track on one album, in album order. This is
-- what selecting a track from an album produces, so playback continues through
-- the record rather than stopping at the end of one song.
function Library.playbackListForAlbum(album)
    local playbackList = {}
    for trackIndex, track in ipairs(album.tracks) do
        table.insert(playbackList, {
            album = album,
            track = track,
            trackIndex = trackIndex,
        })
    end
    return playbackList
end


-- Build a playback list covering the whole library in shelf order.
function Library.playbackListForEverything()
    local playbackList = {}
    for _, entry in ipairs(Library.allTracks) do
        table.insert(playbackList, {
            album = entry.album,
            track = entry.track,
            trackIndex = entry.trackIndex,
        })
    end
    return playbackList
end


-- Return a shuffled copy of a playback list, using a Fisher-Yates shuffle so
-- every ordering is equally likely. The original list is left untouched.
function Library.shuffled(playbackList)
    local shuffledList = {}
    for index, entry in ipairs(playbackList) do
        shuffledList[index] = entry
    end

    for index = #shuffledList, 2, -1 do
        local swapWith = math.random(index)
        shuffledList[index], shuffledList[swapWith] = shuffledList[swapWith], shuffledList[index]
    end

    return shuffledList
end


-- Pick an album at random. Used by the shuffle albums play mode, which puts on
-- a whole record rather than a random song.
function Library.randomAlbum()
    if #Library.albums == 0 then
        return nil
    end
    return Library.albums[math.random(#Library.albums)]
end


-- Format a duration in seconds as minutes and seconds, which is how every
-- screen wants to display it.
function Library.formatDuration(durationInSeconds)
    if not durationInSeconds or durationInSeconds < 0 then
        return "0:00"
    end
    local wholeMinutes = math.floor(durationInSeconds / 60)
    local remainingSeconds = math.floor(durationInSeconds % 60)
    return string.format("%d:%02d", wholeMinutes, remainingSeconds)
end


-- Total running time of an album, used on the album list.
function Library.albumDuration(album)
    local totalSeconds = 0
    for _, track in ipairs(album.tracks) do
        totalSeconds = totalSeconds + (track.duration or 0)
    end
    return totalSeconds
end
