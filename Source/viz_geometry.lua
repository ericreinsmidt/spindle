-- Geometric visualizers.
--
-- These four draw mathematics rather than simulating anything, which suits a
-- 1-bit screen: they are all line work, and line work needs no dithering to
-- read clearly.

import "visualizers"

local graphics <const> = playdate.graphics
local sinePi <const> = Visualizers.sinePi


-- ---------------------------------------------------------------------------
-- Chladni figures
-- ---------------------------------------------------------------------------
--
-- The nodal pattern of a vibrating square plate. Where the plate is still,
-- sand collects, and those still lines are what gets drawn. The two mode
-- numbers come from the dominant frequency bands, so the pattern is the
-- spectrum expressed as physics rather than as bars.
--
-- The plate function is:
--     sin(n*pi*x) * sin(m*pi*y) - sin(m*pi*x) * sin(n*pi*y)
-- and a point is on a nodal line when that value is near zero.

local ChladniFigures = {
    name = "Chladni",

    -- The grid the contour is traced over. It does not need to be fine enough
    -- to look smooth, because the crossing points are interpolated between grid
    -- points, so the curve is smooth regardless. It only needs to be fine
    -- enough to follow the shape without cutting corners. Eight pixels across a
    -- 400 by 240 screen is 50 by 30, which is 1581 evaluations per frame
    -- against the 3840 the filled version needed.
    cellSize = 8,

    -- How thick the nodal lines are drawn, with loudness adding to the base.
    -- One weight for the whole figure rather than per cell: varying thickness
    -- with the local gradient was tried, to fatten the figure where nodal lines
    -- converge, but it cost frames and looked worse than a uniform heavy line.
    baseLineWidth = 7,
    additionalLineWidthWhenLoud = 4,

    -- The mode numbers move toward their targets rather than jumping, so the
    -- pattern morphs smoothly instead of flickering between shapes.
    modeNumberN = 3,
    modeNumberM = 4,
    targetModeN = 3,
    targetModeM = 4,
}

function ChladniFigures:reset()
    self.modeNumberN = 3
    self.modeNumberM = 4
    self.targetModeN = 3
    self.targetModeM = 4
    self.driftPhase = 0
    self.phaseOffset = 0

    -- Reused every frame so the per frame work allocates nothing.
    self.sineNofX = {}
    self.sineMofX = {}
    self.sineMofY = {}
    self.sineNofY = {}
    self.plateValues = {}
end

function ChladniFigures:draw(context)
    if not self.plateValues then
        self:reset()
    end

    local bass, mid, treble = Visualizers.bassMidTreble(context)

    -- The mode numbers follow the music continuously rather than snapping to
    -- whole numbers on a beat. The plate function is defined for fractional
    -- modes, and those intermediate values are where the interesting shapes
    -- are, so quantising to integers threw away most of the movement and left
    -- the pattern sitting still between beats.
    local musicalTargetN = 1.4 + bass * 6.0
    local musicalTargetM = 1.4 + treble * 7.5

    -- A slow independent drift on top, so the figure keeps evolving through a
    -- sustained passage where the spectrum is barely changing. The two rates
    -- are deliberately unrelated, which stops the pattern from settling into a
    -- repeating cycle.
    self.driftPhase = (self.driftPhase or 0) + 0.0032
    musicalTargetN = musicalTargetN + math.sin(self.driftPhase) * 0.9
    musicalTargetM = musicalTargetM + math.sin(self.driftPhase * 0.61 + 1.7) * 0.9

    -- A beat still matters, but as a nudge rather than a jump.
    if context.beat then
        musicalTargetN = musicalTargetN + 0.7
        musicalTargetM = musicalTargetM - 0.5
    end

    self.targetModeN = musicalTargetN
    self.targetModeM = musicalTargetM

    -- Ease gently toward the target. Slower easing than before, because the
    -- target now moves every frame rather than only on beats, and a fast
    -- follow would make the pattern twitch.
    self.modeNumberN = self.modeNumberN + (self.targetModeN - self.modeNumberN) * 0.035
    self.modeNumberM = self.modeNumberM + (self.targetModeM - self.modeNumberM) * 0.035

    -- The crank rotates the whole plate by swapping how far through the
    -- pattern each axis starts, which is a cheap way to make it interactive.
    self.phaseOffset = (self.phaseOffset or 0) + context.crankDelta / 360

    -- Louder passages thicken the nodal lines, so the figure still responds to
    -- the music. When the contour was drawn as filled cells this was a
    -- threshold on how near zero counted as being on the line; now that it is a
    -- traced curve, line width is the direct equivalent.
    -- Rounded to whole pixels, because a fractional width on a 1-bit screen
    -- just moves where the edge lands rather than producing a finer line.
    local lineWidth = self.baseLineWidth
        + math.floor(mid * self.additionalLineWidthWhenLoud)

    local cellSize = self.cellSize
    local columnCount = context.width // cellSize
    local rowCount = context.height // cellSize

    local modeN = self.modeNumberN
    local modeM = self.modeNumberM
    local phase = self.phaseOffset

    -- Precompute the sines along each axis once per frame.
    --
    -- These depend only on their own coordinate, so evaluating them inside the
    -- inner loop meant recomputing the identical value once per column, eighty
    -- times over for every row. That was most of the cost: the first version of
    -- this ran at six frames per second.
    --
    -- The tables are allocated once and reused rather than rebuilt each frame,
    -- to keep the garbage collector out of it. They cover one more entry than
    -- there are cells, because the contour is traced between grid points and
    -- needs the value at the far edge too.
    local sineNofX = self.sineNofX
    local sineMofX = self.sineMofX
    for column = 0, columnCount do
        local horizontalPosition = column / columnCount + phase
        sineNofX[column] = sinePi(modeN * horizontalPosition)
        sineMofX[column] = sinePi(modeM * horizontalPosition)
    end

    local sineMofY = self.sineMofY
    local sineNofY = self.sineNofY
    for row = 0, rowCount do
        local verticalPosition = row / rowCount
        sineMofY[row] = sinePi(modeM * verticalPosition)
        sineNofY[row] = sinePi(modeN * verticalPosition)
    end

    -- Evaluate the plate function at every grid point, storing the results so
    -- each one is computed once rather than four times over as a corner of four
    -- neighbouring cells.
    local plateValues = self.plateValues
    local valuesPerColumn = rowCount + 1
    for column = 0, columnCount do
        local columnSineN = sineNofX[column]
        local columnSineM = sineMofX[column]
        local columnBase = column * valuesPerColumn
        for row = 0, rowCount do
            plateValues[columnBase + row] =
                columnSineN * sineMofY[row] - columnSineM * sineNofY[row]
        end
    end

    -- Trace the nodal contour rather than filling cells.
    --
    -- Filling every cell where the function was near zero produced lines as
    -- thick as the grid, which is why it looked blocky next to the visualizers
    -- that draw real lines. Instead, each cell is examined for places where the
    -- function changes sign along one of its edges. That crossing is the exact
    -- point where the plate is still, and its position along the edge is found
    -- by linear interpolation, so the resulting curve is smooth at a resolution
    -- far finer than the grid itself.
    --
    -- A cell with two crossings has a single piece of contour passing through
    -- it, so the two points are joined. Four crossings means a saddle, where
    -- two separate branches pass through the same cell, and joining them in
    -- pairs is close enough at this size.
    graphics.setLineWidth(lineWidth)

    -- Round caps, which is what makes this read as a line at all.
    --
    -- Every cell draws its own separate segment, and a segment is at most one
    -- cell across, so at eight pixels long and up to eleven wide it is barely
    -- longer than it is thick. With the default butt cap each one ends in a
    -- square cut perpendicular to its own direction, and because neighbouring
    -- segments meet at an angle those square ends leave a notch on the outside
    -- of every bend. The result reads as a stack of little blocks rather than
    -- as a stroke.
    --
    -- A round cap puts a half disc on each end, which fills the notch where the
    -- next segment starts and lets consecutive segments merge into one
    -- continuous curve. This is the cheap version of the filled circles that
    -- were drawn at every segment end in an earlier attempt, which looked right
    -- and cost too much.
    graphics.setLineCapStyle(graphics.kLineCapStyleRound)

    for column = 0, columnCount - 1 do
        local leftBase = column * valuesPerColumn
        local rightBase = leftBase + valuesPerColumn
        local cellLeft = column * cellSize
        local cellRight = cellLeft + cellSize

        for row = 0, rowCount - 1 do
            local topLeft = plateValues[leftBase + row]
            local topRight = plateValues[rightBase + row]
            local bottomLeft = plateValues[leftBase + row + 1]
            local bottomRight = plateValues[rightBase + row + 1]

            -- Sign tests are cheap, and most cells have no contour in them at
            -- all, so this rejects the majority before any arithmetic.
            local topLeftIsNegative = topLeft < 0
            if topLeftIsNegative ~= (topRight < 0)
                or topLeftIsNegative ~= (bottomLeft < 0)
                or topLeftIsNegative ~= (bottomRight < 0) then

                local cellTop = row * cellSize
                local cellBottom = cellTop + cellSize

                local crossingCount = 0
                local firstX, firstY, secondX, secondY
                local thirdX, thirdY, fourthX, fourthY

                if topLeftIsNegative ~= (topRight < 0) then
                    crossingCount = 1
                    firstX = cellLeft + cellSize * (topLeft / (topLeft - topRight))
                    firstY = cellTop
                end

                if (topRight < 0) ~= (bottomRight < 0) then
                    local crossingX = cellRight
                    local crossingY = cellTop + cellSize * (topRight / (topRight - bottomRight))
                    crossingCount = crossingCount + 1
                    if crossingCount == 1 then
                        firstX, firstY = crossingX, crossingY
                    else
                        secondX, secondY = crossingX, crossingY
                    end
                end

                if (bottomLeft < 0) ~= (bottomRight < 0) then
                    local crossingX = cellLeft + cellSize * (bottomLeft / (bottomLeft - bottomRight))
                    local crossingY = cellBottom
                    crossingCount = crossingCount + 1
                    if crossingCount == 1 then
                        firstX, firstY = crossingX, crossingY
                    elseif crossingCount == 2 then
                        secondX, secondY = crossingX, crossingY
                    else
                        thirdX, thirdY = crossingX, crossingY
                    end
                end

                if topLeftIsNegative ~= (bottomLeft < 0) then
                    local crossingX = cellLeft
                    local crossingY = cellTop + cellSize * (topLeft / (topLeft - bottomLeft))
                    crossingCount = crossingCount + 1
                    if crossingCount == 2 then
                        secondX, secondY = crossingX, crossingY
                    elseif crossingCount == 3 then
                        thirdX, thirdY = crossingX, crossingY
                    else
                        fourthX, fourthY = crossingX, crossingY
                    end
                end

                if crossingCount == 2 then
                    graphics.drawLine(firstX, firstY, secondX, secondY)
                elseif crossingCount == 4 then
                    graphics.drawLine(firstX, firstY, secondX, secondY)
                    graphics.drawLine(thirdX, thirdY, fourthX, fourthY)
                end
            end
        end
    end

    graphics.setLineWidth(1)
    graphics.setLineCapStyle(graphics.kLineCapStyleButt)
end

Visualizers.register(ChladniFigures)


-- ---------------------------------------------------------------------------
-- Fourier epicycles
-- ---------------------------------------------------------------------------
--
-- Circles rotating on circles, with the pen at the end tracing a curve. Each
-- circle's radius is taken directly from a spectrum band, which makes this the
-- most literal visualizer of the set: a Fourier series is exactly what the
-- analysis computed, so the drawing mechanism and the audio analysis are the
-- same operation.

local FourierEpicycles = {
    name = "Epicycles",
    circleCount = 6,
    trace = {},
    maximumTraceLength = 260,
    rotationPhase = 0,
}

function FourierEpicycles:reset()
    self.trace = {}
    self.rotationPhase = 0
end

function FourierEpicycles:draw(context)
    -- The crank adds to the rotation speed, so cranking winds the whole
    -- mechanism faster and reverses it when turned the other way.
    self.rotationPhase = self.rotationPhase + 0.012 + context.crankDelta / 2000

    local centreX = context.width / 2
    local centreY = context.height / 2

    local penX = centreX
    local penY = centreY

    for circleNumber = 1, self.circleCount do
        -- Spread the chosen bands across the spectrum rather than taking the
        -- first six, so the mechanism responds to the whole range.
        local bandNumber = 1 + (circleNumber - 1) * 3
        local bandValue = context.bands[math.min(bandNumber, context.bandCount)] or 0
        local radius = 6 + (bandValue / 255) * (74 / circleNumber)

        -- Each circle turns at an integer multiple of the base rate, which is
        -- what makes the traced figure close rather than wander.
        local angle = self.rotationPhase * circleNumber * (circleNumber % 2 == 0 and -1 or 1)

        local nextX = penX + math.cos(angle) * radius
        local nextY = penY + math.sin(angle) * radius

        graphics.drawCircleAtPoint(penX, penY, radius)
        graphics.drawLine(penX, penY, nextX, nextY)

        penX = nextX
        penY = nextY
    end

    -- The pen leaves a trail, which is the actual figure being drawn.
    table.insert(self.trace, { x = penX, y = penY })
    while #self.trace > self.maximumTraceLength do
        table.remove(self.trace, 1)
    end

    -- A beat clears the trail, so each phrase draws a fresh figure instead of
    -- accumulating into an unreadable tangle.
    if context.beat and #self.trace > 40 then
        self.trace = {}
    end

    for pointIndex = 2, #self.trace do
        local previousPoint = self.trace[pointIndex - 1]
        local currentPoint = self.trace[pointIndex]
        graphics.drawLine(previousPoint.x, previousPoint.y, currentPoint.x, currentPoint.y)
    end
end

Visualizers.register(FourierEpicycles)


-- ---------------------------------------------------------------------------
-- Harmonograph
-- ---------------------------------------------------------------------------
--
-- A Victorian drawing machine: two pendulums swinging at right angles, each
-- losing energy over time, with a pen tracing where they meet. The frequencies
-- come from the spectrum, so different music draws different figures, and the
-- decay means each drawing completes and fades rather than running forever.

local Harmonograph = {
    name = "Harmonograph",
    trace = {},
    maximumTraceLength = 700,
    elapsedTime = 0,
    frequencyX = 2.0,
    frequencyY = 3.0,
    phaseOffset = 0,
}

function Harmonograph:reset()
    self.trace = {}
    self.elapsedTime = 0
end

function Harmonograph:draw(context)
    local bass, mid, treble = Visualizers.bassMidTreble(context)

    -- Restart the drawing when the pen has run out of travel, choosing new
    -- frequencies from the music. Simple ratios give closed elegant loops, so
    -- the values are kept small and near whole numbers.
    if self.elapsedTime > 26 then
        self.elapsedTime = 0
        self.trace = {}
        self.frequencyX = 1 + math.floor(bass * 4) + (mid * 0.02)
        self.frequencyY = 1 + math.floor(treble * 5) + (bass * 0.02)
        self.phaseOffset = mid * math.pi
    end

    -- The crank advances the pen faster, so cranking draws the figure more
    -- quickly rather than changing its shape.
    self.elapsedTime = self.elapsedTime + 0.08 + math.abs(context.crankDelta) / 400

    local centreX = context.width / 2
    local centreY = context.height / 2
    local damping = math.exp(-self.elapsedTime * 0.06)
    local amplitude = 96 * damping

    local penX = centreX + math.sin(self.elapsedTime * self.frequencyX) * amplitude
    local penY = centreY + math.sin(self.elapsedTime * self.frequencyY + self.phaseOffset) * amplitude * 0.62

    table.insert(self.trace, { x = penX, y = penY })
    while #self.trace > self.maximumTraceLength do
        table.remove(self.trace, 1)
    end

    for pointIndex = 2, #self.trace do
        local previousPoint = self.trace[pointIndex - 1]
        local currentPoint = self.trace[pointIndex]
        graphics.drawLine(previousPoint.x, previousPoint.y, currentPoint.x, currentPoint.y)
    end
end

Visualizers.register(Harmonograph)


-- ---------------------------------------------------------------------------
-- Moire interference
-- ---------------------------------------------------------------------------
--
-- Two line grids overlaid, one rotated against the other. The interference
-- bands that appear are not drawn by anything, they emerge from where the
-- lines nearly coincide. This is the cheapest visualizer here and the one most
-- native to a 1-bit screen, because moire needs hard pixels and looks worse
-- with any smoothing at all.

local MoireInterference = {
    name = "Moire",
    rotationAngle = 0.3,
}

function MoireInterference:reset()
    self.rotationAngle = 0.3
end

function MoireInterference:draw(context)
    local bass, mid, treble = Visualizers.bassMidTreble(context)

    -- The crank rotates the second grid directly, which is the whole
    -- interaction: small movements produce large changes in the pattern.
    self.rotationAngle = self.rotationAngle + context.crankDelta / 900

    -- A beat nudges the angle, so the pattern jumps on the music even when
    -- nobody is touching the crank.
    if context.beat then
        self.rotationAngle = self.rotationAngle + 0.04
    end

    local firstGridSpacing = 5 + bass * 9
    local secondGridSpacing = 5 + treble * 9

    -- The first grid is plain vertical lines.
    local horizontalPosition = 0
    while horizontalPosition < context.width do
        graphics.drawLine(horizontalPosition, 0, horizontalPosition, context.height)
        horizontalPosition = horizontalPosition + firstGridSpacing
    end

    -- The second grid is drawn rotated, extended well past the screen edges so
    -- that rotating it never reveals an end.
    local angleCosine = math.cos(self.rotationAngle)
    local angleSine = math.sin(self.rotationAngle)
    local centreX = context.width / 2
    local centreY = context.height / 2
    local lineHalfLength = 320

    local offsetFromCentre = -320
    while offsetFromCentre < 320 do
        -- A line perpendicular to the rotation direction, offset sideways.
        local baseX = centreX + angleCosine * offsetFromCentre
        local baseY = centreY + angleSine * offsetFromCentre

        graphics.drawLine(
            baseX - angleSine * lineHalfLength,
            baseY + angleCosine * lineHalfLength,
            baseX + angleSine * lineHalfLength,
            baseY - angleCosine * lineHalfLength
        )

        offsetFromCentre = offsetFromCentre + secondGridSpacing
    end

    -- Mid energy punches a clear circle in the middle, giving the eye
    -- somewhere to rest and making the interference read as deliberate.
    if mid > 0.25 then
        graphics.setColor(graphics.kColorWhite)
        graphics.fillCircleAtPoint(centreX, centreY, 14 + mid * 40)
        graphics.setColor(graphics.kColorBlack)
        graphics.drawCircleAtPoint(centreX, centreY, 14 + mid * 40)
    end
end

Visualizers.register(MoireInterference)
