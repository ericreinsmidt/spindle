-- The now playing screen.
--
-- Album art on the left, track details and a compact spectrum on the right,
-- and the precomputed waveform along the bottom acting as both a progress bar
-- and the scrub display. Being able to see the shape of the song while
-- cranking through it is the point: you can tell where the quiet intro ends
-- without hunting for it.
--
-- The crank scrubs here, which is the whole reason ADPCM was chosen over MP3.
-- Seeking costs about a millisecond, so scrubbing feels immediate.

import "library"
import "player"
import "analysis"

ScreenNowPlaying = {}

local graphics <const> = playdate.graphics

local SCREEN_WIDTH <const> = 400
local SCREEN_HEIGHT <const> = 240

-- Artwork sits hard against the top left, because there is nothing that wants
-- to live above it and the screen is small enough that any wasted band at the
-- top is noticeable.
local ARTWORK_SIZE <const> = 140
local ARTWORK_LEFT <const> = 6
local ARTWORK_TOP <const> = 6
local ARTWORK_BOTTOM <const> = ARTWORK_TOP + ARTWORK_SIZE

-- The right hand column holds the track details, stacked from the top so it
-- lines up with the artwork beside it.
local TEXT_LEFT <const> = 158
local TITLE_Y <const> = 6
local ARTIST_Y <const> = 30
local ALBUM_Y <const> = 50
local TRACK_COUNTER_Y <const> = 74
local PLAYBACK_STATE_Y <const> = 94

-- The compact spectrum fills the remaining space in the right column and is
-- bottom aligned with the artwork, so the two form a single block.
local SPECTRUM_LEFT <const> = TEXT_LEFT
local SPECTRUM_RIGHT <const> = 394
local SPECTRUM_BOTTOM_Y <const> = ARTWORK_BOTTOM
local SPECTRUM_MAXIMUM_HEIGHT <const> = 30

-- The waveform scrub bar spans the full width below both columns.
local WAVEFORM_LEFT <const> = 6
local WAVEFORM_WIDTH <const> = 388
local WAVEFORM_CENTRE_Y <const> = 180
local WAVEFORM_HALF_HEIGHT <const> = 22

-- The playhead marker extends a little beyond the waveform so it stays visible
-- during a quiet passage where the waveform itself is only a few pixels tall.
local PLAYHEAD_OVERHANG <const> = 6

local TIME_ROW_Y <const> = 214

-- Album artwork is cached so that stepping between tracks on the same record
-- does not reload the same image on every frame.
local cachedArtworkImage = nil
local cachedArtworkPath = nil

-- A short lived message shown after changing play mode, so the change is
-- visible without permanently occupying screen space.
local transientMessage = nil
local transientMessageExpiresAtMilliseconds = 0


local function showTransientMessage(message)
    transientMessage = message
    transientMessageExpiresAtMilliseconds = playdate.getCurrentTimeMilliseconds() + 1500
end


-- Load the artwork for an album, reusing the cached image when the album has
-- not changed. Returns nil when the album has no artwork, which is normal for
-- files with no embedded picture and no cover sitting beside them.
local function artworkForAlbum(album)
    local artworkPath = album and album.art or nil

    if artworkPath ~= cachedArtworkPath then
        cachedArtworkPath = artworkPath
        cachedArtworkImage = nil
        if artworkPath and playdate.file.exists(artworkPath) then
            cachedArtworkImage = graphics.image.new(artworkPath)
        end
    end

    return cachedArtworkImage
end


-- Draw a placeholder in the artwork slot when a record has no cover, rather
-- than leaving a hole. A 45 adapter outline echoes the app's own mark.
local function drawArtworkPlaceholder()
    graphics.drawRect(ARTWORK_LEFT, ARTWORK_TOP, ARTWORK_SIZE, ARTWORK_SIZE)

    local centreX = ARTWORK_LEFT + ARTWORK_SIZE / 2
    local centreY = ARTWORK_TOP + ARTWORK_SIZE / 2
    graphics.drawCircleAtPoint(centreX, centreY, 44)
    graphics.drawCircleAtPoint(centreX, centreY, 8)

    -- Three spokes at 120 degrees apart, matching the three arm adapter shape.
    for spokeNumber = 0, 2 do
        local spokeAngle = math.rad(90 + spokeNumber * 120)
        graphics.drawLine(
            centreX + math.cos(spokeAngle) * 8,
            centreY + math.sin(spokeAngle) * 8,
            centreX + math.cos(spokeAngle) * 44,
            centreY + math.sin(spokeAngle) * 44
        )
    end
end


-- Draw the compact spectrum. Each bar is one frequency band from the analysis
-- file, with bass on the left and treble on the right. A baseline is drawn
-- underneath so the strip still reads as a deliberate element during a quiet
-- passage rather than looking like a rendering failure.
local function drawSpectrumStrip(analysis, positionInSeconds)
    local baselineY = SPECTRUM_BOTTOM_Y + 1
    graphics.drawLine(SPECTRUM_LEFT, baselineY, SPECTRUM_RIGHT, baselineY)

    local bandValues = Analysis.bandsAtPosition(analysis, positionInSeconds)
    if not bandValues then
        return
    end

    local availableWidth = SPECTRUM_RIGHT - SPECTRUM_LEFT
    local barPitch = availableWidth / #bandValues
    local barWidth = math.max(1, barPitch - 2)

    for bandNumber, bandValue in ipairs(bandValues) do
        local barHeight = (bandValue / 255) * SPECTRUM_MAXIMUM_HEIGHT
        if barHeight >= 1 then
            local barLeft = SPECTRUM_LEFT + (bandNumber - 1) * barPitch
            graphics.fillRect(barLeft, SPECTRUM_BOTTOM_Y - barHeight, barWidth, barHeight)
        end
    end
end


-- Draw the playhead as a vertical bar across the waveform.
--
-- On a 1-bit screen a plain black line would vanish wherever it crosses the
-- filled part of the waveform, so a white gap is punched first and the black
-- line drawn inside it. That reads clearly against both the solid played
-- section and the outlined unplayed section.
local function drawPlayheadMarker(playheadX)
    local markerTop = WAVEFORM_CENTRE_Y - WAVEFORM_HALF_HEIGHT - PLAYHEAD_OVERHANG
    local markerHeight = (WAVEFORM_HALF_HEIGHT + PLAYHEAD_OVERHANG) * 2

    graphics.setColor(graphics.kColorWhite)
    graphics.fillRect(playheadX - 2, markerTop, 5, markerHeight)

    graphics.setColor(graphics.kColorBlack)
    graphics.fillRect(playheadX - 1, markerTop, 2, markerHeight)
end


-- Draw the waveform with the played portion filled solid and the remainder
-- drawn as an outline, so progress reads at a glance even before looking at
-- the playhead or the times.
local function drawWaveformScrubBar(analysis, positionInSeconds, lengthInSeconds)
    local playedFraction = 0
    if lengthInSeconds > 0 then
        playedFraction = positionInSeconds / lengthInSeconds
        if playedFraction < 0 then
            playedFraction = 0
        end
        if playedFraction > 1 then
            playedFraction = 1
        end
    end

    if not analysis or #analysis.waveform == 0 then
        -- With no waveform available, fall back to a plain progress bar so the
        -- screen still shows where you are in the track.
        graphics.drawRect(WAVEFORM_LEFT, WAVEFORM_CENTRE_Y - 5, WAVEFORM_WIDTH, 10)
        graphics.fillRect(WAVEFORM_LEFT, WAVEFORM_CENTRE_Y - 5, WAVEFORM_WIDTH * playedFraction, 10)
    else
        local pointCount = #analysis.waveform
        local pointSpacing = WAVEFORM_WIDTH / pointCount
        local playedPointCount = math.floor(playedFraction * pointCount)

        for pointIndex, pointValue in ipairs(analysis.waveform) do
            local barHalfHeight = math.max(1, (pointValue / 255) * WAVEFORM_HALF_HEIGHT)
            local barLeft = WAVEFORM_LEFT + (pointIndex - 1) * pointSpacing
            local barWidth = math.max(1, pointSpacing - 1)

            if pointIndex <= playedPointCount then
                graphics.fillRect(barLeft, WAVEFORM_CENTRE_Y - barHalfHeight, barWidth, barHalfHeight * 2)
            else
                graphics.drawRect(barLeft, WAVEFORM_CENTRE_Y - barHalfHeight, barWidth, barHalfHeight * 2)
            end
        end
    end

    drawPlayheadMarker(WAVEFORM_LEFT + WAVEFORM_WIDTH * playedFraction)
end


function ScreenNowPlaying.enter()
end


function ScreenNowPlaying.update()
    -- Crank scrubbing. The player accumulates the movement and commits it on an
    -- interval rather than every frame, because committing a seek per frame
    -- hard faulted the device during Phase 0.
    local crankChange = playdate.getCrankChange()
    if math.abs(crankChange) > 0.5 then
        Player.addCrankScrub(crankChange)
    end

    if playdate.buttonJustPressed(playdate.kButtonA) then
        Player.togglePause()
    end

    if playdate.buttonJustPressed(playdate.kButtonLeft) then
        Player.skipToPrevious()
    end

    if playdate.buttonJustPressed(playdate.kButtonRight) then
        Player.skipToNext()
    end

    if playdate.buttonJustPressed(playdate.kButtonDown) then
        Player.cyclePlayMode()
        showTransientMessage(Player.playModeName())
    end

    if playdate.buttonJustPressed(playdate.kButtonUp) then
        return "visualizer"
    end

    if playdate.buttonJustPressed(playdate.kButtonB) then
        return "library"
    end

    return nil
end


function ScreenNowPlaying.draw()
    local entry = Player.currentEntry()
    if not entry then
        graphics.drawText("Nothing playing", 140, 110)
        return
    end

    local track = entry.track
    local album = entry.album

    local artwork = artworkForAlbum(album)
    if artwork then
        artwork:draw(ARTWORK_LEFT, ARTWORK_TOP)
    else
        drawArtworkPlaceholder()
    end

    graphics.drawText("*" .. track.title .. "*", TEXT_LEFT, TITLE_Y)
    graphics.drawText(album.artist or "", TEXT_LEFT, ARTIST_Y)

    local albumLine = album.title or ""
    if album.year then
        albumLine = albumLine .. "  " .. album.year
    end
    graphics.drawText(albumLine, TEXT_LEFT, ALBUM_Y)

    graphics.drawText(
        string.format("track %d of %d", entry.trackIndex or 1, #album.tracks),
        TEXT_LEFT, TRACK_COUNTER_Y)

    local stateText = Player.isPlaying() and "playing" or "paused"
    graphics.drawText(stateText .. "   " .. Player.playModeName(), TEXT_LEFT, PLAYBACK_STATE_Y)

    local position = Player.position()
    local length = Player.length()
    local analysis = Player.currentAnalysis()

    drawSpectrumStrip(analysis, position)
    drawWaveformScrubBar(analysis, position, length)

    -- Elapsed on the left, total on the right. The total is right aligned by
    -- measuring it rather than guessing a character width, because the default
    -- font is variable width.
    graphics.drawText(Library.formatDuration(position), WAVEFORM_LEFT, TIME_ROW_Y)

    local totalDurationText = Library.formatDuration(length)
    local totalDurationWidth = graphics.getTextSize(totalDurationText)
    graphics.drawText(totalDurationText,
        SCREEN_WIDTH - WAVEFORM_LEFT - totalDurationWidth, TIME_ROW_Y)

    -- The transient message sits between the two times, where nothing else
    -- competes for space.
    if transientMessage then
        if playdate.getCurrentTimeMilliseconds() < transientMessageExpiresAtMilliseconds then
            local messageWidth = graphics.getTextSize(transientMessage)
            graphics.drawText(transientMessage,
                (SCREEN_WIDTH - messageWidth) / 2, TIME_ROW_Y)
        else
            transientMessage = nil
        end
    end
end
