-- The readable visualizers.
--
-- Not exotic, but these are the ones where you can actually see what the music
-- is doing, which is worth having when the others are being decorative.

import "visualizers"

local graphics <const> = playdate.graphics


-- ---------------------------------------------------------------------------
-- Spectrum bars
-- ---------------------------------------------------------------------------
--
-- The sixteen analysis bands drawn at full screen height, with a slowly
-- falling peak marker above each bar. The peaks are what make a bar graph
-- readable: without them a fast passage is a blur, and with them you can see
-- where each band has recently been.

local SpectrumBars = {
    name = "Spectrum",
    peakHeights = {},
}

function SpectrumBars:reset()
    self.peakHeights = {}
end

function SpectrumBars:draw(context)
    local bandCount = context.bandCount
    local barPitch = context.width / bandCount
    local barWidth = barPitch - 4
    local maximumHeight = context.height - 40

    for bandNumber = 1, bandCount do
        local bandValue = context.bands[bandNumber] or 0
        local barHeight = (bandValue / 255) * maximumHeight
        local barLeft = (bandNumber - 1) * barPitch + 2

        graphics.fillRect(barLeft, context.height - barHeight, barWidth, barHeight)

        -- Peaks rise instantly and fall slowly, so a transient stays visible
        -- for a moment after the sound has gone.
        local previousPeak = self.peakHeights[bandNumber] or 0
        if barHeight > previousPeak then
            self.peakHeights[bandNumber] = barHeight
        else
            self.peakHeights[bandNumber] = math.max(0, previousPeak - 2.2)
        end

        local peakHeight = self.peakHeights[bandNumber]
        if peakHeight > 2 then
            graphics.fillRect(barLeft, context.height - peakHeight - 3, barWidth, 2)
        end
    end

    -- A beat draws a line across the top, which is the simplest possible way
    -- to confirm the onset detection is working and lines up with what you
    -- hear.
    if context.beat then
        graphics.fillRect(0, 0, context.width, 3)
    end
end

Visualizers.register(SpectrumBars)


-- ---------------------------------------------------------------------------
-- Radial spectrum
-- ---------------------------------------------------------------------------
--
-- The same sixteen bands arranged around a circle rather than along a line,
-- which turns the spectrum into a shape. The crank rotates the whole figure,
-- and because the bands are mirrored around the circle the result stays
-- symmetrical however far it is turned.

local RadialSpectrum = {
    name = "Radial",
    rotation = 0,
}

function RadialSpectrum:reset()
    self.rotation = 0
end

function RadialSpectrum:draw(context)
    self.rotation = self.rotation + 0.004 + context.crankDelta / 700

    local centreX = context.width / 2
    local centreY = context.height / 2
    local innerRadius = 26 + context.energy * 20

    -- Each band is drawn twice, mirrored across the vertical axis, so the
    -- figure is symmetrical rather than lopsided.
    local spokeCount = context.bandCount * 2

    local previousX, previousY = nil, nil
    local firstX, firstY = nil, nil

    for spokeNumber = 1, spokeCount do
        -- Walk out through the bands and back again, which produces the
        -- mirroring without a second loop.
        local bandNumber = spokeNumber <= context.bandCount
            and spokeNumber
            or (spokeCount - spokeNumber + 1)

        local bandValue = context.bands[bandNumber] or 0
        local spokeLength = innerRadius + (bandValue / 255) * 88

        local spokeAngle = self.rotation + (spokeNumber / spokeCount) * math.pi * 2
        local pointX = centreX + math.cos(spokeAngle) * spokeLength
        local pointY = centreY + math.sin(spokeAngle) * spokeLength

        if previousX then
            graphics.drawLine(previousX, previousY, pointX, pointY)
        else
            firstX, firstY = pointX, pointY
        end

        graphics.drawLine(centreX, centreY, pointX, pointY)

        previousX, previousY = pointX, pointY
    end

    -- Close the outline back to where it started.
    if previousX and firstX then
        graphics.drawLine(previousX, previousY, firstX, firstY)
    end

    if context.beat then
        graphics.drawCircleAtPoint(centreX, centreY, innerRadius + 96)
    end
end

Visualizers.register(RadialSpectrum)


-- ---------------------------------------------------------------------------
-- Waveform scope
-- ---------------------------------------------------------------------------
--
-- The whole track's waveform drawn large, with the playhead riding it and the
-- section currently playing magnified underneath. It is the only visualizer
-- that shows you where you are in the track rather than only what it sounds
-- like right now, which makes it the useful one to leave running while
-- scrubbing with the crank.

local WaveformScope = {
    name = "Scope",
}

function WaveformScope:reset()
end

function WaveformScope:draw(context)
    local analysis = context.analysis
    if not analysis or #analysis.waveform == 0 then
        graphics.drawText("no waveform data", 130, 110)
        return
    end

    local waveform = analysis.waveform
    local pointCount = #waveform

    local playedFraction = 0
    if context.length > 0 then
        playedFraction = math.min(1, math.max(0, context.position / context.length))
    end

    -- The whole track across the top half.
    local overviewCentreY = 66
    local overviewHalfHeight = 46
    local pointSpacing = context.width / pointCount
    local playedPointCount = math.floor(playedFraction * pointCount)

    for pointIndex, pointValue in ipairs(waveform) do
        local barHalfHeight = math.max(1, (pointValue / 255) * overviewHalfHeight)
        local barLeft = (pointIndex - 1) * pointSpacing

        if pointIndex <= playedPointCount then
            graphics.fillRect(barLeft, overviewCentreY - barHalfHeight,
                math.max(1, pointSpacing - 1), barHalfHeight * 2)
        else
            graphics.drawRect(barLeft, overviewCentreY - barHalfHeight,
                math.max(1, pointSpacing - 1), barHalfHeight * 2)
        end
    end

    local playheadX = context.width * playedFraction
    graphics.setColor(graphics.kColorWhite)
    graphics.fillRect(playheadX - 2, 8, 5, 116)
    graphics.setColor(graphics.kColorBlack)
    graphics.fillRect(playheadX - 1, 8, 2, 116)

    -- A magnified window around the playhead across the bottom half, so the
    -- immediate neighbourhood is legible while the top shows the whole track.
    local detailCentreY = 180
    local detailHalfHeight = 46
    local windowPointCount = 40
    local firstDetailPoint = math.max(1, playedPointCount - windowPointCount // 2)
    local detailSpacing = context.width / windowPointCount

    for offset = 0, windowPointCount - 1 do
        local pointIndex = firstDetailPoint + offset
        if pointIndex > pointCount then
            break
        end
        local barHalfHeight = math.max(1, (waveform[pointIndex] / 255) * detailHalfHeight)
        graphics.fillRect(offset * detailSpacing, detailCentreY - barHalfHeight,
            math.max(1, detailSpacing - 2), barHalfHeight * 2)
    end

    graphics.drawLine(0, 132, context.width, 132)
end

Visualizers.register(WaveformScope)
