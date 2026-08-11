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
import "typography"
import "artwork"
import "glyphs"

ScreenNowPlaying = {}

local graphics <const> = playdate.graphics

local SCREEN_WIDTH <const> = 400

-- Artwork sits hard against the top left, because there is nothing that wants
-- to live above it and the screen is small enough that any wasted band at the
-- top is noticeable.
local ARTWORK_SIZE <const> = 140
local ARTWORK_LEFT <const> = 6
local ARTWORK_TOP <const> = 6
local ARTWORK_BOTTOM <const> = ARTWORK_TOP + ARTWORK_SIZE

-- The right hand column holds the track details, stacked from the top so it
-- lines up with the artwork beside it. The title is in the large font and
-- everything under it is in the body font, which is the same arrangement the
-- album list uses.
local TEXT_LEFT <const> = 154
local TEXT_RIGHT <const> = 394
local TITLE_Y <const> = 8
local ARTIST_Y <const> = 34
local ALBUM_Y <const> = 54

-- How tall a clip has to be to hold one line, for the titles that slide because
-- they do not fit. Taken from the gap to the line below rather than from the
-- font, so a descender cannot be shaved off: the title has 26 pixels before the
-- artist and the shorter lines have 20.
local TITLE_BAND_HEIGHT <const> = ARTIST_Y - TITLE_Y
local LINE_BAND_HEIGHT <const> = ALBUM_Y - ARTIST_Y
local TRACK_COUNTER_Y <const> = 74

-- The compact spectrum fills what is left of the right column and is bottom
-- aligned with the artwork, so the two form a single block. It gets the space
-- that the playback state line used to occupy here, which has moved down to a
-- row of its own, and it is half again as tall as a result.
local SPECTRUM_LEFT <const> = TEXT_LEFT
local SPECTRUM_RIGHT <const> = TEXT_RIGHT
local SPECTRUM_BOTTOM_Y <const> = ARTWORK_BOTTOM
local SPECTRUM_MAXIMUM_HEIGHT <const> = 46

-- The waveform scrub bar spans the full width below both columns. It is
-- shorter than it used to be, which it can afford now that it shows the shape
-- of a song rather than a solid block. The old version drew the peak amplitude
-- of each slice, and the peak of any given second of a mastered record is very
-- nearly full scale, so it was pinned to the top for most of most songs. It now
-- draws RMS loudness, which actually varies.
--
-- It was cut to 16 either side to make room for a row of playback state under
-- it. That row has gone, the glyphs that replaced it live on the time row, and
-- the height goes back where it came from rather than being left as a gap.
local WAVEFORM_LEFT <const> = 6
local WAVEFORM_WIDTH <const> = 388
local WAVEFORM_CENTER_Y <const> = 176
local WAVEFORM_HALF_HEIGHT <const> = 22

-- The playhead marker extends a little beyond the waveform so it stays visible
-- during a quiet passage where the waveform itself is only a few pixels tall.
local PLAYHEAD_OVERHANG <const> = 6

local TIME_ROW_Y <const> = 216

-- The playback glyphs share the time row, centered between the elapsed time on
-- the left and the total on the right. That band was already there and empty,
-- which is the whole reason the state row above it could go.
--
-- Nudged up by a pixel so a 20 pixel glyph sits level with 18 pixel type rather
-- than one pixel low.
local GLYPH_ROW_TOP <const> = TIME_ROW_Y - 1
local GLYPH_GAP <const> = 10

-- Album artwork is cached so that stepping between tracks on the same record
-- does not reload the same image on every frame.
local cachedArtworkImage = nil
local cachedArtworkPath = nil

-- Down carries two controls: a short press cycles the play mode, and holding it
-- cycles the repeat mode. They share a button because this screen has no free
-- ones left, and the obvious alternative was the system menu, which stops the
-- audio the moment it opens. Putting a playback control behind something that
-- silences playback is not a trade worth making for a setting you might change
-- three times a record.
local REPEAT_HOLD_DURATION_MILLISECONDS <const> = 400

-- When down went down, and whether the hold has already fired for this press.
local downPressedAtMilliseconds = nil
local downHoldAlreadyFired = false

-- B does the same trick: a short press goes back, a longer one drops into
-- pocket mode. Longer than the repeat hold, because going back is the common
-- action of the two and should not feel like it is waiting on anything.
local POCKET_HOLD_DURATION_MILLISECONDS <const> = 700

local backPressedAtMilliseconds = nil
local backHoldAlreadyFired = false


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
    local markerTop = WAVEFORM_CENTER_Y - WAVEFORM_HALF_HEIGHT - PLAYHEAD_OVERHANG
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
        graphics.drawRect(WAVEFORM_LEFT, WAVEFORM_CENTER_Y - 5, WAVEFORM_WIDTH, 10)
        graphics.fillRect(WAVEFORM_LEFT, WAVEFORM_CENTER_Y - 5, WAVEFORM_WIDTH * playedFraction, 10)
    else
        local pointCount = #analysis.waveform
        local pointSpacing = WAVEFORM_WIDTH / pointCount
        local playedPointCount = math.floor(playedFraction * pointCount)

        for pointIndex, pointValue in ipairs(analysis.waveform) do
            local barHalfHeight = math.max(1, (pointValue / 255) * WAVEFORM_HALF_HEIGHT)
            local barLeft = WAVEFORM_LEFT + (pointIndex - 1) * pointSpacing
            local barWidth = math.max(1, pointSpacing - 1)

            if pointIndex <= playedPointCount then
                graphics.fillRect(barLeft, WAVEFORM_CENTER_Y - barHalfHeight, barWidth, barHalfHeight * 2)
            else
                graphics.drawRect(barLeft, WAVEFORM_CENTER_Y - barHalfHeight, barWidth, barHalfHeight * 2)
            end
        end
    end

    drawPlayheadMarker(WAVEFORM_LEFT + WAVEFORM_WIDTH * playedFraction)
end


-- Draw what playback is doing, as a centered row of glyphs.
--
-- Text was tried first and the trouble with it is that the interesting states
-- are the unusual ones, and text gives them no more weight than the ordinary
-- ones. "paused   shuffle albums   repeat album" is also close to the width of
-- the screen, so it had to live on its own full width row.
--
-- Only the transport is always drawn. In order and repeat off contribute
-- nothing, so a row with one glyph means one thing is out of the ordinary and
-- you can see that without reading anything.
local function drawPlaybackGlyphs()
    local drawGlyph = {}

    table.insert(drawGlyph, Player.isPlaying() and Glyphs.drawPlay or Glyphs.drawPause)

    if Player.playMode == Player.PLAY_MODE_SHUFFLE_TRACKS then
        table.insert(drawGlyph, Glyphs.drawShuffle)
    elseif Player.playMode == Player.PLAY_MODE_SHUFFLE_ALBUMS then
        -- Two glyphs, because shuffling whole records is a different thing from
        -- shuffling songs and one mark cannot say both. The record after the
        -- crossed arrows says what is being shuffled.
        table.insert(drawGlyph, Glyphs.drawShuffle)
        table.insert(drawGlyph, Glyphs.drawRecord)
    end

    if Player.repeatMode == Player.REPEAT_ALBUM then
        table.insert(drawGlyph, Glyphs.drawRepeat)
    elseif Player.repeatMode == Player.REPEAT_TRACK then
        table.insert(drawGlyph, Glyphs.drawRepeatTrack)
    end

    local totalWidth = #drawGlyph * Glyphs.SIZE + (#drawGlyph - 1) * GLYPH_GAP
    local left = (SCREEN_WIDTH - totalWidth) // 2

    for _, draw in ipairs(drawGlyph) do
        draw(left, GLYPH_ROW_TOP)
        left = left + Glyphs.SIZE + GLYPH_GAP
    end
end


function ScreenNowPlaying.enter()
    -- Clear the hold tracking, in case the screen was left while a button was
    -- still held. Otherwise the release lands here on the way back in and fires
    -- an action nobody asked for, which matters most coming back from pocket
    -- mode, where B has almost certainly just been held down.
    downPressedAtMilliseconds = nil
    downHoldAlreadyFired = false

    -- A long title starts from its beginning each time this screen is arrived
    -- at, rather than wherever it had slid to last time.
    Marquee.reset()
    backPressedAtMilliseconds = nil
    backHoldAlreadyFired = false
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

    -- Down cycles the play mode on a short press and the repeat mode on a hold.
    -- The play mode can only change on release, because until the button comes
    -- back up there is no way to tell which of the two was meant.
    --
    -- Acting on a release is only safe if this screen also saw the press. A
    -- button pressed on another screen that switches here lands its release on
    -- this screen, and without that check the release is read as a short press
    -- that nobody made. All three of the ways in are affected: down and B both
    -- leave the visualizer, B reaches here from the album list, and unlocking
    -- pocket mode needs B held. So arriving here by any route fired an action
    -- immediately on letting go.
    if playdate.buttonJustPressed(playdate.kButtonDown) then
        downPressedAtMilliseconds = playdate.getCurrentTimeMilliseconds()
        downHoldAlreadyFired = false
    end

    if downPressedAtMilliseconds
        and not downHoldAlreadyFired
        and playdate.buttonIsPressed(playdate.kButtonDown)
        and playdate.getCurrentTimeMilliseconds() - downPressedAtMilliseconds
            >= REPEAT_HOLD_DURATION_MILLISECONDS then
        Player.cycleRepeatMode()
        downHoldAlreadyFired = true
    end

    if playdate.buttonJustReleased(playdate.kButtonDown) then
        local pressBeganHere = downPressedAtMilliseconds ~= nil
        downPressedAtMilliseconds = nil
        if pressBeganHere and not downHoldAlreadyFired then
            Player.cyclePlayMode()
        end
    end

    if playdate.buttonJustPressed(playdate.kButtonUp) then
        return "visualizer"
    end

    -- B carries two controls the same way down does: a short press goes back to
    -- the library, holding it drops into pocket mode.
    --
    -- Pocket mode needs a deliberate way in and this screen has no spare button,
    -- so it shares one. The system menu was the alternative and is worse, since
    -- opening it stops the audio, which is precisely the wrong thing to do at
    -- the moment you are putting the device away with music playing.
    if playdate.buttonJustPressed(playdate.kButtonB) then
        backPressedAtMilliseconds = playdate.getCurrentTimeMilliseconds()
        backHoldAlreadyFired = false
    end

    if backPressedAtMilliseconds
        and not backHoldAlreadyFired
        and playdate.buttonIsPressed(playdate.kButtonB)
        and playdate.getCurrentTimeMilliseconds() - backPressedAtMilliseconds
            >= POCKET_HOLD_DURATION_MILLISECONDS then
        backHoldAlreadyFired = true
        backPressedAtMilliseconds = nil
        return "pocket"
    end

    if playdate.buttonJustReleased(playdate.kButtonB) then
        local pressBeganHere = backPressedAtMilliseconds ~= nil
        backPressedAtMilliseconds = nil
        if pressBeganHere and not backHoldAlreadyFired then
            return "library"
        end
    end

    return nil
end


function ScreenNowPlaying.draw()
    local entry = Player.currentEntry()
    if not entry then
        graphics.setFont(Typography.body)
        graphics.drawText("Nothing playing", 140, 110)
        return
    end

    local track = entry.track
    local album = entry.album

    -- Here the cover sits on the screen background rather than inside a
    -- highlight, so unlike the album list this one does depend on whether the
    -- display is inverted. Artwork.draw flips it on the way in when it is, so
    -- the display's flip on the way out cancels and a cover stays a cover.
    local artwork = artworkForAlbum(album)
    if artwork then
        Artwork.draw(artwork, ARTWORK_LEFT, ARTWORK_TOP)
    else
        Artwork.drawCoverMark(ARTWORK_LEFT, ARTWORK_TOP, ARTWORK_SIZE)
    end

    -- Everything in the right hand column is held to the column, because a long
    -- title would otherwise run off the right of the screen. Anything too long
    -- slides back and forth rather than being cut, since this is the one screen
    -- where a title sits still long enough to be worth reading in full.
    local columnWidth = TEXT_RIGHT - TEXT_LEFT

    Marquee.draw("nowPlayingTitle", Typography.large, track.title,
        TEXT_LEFT, TITLE_Y, columnWidth, TITLE_BAND_HEIGHT)

    Marquee.draw("nowPlayingArtist", Typography.body, album.artist or "",
        TEXT_LEFT, ARTIST_Y, columnWidth, LINE_BAND_HEIGHT)

    local albumLine = album.title or ""
    if album.year then
        albumLine = albumLine .. "  " .. album.year
    end
    Marquee.draw("nowPlayingAlbum", Typography.body, albumLine,
        TEXT_LEFT, ALBUM_Y, columnWidth, LINE_BAND_HEIGHT)

    graphics.setFont(Typography.body)

    graphics.drawText(
        string.format("track %d of %d", entry.trackIndex or 1, #album.tracks),
        TEXT_LEFT, TRACK_COUNTER_Y)

    local position = Player.position()
    local length = Player.length()
    local analysis = Player.currentAnalysis()

    drawSpectrumStrip(analysis, position)
    drawWaveformScrubBar(analysis, position, length)

    drawPlaybackGlyphs()

    -- Elapsed on the left, total on the right. The total is right aligned by
    -- measuring it rather than guessing a character width, because the font is
    -- variable width.
    graphics.drawText(Library.formatDuration(position), WAVEFORM_LEFT, TIME_ROW_Y)

    local totalDurationText = Library.formatDuration(length)
    graphics.drawText(totalDurationText,
        SCREEN_WIDTH - WAVEFORM_LEFT - Typography.body:getTextWidth(totalDurationText),
        TIME_ROW_Y)
end
