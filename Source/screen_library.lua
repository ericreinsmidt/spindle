-- The library browser: a list of albums, and the track list inside one album.
--
-- The album is the primary object in Spindle, so this is where the app opens.
-- Artists are not a separate level of navigation, they are shown alongside
-- each album, because a three level artist and album and track hierarchy puts
-- every song three steps away and fills the top level with artists who have
-- one record.
--
-- The crank scrolls the list, and up and down do the same thing, because the
-- crank is an enhancement and never a requirement.
--
-- The album list shows three rows at a time rather than filling the screen with
-- them. A cover you cannot make out is not worth drawing, and three rows leaves
-- enough height for a 60 pixel cover and a title in the large font. Scrolling
-- past a few extra rows costs a second; squinting at a list costs every time.

import "library"
import "player"
import "typography"
import "artwork"
import "transition"

ScreenLibrary = {}

local graphics <const> = playdate.graphics

-- How much of a turn moves the selection by one row. Eight ticks per
-- revolution feels close to a scroll wheel.
local CRANK_TICKS_PER_REVOLUTION <const> = 8

local SCREEN_HEIGHT <const> = 240
local LIST_LEFT_EDGE <const> = 6
local LIST_WIDTH <const> = 388

-- The right hand end of the usable area, short of the scroll bar.
local CONTENT_RIGHT_EDGE <const> = 390

-- ---------------------------------------------------------------------------
-- Album list geometry
-- ---------------------------------------------------------------------------

local ALBUM_LIST_TOP_EDGE <const> = 30

-- Three rows in the 210 pixels below the header.
local ALBUM_ROW_HEIGHT <const> = 70

local ALBUM_COVER_SIZE <const> = 60
local ALBUM_COVER_LEFT <const> = 10
local ALBUM_TEXT_LEFT <const> = ALBUM_COVER_LEFT + ALBUM_COVER_SIZE + 12

-- The gap between the album title and the line of detail underneath it.
local ALBUM_TITLE_TO_DETAIL_GAP <const> = 3

-- ---------------------------------------------------------------------------
-- Track list geometry
-- ---------------------------------------------------------------------------

local TRACK_LIST_TOP_EDGE <const> = 52
local TRACK_ROW_HEIGHT <const> = 30

local TRACK_NUMBER_LEFT <const> = 10
local TRACK_TITLE_LEFT <const> = 46

-- How much room the running time needs on the right, so titles are trimmed
-- before they reach it rather than drawing over the top of it.
local TRACK_DURATION_COLUMN_WIDTH <const> = 56

-- Which view is showing: the album list, or the tracks inside one album.
local VIEW_ALBUMS <const> = "albums"
local VIEW_TRACKS <const> = "tracks"

local currentView = VIEW_ALBUMS

local selectedAlbumIndex = 1
local albumScrollOffset = 0

-- Where the list is actually drawn, in pixels, as opposed to the row it is on
-- its way to. The offsets above are the target and stay whole rows; these chase
-- them and are the thing you see.
local albumScrollPixels = 0
local trackScrollPixels = 0

-- Where the selection bar has slid to, in screen pixels. Separate from the
-- scroll, because moving the selection within the visible rows moves the bar
-- without moving the list at all.
local albumHighlightPixels = 0
local trackHighlightPixels = 0

-- How quickly a list catches up with where it is going.
--
-- This is a time constant, not a speed: each step closes the same fraction of
-- whatever distance is left, so a short hop is quick and a long one still takes
-- a moment. 90 milliseconds covers about two thirds of the distance, so a row
-- lands in roughly a fifth of a second, which is fast enough to feel like a
-- response rather than an animation.
local SCROLL_EASE_MILLISECONDS <const> = 90

-- Below this, stop and sit on the target. Without it the list creeps toward the
-- row forever by ever smaller fractions of a pixel, which costs a redraw every
-- frame for motion nobody can see.
local SCROLL_SETTLED_PIXELS <const> = 0.4

local lastEasedAt = nil
local elapsedThisFrame = 0


-- Read the clock once for the frame.
--
-- Kept separate from the easing itself so that the time advances whether or not
-- anything is moving. Reading it inside the easing would leave it stale while a
-- list sat still, and the first move after a pause would be handed several
-- seconds of elapsed time.
local function beginEasingFrame()
    local now = playdate.getCurrentTimeMilliseconds()
    elapsedThisFrame = now - (lastEasedAt or now)
    lastEasedAt = now

    -- A long gap is a screen change or a stall rather than a frame. Treating it
    -- as elapsed time would snap the list across in one jump.
    if elapsedThisFrame > 250 then
        elapsedThisFrame = 0
    end
end


-- Move a value toward a target by a fraction of the distance left.
--
-- Time based rather than per frame, for the reason the marquee had to be: this
-- screen ran at 19 frames a second until recently, and a fixed step per frame is
-- only a fixed speed if the frames are evenly spaced.
local function easeTowards(current, target)
    if math.abs(target - current) < SCROLL_SETTLED_PIXELS then
        return target
    end

    local closed = 1 - math.exp(-elapsedThisFrame / SCROLL_EASE_MILLISECONDS)
    return current + (target - current) * closed
end

-- What is open in the track view, as a table holding the rows to draw and the
-- playback list they produce. An album and a playlist both reduce to that, which
-- is what lets one track view serve both.
local openedCollection = nil
local selectedTrackIndex = 1
local trackScrollOffset = 0

-- Cover thumbnails, loaded the first time a row is drawn and then kept. A 60 by
-- 60 one bit image is well under a kilobyte, so holding one per album costs
-- nothing even for a library far larger than anything that fits on the device,
-- and loading them lazily means startup does not stall reading pictures for
-- albums nobody has scrolled to yet.
--
-- Keyed by the album table itself rather than by its position in the list, so a
-- playlist borrowing the cover of the album it opens with shares the one image
-- rather than loading a second copy.
--
-- An album with no usable thumbnail is stored as false rather than left absent,
-- so a missing file is not looked for again on every single frame.
local thumbnailsByAlbum = {}


-- Keep the selected row on screen by nudging the scroll offset only as far as
-- it needs to go, which keeps the list from jumping around while browsing.
local function adjustScrollToShowSelection(selectedIndex, scrollOffset, rowHeight, itemCount, listTop)
    local visibleRowCount = math.floor((SCREEN_HEIGHT - listTop) / rowHeight)

    if selectedIndex - 1 < scrollOffset then
        scrollOffset = selectedIndex - 1
    elseif selectedIndex > scrollOffset + visibleRowCount then
        scrollOffset = selectedIndex - visibleRowCount
    end

    local maximumOffset = math.max(0, itemCount - visibleRowCount)
    if scrollOffset > maximumOffset then
        scrollOffset = maximumOffset
    end
    if scrollOffset < 0 then
        scrollOffset = 0
    end

    return scrollOffset, visibleRowCount
end


-- Read one step of movement from the buttons and the crank combined. Returns
-- the number of rows to move, which is zero when nothing happened.
local function readMovementInput()
    local movement = 0

    if playdate.buttonJustPressed(playdate.kButtonUp) then
        movement = movement - 1
    end
    if playdate.buttonJustPressed(playdate.kButtonDown) then
        movement = movement + 1
    end

    movement = movement + playdate.getCrankTicks(CRANK_TICKS_PER_REVOLUTION)

    return movement
end


-- Draw a slim scrollbar down the right edge, so it is obvious when a list runs
-- past the bottom of the screen.
local function drawScrollIndicator(itemCount, visibleRowCount, scrollOffset, listTop)
    if itemCount <= visibleRowCount then
        return
    end

    local trackTop = listTop
    local trackHeight = SCREEN_HEIGHT - listTop - 4
    local thumbHeight = math.max(12, trackHeight * visibleRowCount / itemCount)
    local scrollableRows = itemCount - visibleRowCount
    local thumbTop = trackTop + (trackHeight - thumbHeight) * (scrollOffset / scrollableRows)

    graphics.fillRect(396, thumbTop, 3, thumbHeight)
end


-- ---------------------------------------------------------------------------
-- The album list
-- ---------------------------------------------------------------------------

-- Everything the top level shows, playlists first and then albums.
--
-- Playlists come first because there are few of them and they are the thing you
-- made deliberately. They sit in the same list rather than behind a separate
-- screen, because a playlist is another way to start a run of music and putting
-- it one level away would make it feel like a different kind of object than it
-- is.
--
-- Rebuilt on each draw rather than cached. It is a handful of table inserts over
-- a list that only changes when the library reloads, and a cache would be a
-- second thing to keep in step for no measurable gain.
-- Built once and kept.
--
-- This used to be rebuilt on every call, and it is called twice a frame, once
-- from update and once from draw. Each rebuild summed every track's duration for
-- every album, formatted a detail line for each, and called
-- playbackListForAlbum for all of them, which allocates a table for every track
-- in the library. On a 155 track library that is around 310 tables and a pile of
-- string formatting a frame, for a list that cannot change while the app is
-- running.
--
-- It cost about 20 milliseconds a frame. The album list ran at 19 frames a
-- second against now playing's 30, measured on device, and none of the
-- difference was drawing: removing the covers entirely changed nothing.
--
-- Nothing invalidates this because nothing can. The library is read once at
-- startup and there is no way to add a record without leaving the app.
local cachedCollections = nil


local function browsableCollections()
    if cachedCollections then
        return cachedCollections
    end

    local collections = {}

    for _, playlist in ipairs(Library.playlists) do
        local totalSeconds = 0
        for _, entry in ipairs(playlist.entries) do
            totalSeconds = totalSeconds + (entry.track.duration or 0)
        end

        table.insert(collections, {
            isPlaylist = true,
            title = playlist.name,
            detail = string.format("playlist  %d tracks  %s",
                #playlist.entries, Library.formatDuration(totalSeconds)),
            entries = playlist.entries,
            -- No cover album, so the row draws the adapter mark. A playlist
            -- borrowing the cover of whatever it opened with was tried and makes
            -- it look like that album, which is exactly what it is not.
            coverAlbum = nil,
        })
    end

    for _, album in ipairs(Library.albums) do
        local detailParts = { album.artist or "Unknown artist" }
        if album.year then
            table.insert(detailParts, tostring(album.year))
        end
        table.insert(detailParts, string.format("%d tracks", #album.tracks))
        table.insert(detailParts, Library.formatDuration(Library.albumDuration(album)))

        table.insert(collections, {
            isPlaylist = false,
            title = album.title,
            detail = table.concat(detailParts, "  "),

            -- No entries here. Building the playback list for every album means
            -- allocating a table per track across the whole library, and all but
            -- one of those is for a record nobody opened. entriesFor builds the
            -- one that gets opened, the first time it is asked for.
            coverAlbum = album,
        })
    end

    cachedCollections = collections
    return collections
end


-- The playback list for a collection, built on first use and then kept.
--
-- A playlist already is a list of entries, so it has them from the start. An
-- album has to be turned into one, and that is worth doing when somebody opens
-- the record rather than for all twelve every time the list is drawn.
local function entriesFor(collection)
    if not collection.entries then
        collection.entries = Library.playbackListForAlbum(collection.coverAlbum)
    end
    return collection.entries
end

-- Load an album's cover thumbnail, or return nil when there is nothing to show.
local function thumbnailForAlbum(album)
    if not album then
        return nil
    end

    local alreadyLoaded = thumbnailsByAlbum[album]
    if alreadyLoaded ~= nil then
        -- false means it has already been looked for and is not there.
        return alreadyLoaded or nil
    end

    local thumbnail = nil

    local thumbnailPath = Library.thumbnailPathForAlbum(album)
    if thumbnailPath and playdate.file.exists(thumbnailPath) then
        thumbnail = graphics.image.new(thumbnailPath)
    elseif album.art and playdate.file.exists(album.art) then
        -- No thumbnail file, which means the library was ingested before they
        -- existed. Shrinking the full artwork is a poor substitute, because the
        -- dither pattern was generated for 140 pixels and resampling it turns
        -- the picture into noise, but a rough cover reads better than an empty
        -- square and this only happens once per album.
        local fullSizeArtwork = graphics.image.new(album.art)
        if fullSizeArtwork then
            local fullSizeWidth = fullSizeArtwork:getSize()
            if fullSizeWidth and fullSizeWidth > 0 then
                thumbnail = fullSizeArtwork:scaledImage(ALBUM_COVER_SIZE / fullSizeWidth)
            end
        end
    end

    thumbnailsByAlbum[album] = thumbnail or false
    return thumbnail
end


local function updateAlbumList()
    local collections = browsableCollections()
    if #collections == 0 then
        return nil
    end

    local movement = readMovementInput()
    if movement ~= 0 then
        selectedAlbumIndex = selectedAlbumIndex + movement
        if selectedAlbumIndex < 1 then
            selectedAlbumIndex = 1
        end
        if selectedAlbumIndex > #collections then
            selectedAlbumIndex = #collections
        end
    end

    if playdate.buttonJustPressed(playdate.kButtonA) then
        openedCollection = collections[selectedAlbumIndex]

        -- Built here, at the one moment somebody has asked for this record, so
        -- the track list and everything after it can read entries directly.
        entriesFor(openedCollection)

        selectedTrackIndex = 1
        trackScrollOffset = 0

        -- Snapped rather than eased. Opening a record is a change of place, not
        -- a movement within one, and a track list that slid into position from
        -- wherever the last one happened to be would read as the wrong thing
        -- arriving rather than the right thing appearing.
        trackScrollPixels = 0
        trackHighlightPixels = TRACK_LIST_TOP_EDGE

        -- Opening a record goes further in, so it pushes left, the same as
        -- moving from the library to now playing. These two views are not
        -- separate screens, but nothing about a transition cares: it
        -- photographs the frame buffer and slides whatever draws next against
        -- it, so saying when it happens is the whole of the work.
        Transition.begin(1, 0)

        currentView = VIEW_TRACKS
    end

    -- B from the top level jumps to whatever is playing, which is the only
    -- other place there is to go.
    if playdate.buttonJustPressed(playdate.kButtonB) and Player.hasTrackLoaded() then
        return "nowplaying"
    end

    return nil
end


local function drawAlbumList()
    local collections = browsableCollections()
    local visibleRowCount
    albumScrollOffset, visibleRowCount =
        adjustScrollToShowSelection(selectedAlbumIndex, albumScrollOffset, ALBUM_ROW_HEIGHT,
            #collections, ALBUM_LIST_TOP_EDGE)

    -- The heading says what is in the list rather than always saying Albums,
    -- because once playlists are in it that would be wrong.
    graphics.setFont(Typography.body)
    graphics.drawText(#Library.playlists > 0 and "Library" or "Albums", LIST_LEFT_EDGE, 4)

    local countText = string.format("%d", #collections)
    graphics.drawText(countText,
        CONTENT_RIGHT_EDGE - Typography.body:getTextWidth(countText), 4)

    -- The text column runs from the cover across to the scroll bar, and both
    -- lines are trimmed to it so nothing draws over the edge of the screen.
    local textWidth = CONTENT_RIGHT_EDGE - ALBUM_TEXT_LEFT

    local titleHeight = Typography.large:getHeight()
    local detailHeight = Typography.body:getHeight()
    local textBlockHeight = titleHeight + ALBUM_TITLE_TO_DETAIL_GAP + detailHeight

    beginEasingFrame()

    albumScrollPixels = easeTowards(albumScrollPixels,
        albumScrollOffset * ALBUM_ROW_HEIGHT)

    -- The row at the top of the screen and how far it has been pushed up out of
    -- view. While the list is moving these are a row and a part of one, which is
    -- the whole point: a list that only ever showed whole rows could not slide.
    local firstVisibleIndex = math.floor(albumScrollPixels / ALBUM_ROW_HEIGHT)
    local pixelsScrolledIntoFirstRow =
        albumScrollPixels - firstVisibleIndex * ALBUM_ROW_HEIGHT

    -- Where the highlight has slid to. The bar chases the selected row rather
    -- than being drawn on it, which is what lets it move between rows while the
    -- list itself is standing still.
    -- Measured against where the list is going rather than where it has got
    -- to, which is what keeps the two motions from ever running at once.
    --
    -- Move the selection within the visible rows and the scroll target does not
    -- change, so this does: the bar travels and the list stands still. Move it
    -- past the end and both the row and the scroll target shift by exactly one
    -- row, so this does not change at all: the bar stays put and the list slides
    -- underneath it.
    --
    -- Aiming at the eased scroll instead made the bar chase its own row down the
    -- screen during a scroll, so it trailed the row it belongs to.
    local selectedRowTop = ALBUM_LIST_TOP_EDGE
        + (selectedAlbumIndex - 1 - albumScrollOffset) * ALBUM_ROW_HEIGHT
    albumHighlightPixels = easeTowards(albumHighlightPixels, selectedRowTop)

    -- Draw every visible row once. Called twice: once for the list as it reads
    -- off the bar, and once more clipped to the bar with everything in white.
    --
    -- Two passes rather than colouring each row by whether it is selected,
    -- because while the bar is moving it lies across two rows at once and
    -- neither of them is wholly on it. Anything keyed to the selection can only
    -- pick one, and the half of the other row sitting on black would vanish.
    --
    -- The marquee is safe being called twice a frame: it measures its own
    -- movement against the clock, so the second call is handed no elapsed time
    -- and moves nothing.
    local function drawAlbumRows(onTheBar)
        for visibleRow = 1, visibleRowCount + 1 do
            local collectionIndex = firstVisibleIndex + visibleRow
            local collection = collections[collectionIndex]
            if not collection then
                break
            end

            local bandTop = ALBUM_LIST_TOP_EDGE + (visibleRow - 1) * ALBUM_ROW_HEIGHT
                - pixelsScrolledIntoFirstRow

            -- Every cover is flipped, because the display flips the whole screen
            -- again afterwards and a cover should look like a photograph rather
            -- than a negative.
            --
            -- Flipping only the highlighted row was tried first, on the
            -- reasoning that its bar comes out light and is therefore the only
            -- place a cover has light ground to sit on. That leaves every other
            -- one a negative, which is the thing worth avoiding in the first
            -- place.
            local coverTop = bandTop + (ALBUM_ROW_HEIGHT - ALBUM_COVER_SIZE) // 2
            local thumbnail = thumbnailForAlbum(collection.coverAlbum)
            if thumbnail then
                Artwork.draw(thumbnail, ALBUM_COVER_LEFT, coverTop)
            else
                Artwork.drawCoverMark(ALBUM_COVER_LEFT, coverTop, ALBUM_COVER_SIZE)
            end

            -- Put the text's own draw mode back, whichever pass this is. Artwork
            -- leaves the mode where it found it, so this has to be set after the
            -- cover rather than before it.
            graphics.setImageDrawMode(onTheBar
                and graphics.kDrawModeFillWhite
                or graphics.kDrawModeCopy)

            local textTop = bandTop + (ALBUM_ROW_HEIGHT - textBlockHeight) // 2
            local detailTop = textTop + titleHeight + ALBUM_TITLE_TO_DETAIL_GAP

            -- Only the selected row slides. Every long title on screen moving at
            -- once is unreadable, and it would tie the cost of the list to how
            -- many rows happen not to fit.
            if collectionIndex == selectedAlbumIndex then
                Marquee.draw("albumRowTitle", Typography.large, collection.title,
                    ALBUM_TEXT_LEFT, textTop, textWidth, titleHeight)
                Marquee.draw("albumRowDetail", Typography.body, collection.detail,
                    ALBUM_TEXT_LEFT, detailTop, textWidth,
                    ALBUM_ROW_HEIGHT - titleHeight)
            else
                graphics.setFont(Typography.large)
                graphics.drawText(
                    Typography.truncateToWidth(
                        Typography.large, collection.title, textWidth),
                    ALBUM_TEXT_LEFT, textTop)

                graphics.setFont(Typography.body)
                graphics.drawText(
                    Typography.truncateToWidth(
                        Typography.body, collection.detail, textWidth),
                    ALBUM_TEXT_LEFT, detailTop)
            end

            graphics.setImageDrawMode(graphics.kDrawModeCopy)
        end
    end

    -- Clipped to the area below the heading, so the row sliding in at the bottom
    -- stops at the edge of the screen and the one sliding out at the top does
    -- not draw over the heading.
    graphics.setClipRect(0, ALBUM_LIST_TOP_EDGE, 400, SCREEN_HEIGHT - ALBUM_LIST_TOP_EDGE)
    drawAlbumRows(false)

    -- The bar, and everything on it again in white. Clipped to whatever part of
    -- the bar is on screen, which while it moves is a band lying across two
    -- rows.
    local barTop = math.max(ALBUM_LIST_TOP_EDGE, math.floor(albumHighlightPixels))
    local barBottom = math.min(SCREEN_HEIGHT,
        math.floor(albumHighlightPixels) + ALBUM_ROW_HEIGHT)

    if barBottom > barTop then
        graphics.setClipRect(0, barTop, 400, barBottom - barTop)
        graphics.fillRect(LIST_LEFT_EDGE - 2, barTop, LIST_WIDTH + 4, barBottom - barTop)
        drawAlbumRows(true)
    end

    graphics.clearClipRect()

    -- The thumb tracks where the list has slid to rather than the row it is
    -- heading for, so it moves with the list instead of jumping ahead of it.
    drawScrollIndicator(#collections, visibleRowCount,
        albumScrollPixels / ALBUM_ROW_HEIGHT, ALBUM_LIST_TOP_EDGE)
end


-- ---------------------------------------------------------------------------
-- The track list inside an album or a playlist
-- ---------------------------------------------------------------------------
--
-- One view serves both, because by the time anything gets here the difference
-- has already been resolved away: an album and a playlist are each a list of
-- entries holding an album, a track and its number on that album. The only
-- things that differ are the two lines of heading and whether the numbers down
-- the left count within the record or within the playlist.

local function updateTrackList()
    local trackCount = #openedCollection.entries

    local movement = readMovementInput()
    if movement ~= 0 then
        selectedTrackIndex = selectedTrackIndex + movement
        if selectedTrackIndex < 1 then
            selectedTrackIndex = 1
        end
        if selectedTrackIndex > trackCount then
            selectedTrackIndex = trackCount
        end
    end

    if playdate.buttonJustPressed(playdate.kButtonB) then
        -- Coming back out, so it pops right.
        Transition.begin(-1, 0)
        currentView = VIEW_ALBUMS
        return nil
    end

    if playdate.buttonJustPressed(playdate.kButtonA) then
        -- Play the whole thing from the chosen track rather than just the one
        -- song, so a record plays through as it should and a playlist runs on.
        Player.playList(openedCollection.entries, selectedTrackIndex)
        return "nowplaying"
    end

    return nil
end


local function drawTrackList()
    local trackCount = #openedCollection.entries
    local visibleRowCount
    trackScrollOffset, visibleRowCount =
        adjustScrollToShowSelection(selectedTrackIndex, trackScrollOffset, TRACK_ROW_HEIGHT,
            trackCount, TRACK_LIST_TOP_EDGE)

    local headerWidth = CONTENT_RIGHT_EDGE - LIST_LEFT_EDGE

    -- The header slides whenever it needs to, rather than only when selected.
    -- There is one of it, it is not competing with anything, and a record with a
    -- long name is exactly the case where you want to see the whole name.
    Marquee.draw("trackHeaderTitle", Typography.large, openedCollection.title,
        LIST_LEFT_EDGE, 3, headerWidth, 25)

    -- An album names its artist here. A playlist has no single artist, so it
    -- says what it is and how long it runs instead, which is the thing you
    -- actually want to know before starting one.
    local subheading = openedCollection.isPlaylist
        and openedCollection.detail
        or (openedCollection.coverAlbum and openedCollection.coverAlbum.artist or "")

    Marquee.draw("trackHeaderSubheading", Typography.body, subheading,
        LIST_LEFT_EDGE, 28, headerWidth, Typography.body:getHeight())

    local titleWidth = CONTENT_RIGHT_EDGE - TRACK_DURATION_COLUMN_WIDTH - TRACK_TITLE_LEFT

    beginEasingFrame()

    trackScrollPixels = easeTowards(trackScrollPixels,
        trackScrollOffset * TRACK_ROW_HEIGHT)

    local firstVisibleIndex = math.floor(trackScrollPixels / TRACK_ROW_HEIGHT)
    local pixelsScrolledIntoFirstRow =
        trackScrollPixels - firstVisibleIndex * TRACK_ROW_HEIGHT

    -- Clipped below the two heading lines, so a row sliding out of the top does
    -- not draw across them.
    graphics.setClipRect(0, TRACK_LIST_TOP_EDGE, 400, SCREEN_HEIGHT - TRACK_LIST_TOP_EDGE)

    local selectedRowTop = TRACK_LIST_TOP_EDGE
        + (selectedTrackIndex - 1 - trackScrollOffset) * TRACK_ROW_HEIGHT
    trackHighlightPixels = easeTowards(trackHighlightPixels, selectedRowTop)

    -- Drawn twice, the same as the album list: once as the list reads off the
    -- bar, once more clipped to the bar with everything in white.
    local function drawTrackRows(onTheBar)
        graphics.setImageDrawMode(onTheBar
            and graphics.kDrawModeFillWhite
            or graphics.kDrawModeCopy)

        -- One row more than fits, for the partial one at each end while it moves.
        for visibleRow = 1, visibleRowCount + 1 do
            local trackIndex = firstVisibleIndex + visibleRow
            local entry = openedCollection.entries[trackIndex]
            if not entry then
                break
            end
            local track = entry.track

            local bandTop = TRACK_LIST_TOP_EDGE + (visibleRow - 1) * TRACK_ROW_HEIGHT
                - pixelsScrolledIntoFirstRow

            -- The row that has slid past the bottom edge is skipped rather than
            -- drawn and clipped away, since the check costs nothing and the
            -- drawing does not.
            if bandTop >= SCREEN_HEIGHT then
                break
            end

            Typography.drawCenteredInBand(Typography.body,
                string.format("%2d.", trackIndex),
                TRACK_NUMBER_LEFT, bandTop, TRACK_ROW_HEIGHT)

            -- On a playlist the title carries the artist as well, because a
            -- list drawn from several records is unreadable without it. On an
            -- album every line would say the same name, so it does not.
            local titleText = track.title
            if openedCollection.isPlaylist then
                titleText = titleText .. "   " .. (entry.album.artist or "")
            end

            -- Only the selected row slides, for the same reason the album list
            -- only slides the selected one: every long title moving at once is
            -- unreadable, and the selected row is the one being read.
            if trackIndex == selectedTrackIndex then
                local lineHeight = Typography.body:getHeight()
                Marquee.draw("trackRowTitle", Typography.body, titleText,
                    TRACK_TITLE_LEFT,
                    bandTop + (TRACK_ROW_HEIGHT - lineHeight) // 2,
                    titleWidth, lineHeight)
            else
                Typography.drawCenteredInBand(Typography.body,
                    Typography.truncateToWidth(Typography.body, titleText, titleWidth),
                    TRACK_TITLE_LEFT, bandTop, TRACK_ROW_HEIGHT)
            end

            local durationText = Library.formatDuration(track.duration)
            Typography.drawCenteredInBand(Typography.body, durationText,
                CONTENT_RIGHT_EDGE - Typography.body:getTextWidth(durationText),
                bandTop, TRACK_ROW_HEIGHT)
        end

        graphics.setImageDrawMode(graphics.kDrawModeCopy)
    end

    drawTrackRows(false)

    local barTop = math.max(TRACK_LIST_TOP_EDGE, math.floor(trackHighlightPixels))
    local barBottom = math.min(SCREEN_HEIGHT,
        math.floor(trackHighlightPixels) + TRACK_ROW_HEIGHT)

    if barBottom > barTop then
        graphics.setClipRect(0, barTop, 400, barBottom - barTop)
        graphics.fillRect(LIST_LEFT_EDGE - 2, barTop, LIST_WIDTH + 4, barBottom - barTop)
        drawTrackRows(true)
    end

    graphics.clearClipRect()

    drawScrollIndicator(trackCount, visibleRowCount,
        trackScrollPixels / TRACK_ROW_HEIGHT, TRACK_LIST_TOP_EDGE)
end


-- ---------------------------------------------------------------------------
-- Screen interface
-- ---------------------------------------------------------------------------

-- Called when the library screen becomes visible again, so returning from now
-- playing lands where you left off rather than resetting to the top.
function ScreenLibrary.enter()
    -- So a title that was mid slide when this screen was last open does not
    -- reappear part way along, which reads as the list having been running
    -- while nobody was looking at it.
    Marquee.reset()

    -- Arrive at rest. Easing from wherever the list was left would animate on
    -- the way in, and the movement is meant to show a list responding to you
    -- rather than a screen assembling itself.
    albumScrollPixels = albumScrollOffset * ALBUM_ROW_HEIGHT
    trackScrollPixels = trackScrollOffset * TRACK_ROW_HEIGHT
    albumHighlightPixels = ALBUM_LIST_TOP_EDGE
        + (selectedAlbumIndex - 1 - albumScrollOffset) * ALBUM_ROW_HEIGHT
    trackHighlightPixels = TRACK_LIST_TOP_EDGE
        + (selectedTrackIndex - 1 - trackScrollOffset) * TRACK_ROW_HEIGHT
    lastEasedAt = nil
end


function ScreenLibrary.update()
    if currentView == VIEW_TRACKS and openedCollection then
        return updateTrackList()
    end
    return updateAlbumList()
end


function ScreenLibrary.draw()
    if currentView == VIEW_TRACKS and openedCollection then
        drawTrackList()
    else
        drawAlbumList()
    end
end
