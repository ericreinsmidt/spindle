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
--
-- Shown as Maigasa, the Japanese dance umbrella, for the spokes and the ring
-- around them.

-- Everything here is sized so the whole figure fits on the screen.
--
-- The screen is 240 tall, so anything drawn from the center has 120 pixels
-- before it runs off the top and bottom. The spokes previously reached 134 at
-- full band value and the ring on a beat sat at up to 142, so both were being
-- cut off by the edge, and the ring in particular read as two arcs at the sides
-- rather than as a ring at all.
--
-- The longest spoke now reaches 112 and the ring sits at 116, just outside it,
-- which keeps the ring whole and still lets the spokes nearly touch it on a
-- loud passage.
local SPOKE_REACH <const> = 74

-- The figure is drawn as an ellipse rather than a circle, stretched sideways to
-- the shape of the screen.
--
-- A circle here can only ever be as big as the screen is tall, so it reached 112
-- pixels of the 120 available vertically while leaving 88 pixels of nothing down
-- each side. It filled the height and still read as small, because what you
-- notice is the empty width.
--
-- 1.55 is a little under the screen's own 400 by 240, which is 1.67. Going all
-- the way looks stretched; stopping short of it fills the space while still
-- reading as round.
local HORIZONTAL_STRETCH <const> = 1.55
-- The ring that flashes on a beat. An ellipse rather than a circle, stretched
-- by exactly the same amount as the spokes, so the figure it surrounds stays
-- inside it.
--
-- It was a circle at radius 116. Once the spokes were stretched sideways they
-- reached nearly 200 pixels, so on every beat a circle appeared with most of the
-- figure sticking out through it. Two shapes disagreeing about the same centre
-- reads as a mistake, which it was.
local BEAT_RING_RADIUS <const> = 118

local RadialSpectrum = {
    name = "Maigasa",
    rotation = 0,
}

function RadialSpectrum:reset()
    self.rotation = 0
end

function RadialSpectrum:draw(context)
    self.rotation = self.rotation + 0.004 + context.crankDelta / 700

    local centerX = context.width / 2
    local centerY = context.height / 2
    local innerRadius = 32 + context.energy * 22

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
        -- Capped at the ring, so the loudest moments flatten against it rather
        -- than pushing through it. At full energy and a maxed band the reach
        -- would otherwise be 128 against a ring at 118.
        local spokeLength = innerRadius + (bandValue / 255) * SPOKE_REACH
        if spokeLength > BEAT_RING_RADIUS then
            spokeLength = BEAT_RING_RADIUS
        end

        local spokeAngle = self.rotation + (spokeNumber / spokeCount) * math.pi * 2
        local pointX = centerX + math.cos(spokeAngle) * spokeLength * HORIZONTAL_STRETCH
        local pointY = centerY + math.sin(spokeAngle) * spokeLength

        if previousX then
            graphics.drawLine(previousX, previousY, pointX, pointY)
        else
            firstX, firstY = pointX, pointY
        end

        graphics.drawLine(centerX, centerY, pointX, pointY)

        previousX, previousY = pointX, pointY
    end

    -- Close the outline back to where it started.
    if previousX and firstX then
        graphics.drawLine(previousX, previousY, firstX, firstY)
    end

    if context.beat then
        graphics.drawEllipseInRect(
            centerX - BEAT_RING_RADIUS * HORIZONTAL_STRETCH,
            centerY - BEAT_RING_RADIUS,
            BEAT_RING_RADIUS * HORIZONTAL_STRETCH * 2,
            BEAT_RING_RADIUS * 2)
    end
end

Visualizers.register(RadialSpectrum)
