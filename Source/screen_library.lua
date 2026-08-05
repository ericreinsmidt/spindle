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

import "library"
import "player"

ScreenLibrary = {}

local graphics <const> = playdate.graphics

-- How much of a turn moves the selection by one row. Eight ticks per
-- revolution feels close to a scroll wheel.
local CRANK_TICKS_PER_REVOLUTION <const> = 8

local ALBUM_ROW_HEIGHT <const> = 36
local TRACK_ROW_HEIGHT <const> = 26
local LIST_TOP_EDGE <const> = 30

-- The track list sits lower than the album list, because the album title and
-- artist occupy a header above it.
local TRACK_LIST_TOP_EDGE <const> = 46
local LIST_LEFT_EDGE <const> = 6
local LIST_WIDTH <const> = 388
local SCREEN_HEIGHT <const> = 240

-- Which view is showing: the album list, or the tracks inside one album.
local VIEW_ALBUMS <const> = "albums"
local VIEW_TRACKS <const> = "tracks"

local currentView = VIEW_ALBUMS

local selectedAlbumIndex = 1
local albumScrollOffset = 0

local openedAlbum = nil
local selectedTrackIndex = 1
local trackScrollOffset = 0


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


-- Draw one row, highlighting it by filling the background black and drawing
-- the text in white. On a 1-bit screen an inverted row is the clearest way to
-- show selection.
local function drawRow(rowTop, rowHeight, isSelected, drawContents)
    if isSelected then
        graphics.fillRect(LIST_LEFT_EDGE - 2, rowTop - 2, LIST_WIDTH + 4, rowHeight)
        graphics.setImageDrawMode(graphics.kDrawModeFillWhite)
    else
        graphics.setImageDrawMode(graphics.kDrawModeCopy)
    end

    drawContents()

    graphics.setImageDrawMode(graphics.kDrawModeCopy)
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

local function updateAlbumList()
    local albumCount = #Library.albums
    if albumCount == 0 then
        return nil
    end

    local movement = readMovementInput()
    if movement ~= 0 then
        selectedAlbumIndex = selectedAlbumIndex + movement
        if selectedAlbumIndex < 1 then
            selectedAlbumIndex = 1
        end
        if selectedAlbumIndex > albumCount then
            selectedAlbumIndex = albumCount
        end
    end

    if playdate.buttonJustPressed(playdate.kButtonA) then
        openedAlbum = Library.albums[selectedAlbumIndex]
        selectedTrackIndex = 1
        trackScrollOffset = 0
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
    local albumCount = #Library.albums
    local visibleRowCount
    albumScrollOffset, visibleRowCount =
        adjustScrollToShowSelection(selectedAlbumIndex, albumScrollOffset, ALBUM_ROW_HEIGHT,
            albumCount, LIST_TOP_EDGE)

    graphics.drawText("*Albums*", LIST_LEFT_EDGE, 6)
    graphics.drawText(string.format("%d", albumCount), 360, 6)

    for visibleRow = 1, visibleRowCount do
        local albumIndex = albumScrollOffset + visibleRow
        local album = Library.albums[albumIndex]
        if not album then
            break
        end

        local rowTop = LIST_TOP_EDGE + (visibleRow - 1) * ALBUM_ROW_HEIGHT

        drawRow(rowTop, ALBUM_ROW_HEIGHT, albumIndex == selectedAlbumIndex, function()
            graphics.drawText(album.title, LIST_LEFT_EDGE + 2, rowTop)

            local detailParts = { album.artist or "Unknown artist" }
            if album.year then
                table.insert(detailParts, tostring(album.year))
            end
            table.insert(detailParts, string.format("%d tracks", #album.tracks))
            table.insert(detailParts, Library.formatDuration(Library.albumDuration(album)))

            graphics.drawText(table.concat(detailParts, "  ") , LIST_LEFT_EDGE + 2, rowTop + 16)
        end)
    end

    drawScrollIndicator(albumCount, visibleRowCount, albumScrollOffset, LIST_TOP_EDGE)
end


-- ---------------------------------------------------------------------------
-- The track list inside one album
-- ---------------------------------------------------------------------------

local function updateTrackList()
    local trackCount = #openedAlbum.tracks

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
        currentView = VIEW_ALBUMS
        return nil
    end

    if playdate.buttonJustPressed(playdate.kButtonA) then
        -- Play the whole album starting from the chosen track, rather than
        -- just the one song, so a record plays through as it should.
        local playbackList = Library.playbackListForAlbum(openedAlbum)
        Player.playList(playbackList, selectedTrackIndex)
        return "nowplaying"
    end

    return nil
end


local function drawTrackList()
    local trackCount = #openedAlbum.tracks
    local visibleRowCount
    trackScrollOffset, visibleRowCount =
        adjustScrollToShowSelection(selectedTrackIndex, trackScrollOffset, TRACK_ROW_HEIGHT,
            trackCount, TRACK_LIST_TOP_EDGE)

    graphics.drawText("*" .. openedAlbum.title .. "*", LIST_LEFT_EDGE, 4)
    graphics.drawText(openedAlbum.artist or "", LIST_LEFT_EDGE, 20)

    for visibleRow = 1, visibleRowCount do
        local trackIndex = trackScrollOffset + visibleRow
        local track = openedAlbum.tracks[trackIndex]
        if not track then
            break
        end

        local rowTop = TRACK_LIST_TOP_EDGE + (visibleRow - 1) * TRACK_ROW_HEIGHT
        if rowTop + TRACK_ROW_HEIGHT > SCREEN_HEIGHT then
            break
        end

        drawRow(rowTop, TRACK_ROW_HEIGHT, trackIndex == selectedTrackIndex, function()
            graphics.drawText(string.format("%2d.", trackIndex), LIST_LEFT_EDGE + 2, rowTop)
            graphics.drawText(track.title, LIST_LEFT_EDGE + 34, rowTop)
            graphics.drawText(Library.formatDuration(track.duration), 340, rowTop)
        end)
    end

    drawScrollIndicator(trackCount, visibleRowCount, trackScrollOffset, TRACK_LIST_TOP_EDGE)
end


-- ---------------------------------------------------------------------------
-- Screen interface
-- ---------------------------------------------------------------------------

-- Called when the library screen becomes visible again, so returning from now
-- playing lands where you left off rather than resetting to the top.
function ScreenLibrary.enter()
end


function ScreenLibrary.update()
    if currentView == VIEW_TRACKS and openedAlbum then
        return updateTrackList()
    end
    return updateAlbumList()
end


function ScreenLibrary.draw()
    if currentView == VIEW_TRACKS and openedAlbum then
        drawTrackList()
    else
        drawAlbumList()
    end
end
