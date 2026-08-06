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

local openedAlbum = nil
local selectedTrackIndex = 1
local trackScrollOffset = 0

-- Cover thumbnails, loaded the first time a row is drawn and then kept. A 60 by
-- 60 one bit image is well under a kilobyte, so holding one per album costs
-- nothing even for a library far larger than anything that fits on the device,
-- and loading them lazily means startup does not stall reading pictures for
-- albums nobody has scrolled to yet.
--
-- An album with no usable thumbnail is stored as false rather than left absent,
-- so a missing file is not looked for again on every single frame.
local thumbnailsByAlbumIndex = {}


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
--
-- bandTop is the top of the highlight itself rather than an offset into it, and
-- the contents function is handed the band it has to sit inside. Everything
-- inside then centres itself against measured font heights. The previous
-- version drew text at a fixed offset from the top and let the leftover space
-- collect underneath, which made the highlight look like it sat lower than the
-- row it belonged to.
--
-- The selected state is passed through as well, because artwork has to opt out
-- of the highlight. It works by forcing everything drawn to white, and doing
-- that to a picture would flatten it into a solid white square.
local function drawRow(bandTop, bandHeight, isSelected, drawContents)
    if isSelected then
        graphics.fillRect(LIST_LEFT_EDGE - 2, bandTop, LIST_WIDTH + 4, bandHeight)
        graphics.setImageDrawMode(graphics.kDrawModeFillWhite)
    else
        graphics.setImageDrawMode(graphics.kDrawModeCopy)
    end

    drawContents(isSelected)

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

-- Load an album's cover thumbnail, or return nil when there is nothing to show.
local function thumbnailForAlbum(album, albumIndex)
    local alreadyLoaded = thumbnailsByAlbumIndex[albumIndex]
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

    thumbnailsByAlbumIndex[albumIndex] = thumbnail or false
    return thumbnail
end


-- Stand in for a missing cover, drawn as a square with an outline and a centre
-- hole that echoes the 45 adapter the app is named for.
--
-- It flips exactly when a real cover would, so that a record without artwork
-- sits the same way round as one with it. Getting this wrong would be more
-- obvious than leaving it plain, because the two would disagree down a single
-- list.
local function drawCoverPlaceholder(left, top, shouldFlip)
    local paperColor = shouldFlip and graphics.kColorBlack or graphics.kColorWhite
    local inkColor = shouldFlip and graphics.kColorWhite or graphics.kColorBlack

    graphics.setColor(paperColor)
    graphics.fillRect(left, top, ALBUM_COVER_SIZE, ALBUM_COVER_SIZE)

    graphics.setColor(inkColor)
    graphics.drawRect(left, top, ALBUM_COVER_SIZE, ALBUM_COVER_SIZE)

    local centreX = left + ALBUM_COVER_SIZE / 2
    local centreY = top + ALBUM_COVER_SIZE / 2
    graphics.drawCircleAtPoint(centreX, centreY, 9)

    -- Three spokes at 120 degrees apart, matching the three arm adapter shape.
    for spokeNumber = 0, 2 do
        local spokeAngle = math.rad(90 + spokeNumber * 120)
        graphics.drawLine(
            centreX + math.cos(spokeAngle) * 9,
            centreY + math.sin(spokeAngle) * 9,
            centreX + math.cos(spokeAngle) * 24,
            centreY + math.sin(spokeAngle) * 24)
    end

    -- Leave black selected, since everything drawn after this expects it.
    graphics.setColor(graphics.kColorBlack)
end


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
            albumCount, ALBUM_LIST_TOP_EDGE)

    graphics.setFont(Typography.body)
    graphics.drawText("Albums", LIST_LEFT_EDGE, 4)

    local countText = string.format("%d", albumCount)
    graphics.drawText(countText,
        CONTENT_RIGHT_EDGE - Typography.body:getTextWidth(countText), 4)

    -- The text column runs from the cover across to the scroll bar, and both
    -- lines are trimmed to it so nothing draws over the edge of the screen.
    local textWidth = CONTENT_RIGHT_EDGE - ALBUM_TEXT_LEFT

    local titleHeight = Typography.large:getHeight()
    local detailHeight = Typography.body:getHeight()
    local textBlockHeight = titleHeight + ALBUM_TITLE_TO_DETAIL_GAP + detailHeight

    for visibleRow = 1, visibleRowCount do
        local albumIndex = albumScrollOffset + visibleRow
        local album = Library.albums[albumIndex]
        if not album then
            break
        end

        local bandTop = ALBUM_LIST_TOP_EDGE + (visibleRow - 1) * ALBUM_ROW_HEIGHT

        drawRow(bandTop, ALBUM_ROW_HEIGHT, albumIndex == selectedAlbumIndex, function(isSelected)
            -- A cover should look like a photograph, so on an inverted display
            -- every one of them is flipped back rather than left as a negative.
            --
            -- On a normal display nothing is flipped and nothing needs to be,
            -- including the highlighted row, where a light cover sitting in a
            -- dark bar reads perfectly well.
            --
            -- The narrower rule of flipping only the highlighted row was tried
            -- first, on the reasoning that the highlight bar comes out light and
            -- is therefore the only place a cover has light ground to sit on.
            -- That leaves the rest as negatives, which is the thing worth
            -- avoiding in the first place.
            local shouldFlipCover = Artwork.displayIsInverted

            graphics.setImageDrawMode(shouldFlipCover
                and graphics.kDrawModeInverted
                or graphics.kDrawModeCopy)

            local coverTop = bandTop + (ALBUM_ROW_HEIGHT - ALBUM_COVER_SIZE) // 2
            local thumbnail = thumbnailForAlbum(album, albumIndex)
            if thumbnail then
                thumbnail:draw(ALBUM_COVER_LEFT, coverTop)
            else
                drawCoverPlaceholder(ALBUM_COVER_LEFT, coverTop, shouldFlipCover)
            end

            -- Put the text's own draw mode back, for both kinds of row rather
            -- than only the highlighted one.
            --
            -- This used to restore it only when the row was selected, which
            -- worked purely by luck: back then the cover was drawn in plain copy
            -- mode, which is what the text on an unselected row wanted anyway.
            -- The moment covers started being flipped, every unselected row was
            -- drawing its text in inverted mode as well, and the text
            -- disappeared.
            graphics.setImageDrawMode(isSelected
                and graphics.kDrawModeFillWhite
                or graphics.kDrawModeCopy)

            local textTop = bandTop + (ALBUM_ROW_HEIGHT - textBlockHeight) // 2

            graphics.setFont(Typography.large)
            graphics.drawText(
                Typography.truncateToWidth(Typography.large, album.title, textWidth),
                ALBUM_TEXT_LEFT, textTop)

            local detailParts = { album.artist or "Unknown artist" }
            if album.year then
                table.insert(detailParts, tostring(album.year))
            end
            table.insert(detailParts, string.format("%d tracks", #album.tracks))
            table.insert(detailParts, Library.formatDuration(Library.albumDuration(album)))

            graphics.setFont(Typography.body)
            graphics.drawText(
                Typography.truncateToWidth(Typography.body,
                    table.concat(detailParts, "  "), textWidth),
                ALBUM_TEXT_LEFT, textTop + titleHeight + ALBUM_TITLE_TO_DETAIL_GAP)
        end)
    end

    drawScrollIndicator(albumCount, visibleRowCount, albumScrollOffset, ALBUM_LIST_TOP_EDGE)
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

    local headerWidth = CONTENT_RIGHT_EDGE - LIST_LEFT_EDGE

    graphics.setFont(Typography.large)
    graphics.drawText(
        Typography.truncateToWidth(Typography.large, openedAlbum.title, headerWidth),
        LIST_LEFT_EDGE, 3)

    graphics.setFont(Typography.body)
    graphics.drawText(
        Typography.truncateToWidth(Typography.body, openedAlbum.artist or "", headerWidth),
        LIST_LEFT_EDGE, 28)

    local titleWidth = CONTENT_RIGHT_EDGE - TRACK_DURATION_COLUMN_WIDTH - TRACK_TITLE_LEFT

    for visibleRow = 1, visibleRowCount do
        local trackIndex = trackScrollOffset + visibleRow
        local track = openedAlbum.tracks[trackIndex]
        if not track then
            break
        end

        local bandTop = TRACK_LIST_TOP_EDGE + (visibleRow - 1) * TRACK_ROW_HEIGHT
        if bandTop + TRACK_ROW_HEIGHT > SCREEN_HEIGHT then
            break
        end

        drawRow(bandTop, TRACK_ROW_HEIGHT, trackIndex == selectedTrackIndex, function()
            Typography.drawCentredInBand(Typography.body,
                string.format("%2d.", trackIndex),
                TRACK_NUMBER_LEFT, bandTop, TRACK_ROW_HEIGHT)

            Typography.drawCentredInBand(Typography.body,
                Typography.truncateToWidth(Typography.body, track.title, titleWidth),
                TRACK_TITLE_LEFT, bandTop, TRACK_ROW_HEIGHT)

            local durationText = Library.formatDuration(track.duration)
            Typography.drawCentredInBand(Typography.body, durationText,
                CONTENT_RIGHT_EDGE - Typography.body:getTextWidth(durationText),
                bandTop, TRACK_ROW_HEIGHT)
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
