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

-- Playlists, each holding a name and a list of entries in exactly the shape
-- playbackListForAlbum produces. They are resolved at load, so nothing that
-- browses or plays them needs to know whether it is looking at a playlist or an
-- album.
Library.playlists = {}

-- How many tracks the library holds in total, across every album.
--
-- This used to be a flattened list with an entry per track, built so shuffle and
-- any screen wanting to walk tracks could avoid descending through albums.
-- Nothing walks it any more, and building a table per track to answer one
-- question is not worth it, so it is a count.
Library.trackCount = 0

-- Set when loading fails, so the app can explain itself rather than showing an
-- empty list and leaving the user to guess.
Library.loadError = nil


-- Sort albums the way a record shelf is usually organized, by artist and then
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


-- Turn the playlists in the index into playable entries.
--
-- The index stores a playlist as a list of converted audio paths and nothing
-- else, because everything else about a track already exists on the album it
-- belongs to. Repeating the title and duration there would be a second copy to
-- keep in step, and playlists exist precisely so a track can appear in more than
-- one place without being stored twice.
--
-- The cost of that is one pass here building a lookup from path to track, which
-- only happens when there are playlists to resolve. A track named by a playlist
-- but missing from the library is dropped rather than left as a hole, since
-- there is nothing sensible to draw or play for it.
local function resolvePlaylists(playlistsFromIndex)
    if type(playlistsFromIndex) ~= "table" or #playlistsFromIndex == 0 then
        return
    end

    local entryByFile = {}
    for _, album in ipairs(Library.albums) do
        for trackIndex, track in ipairs(album.tracks) do
            if track.file then
                entryByFile[track.file] = {
                    album = album,
                    track = track,
                    trackIndex = trackIndex,
                }
            end
        end
    end

    for _, playlistFromIndex in ipairs(playlistsFromIndex) do
        local entries = {}

        for _, file in ipairs(playlistFromIndex.tracks or {}) do
            local entry = entryByFile[file]
            if entry then
                -- A fresh table per playlist entry, because the position within
                -- the playlist is not the position within the album and the two
                -- must not share one.
                table.insert(entries, {
                    album = entry.album,
                    track = entry.track,
                    trackIndex = entry.trackIndex,
                })
            end
        end

        if #entries > 0 then
            table.insert(Library.playlists, {
                name = playlistFromIndex.name or "Playlist",
                entries = entries,
            })
        end
    end
end


-- Read library.json and build the album list and the flattened track list.
-- Returns true when a usable library was loaded.
function Library.load()
    Library.albums = {}
    Library.playlists = {}
    Library.trackCount = 0
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

    for _, album in ipairs(Library.albums) do
        -- Guard against an album entry with no tracks, which would otherwise
        -- produce a selectable but empty row.
        album.tracks = album.tracks or {}
        Library.trackCount = Library.trackCount + #album.tracks
    end

    if Library.trackCount == 0 then
        Library.loadError = "The library contains no playable tracks."
        return false
    end

    resolvePlaylists(indexOrError.playlists)

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


-- Work out where one of an album's other artwork sizes lives.
--
-- Ingest writes artwork at three sizes: the 140 pixel image the index points at,
-- a 60 pixel thumbnail for the album list, and a 240 pixel one for the Sleeve
-- visualizer. Only the first has a path in the index. The other two are derived
-- by adding a suffix to it, because it is always the same transformation and
-- putting all three in the index would mean every library had to be rebuilt to
-- gain a size that was added later.
--
-- Returns nil for an album that has no artwork at all. The file may also simply
-- not exist, for a library ingested before that size was added, so callers have
-- to check rather than trusting the path they get back.
local function artworkPathWithSuffix(album, suffix)
    local artworkPath = album and album.art
    if not artworkPath then
        return nil
    end

    -- The parentheses matter: gsub returns the replacement count as a second
    -- value, and without them that count would be returned to the caller too.
    return (string.gsub(artworkPath, "%.pdi$", suffix .. ".pdi"))
end


-- The 60 pixel cover the album list draws beside each row.
function Library.thumbnailPathForAlbum(album)
    return artworkPathWithSuffix(album, "-thumb")
end


-- The 240 pixel cover the Sleeve visualizer cuts into strips.
function Library.fullscreenArtPathForAlbum(album)
    return artworkPathWithSuffix(album, "-full")
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
