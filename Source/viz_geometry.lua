-- Geometric visualizers.
--
-- These three draw mathematics rather than simulating anything, which suits a
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
--
-- Shown as Haring, for the heavy black outlines it ends up drawing.

local ChladniFigures = {
    name = "Haring",

    -- The grid the contour is traced over. It does not need to be fine enough
    -- to look smooth, because the crossing points are interpolated between grid
    -- points, so the curve is smooth regardless. It only needs to be fine
    -- enough to follow the shape without cutting corners.
    --
    -- Fourteen pixels across a 400 by 240 screen is 28 by 17, which is 522
    -- evaluations per frame, against 3840 for the filled version this replaced.
    --
    -- Fourteen rather than ten is the single biggest thing keeping this inside
    -- the frame budget, and the reason is overdraw rather than arithmetic. Each
    -- cell draws its own round capped segment, and a cap sticks out half a line
    -- width past each end. At widths up to 26 with cells only 10 apart, every
    -- segment's caps reach well past where the next segment begins, so most of
    -- that ink is the same pixels being filled two or three times over.
    --
    -- Measured on device, 60 frames per variant, at identical widths:
    --
    --     cell 10   41.5 ms      cell 14   28.4 ms      cell 18   22.1 ms
    --
    -- Narrowing the lines instead barely helps, which is what says the cost is
    -- overdraw and not ink: at cell 14, dropping the widths from 10 to 26 down
    -- to 8 to 22 saved only 4 percent, and down to 8 to 18 only 8 percent, for
    -- a figure that looks much lighter. Eighteen was measured and rejected on
    -- looks: it polygonises tight curves and makes the width estimate noisy
    -- enough to leave isolated fat spots along a run.
    cellSize = 14,

    -- How thick the nodal lines are drawn.
    --
    -- The width comes from the local steepness of the plate rather than being
    -- one weight for the whole figure, because that is what gives a Chladni
    -- pattern its character. On a real plate the still region is wide where the
    -- surface is flat and narrow where it is steep, and nodal lines converge
    -- exactly where the surface flattens, so the figure swells where lines meet
    -- and stays fine elsewhere.
    --
    -- The very first version of this visualizer had that property by accident.
    -- It filled any cell where the plate value was near zero, and thresholding a
    -- field like that produces a band whose width is set by the gradient without
    -- anyone asking for it. Tracing the contour threw it away, because a contour
    -- is a curve with no width at all, and the width had to be put back by hand.
    --
    -- Putting it back was tried once before and reverted, but that attempt was
    -- paying for two things at once: this, and a filled circle at every segment
    -- end to hide the notching between segments. Round caps now do the second
    -- job for nothing, so this is a different proposition.
    --
    -- The threshold is what the width is derived from, in the units of the plate
    -- function, and loudness widens it so the whole figure thickens with the
    -- music.
    nodalThreshold = 0.30,
    additionalThresholdWhenLoud = 0.10,

    -- The bounds on the width matter more than they look, and how they are
    -- applied matters as much as what they are.
    --
    -- Width goes as one over the gradient, so a region where the plate is
    -- genuinely flat asks for an unbounded width. The very first version had no
    -- limit at all, and at some mode numbers an entire corner of the screen
    -- filled in solid and the line stopped being a line.
    --
    -- Clamping that with a hard minimum and maximum was the obvious fix and it
    -- was wrong. One over the gradient is very steep near zero, so two
    -- neighbouring cells with almost the same gradient can land far apart in
    -- width, and the clamp then chops that off abruptly. The result was
    -- occasional single cells fatter than everything around them, which broke
    -- the line into lumps.
    --
    -- These are used as the ends of a smooth curve instead:
    --
    --     width = minimum + range / (1 + range * gradient / (2 * threshold))
    --
    -- which approaches the maximum as the gradient goes to zero and the minimum
    -- as it grows, is smooth everywhere in between, and behaves as one over the
    -- gradient through the middle where that is what is wanted. The bounds are
    -- structural rather than enforced, so nothing has to be clamped and the flat
    -- region case needs no special handling.
    --
    -- The gradient is also averaged with the four neighbouring cells before the
    -- width is worked out. Without it the width still steps from one segment to
    -- the next, and because each segment is drawn with round caps of its own
    -- radius, those steps show up as a slightly scalloped edge along what should
    -- be a clean stroke. Averaging first is what makes the outline flow.
    --
    -- It is done on the squared gradient so the whole thing costs one square
    -- root rather than five.
    minimumLineWidth = 10,
    maximumLineWidth = 34,

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
    self.squaredSlopes = {}
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

    -- Louder passages widen the band that counts as still, so the whole figure
    -- thickens with the music rather than staying a constant weight.
    local nodalThreshold = self.nodalThreshold + mid * self.additionalThresholdWhenLoud

    local minimumLineWidth = self.minimumLineWidth
    local lineWidthRange = self.maximumLineWidth - minimumLineWidth

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

    -- How steeply the plate is rising through each cell, squared.
    --
    -- This is a pass of its own rather than being folded into the tracing below,
    -- because the width of a cell's stroke is averaged with its neighbours, and
    -- a cell cannot average with a neighbour that has not been worked out yet.
    -- Squared, because averaging squares and taking one root at the end gives
    -- the same smoothing for a fifth of the roots.
    local squaredSlopes = self.squaredSlopes
    local inverseCellArea = 1 / (cellSize * cellSize)
    for column = 0, columnCount - 1 do
        local leftBase = column * valuesPerColumn
        local rightBase = leftBase + valuesPerColumn
        local slopeBase = column * rowCount
        for row = 0, rowCount - 1 do
            local topLeft = plateValues[leftBase + row]
            local topRight = plateValues[rightBase + row]
            local bottomLeft = plateValues[leftBase + row + 1]
            local bottomRight = plateValues[rightBase + row + 1]

            local horizontalSlope = topRight + bottomRight - topLeft - bottomLeft
            local verticalSlope = bottomLeft + bottomRight - topLeft - topRight

            -- The halving each slope needs becomes a quarter once squared, so
            -- it is folded in here rather than done twice above.
            squaredSlopes[slopeBase + row] =
                (horizontalSlope * horizontalSlope + verticalSlope * verticalSlope)
                * 0.25 * inverseCellArea
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
    --
    -- The line width is set per cell rather than once for the whole figure, so
    -- it can follow the local steepness of the plate.

    -- Round caps, which is what makes this read as a line at all.
    --
    -- Every cell draws its own separate segment, and a segment is at most one
    -- cell across, so it is barely longer than it is thick. With the default
    -- butt cap each one ends in a
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

                -- How wide the still band is here.
                --
                -- Thresholding the plate function at some small value picks out
                -- a band around the nodal line, and that band's width is simply
                -- twice the threshold divided by how steeply the surface is
                -- rising through it. So a steep region gives a fine line and a
                -- flat region gives a broad one, which is the whole effect.
                --
                -- Averaged with whichever of the four neighbours exist, so the
                -- width changes gradually from one segment to the next instead
                -- of stepping, which is what keeps the edge of the stroke clean.
                local slopeBase = column * rowCount
                local totalSquaredSlope = squaredSlopes[slopeBase + row]
                local cellsAveraged = 1

                if column > 0 then
                    totalSquaredSlope =
                        totalSquaredSlope + squaredSlopes[slopeBase - rowCount + row]
                    cellsAveraged = cellsAveraged + 1
                end
                if column < columnCount - 1 then
                    totalSquaredSlope =
                        totalSquaredSlope + squaredSlopes[slopeBase + rowCount + row]
                    cellsAveraged = cellsAveraged + 1
                end
                if row > 0 then
                    totalSquaredSlope = totalSquaredSlope + squaredSlopes[slopeBase + row - 1]
                    cellsAveraged = cellsAveraged + 1
                end
                if row < rowCount - 1 then
                    totalSquaredSlope = totalSquaredSlope + squaredSlopes[slopeBase + row + 1]
                    cellsAveraged = cellsAveraged + 1
                end

                local slopePerPixel = math.sqrt(totalSquaredSlope / cellsAveraged)

                -- The smooth mapping described where the bounds are declared.
                -- A flat cell gives exactly the maximum and a steep one
                -- approaches the minimum, with no branch and nothing to clamp.
                graphics.setLineWidth(minimumLineWidth + lineWidthRange
                    / (1 + lineWidthRange * slopePerPixel / (2 * nodalThreshold)))

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
-- Harmonograph
-- ---------------------------------------------------------------------------
--
-- A Victorian drawing machine: two pendulums swinging at right angles, each
-- losing energy over time, with a pen tracing where they meet. The frequencies
-- come from the spectrum, so different music draws different figures, and the
-- decay means each drawing completes and fades rather than running forever.
--
-- Shown as Spirograph, which is the toy version of the same idea.

-- How far the pen advances along the curve each frame before the crank adds
-- anything, how long a figure lives before it is restarted, and how quickly the
-- pendulums lose their travel.
local PEN_SPEED_PER_FRAME <const> = 0.08
local FIGURE_LIFETIME <const> = 26
local DAMPING_RATE <const> = 0.06

local Harmonograph = {
    name = "Spirograph",
    trace = {},
    maximumTraceLength = 700,
    frequencyX = 2.0,
    frequencyY = 3.0,
    phaseOffset = 0,
}

function Harmonograph:reset()
    self.trace = {}
    self.penTime = 0
    self.dampingTime = 0
end

function Harmonograph:draw(context)
    if not self.penTime then
        self:reset()
    end

    local bass, mid, treble = Visualizers.bassMidTreble(context)

    -- Restart the drawing when the pendulums have run out of travel, choosing
    -- new frequencies from the music. Simple ratios give closed elegant loops,
    -- so the values are kept small and near whole numbers.
    if self.dampingTime > FIGURE_LIFETIME then
        self.penTime = 0
        self.dampingTime = 0
        self.trace = {}
        self.frequencyX = 1 + math.floor(bass * 4) + (mid * 0.02)
        self.frequencyY = 1 + math.floor(treble * 5) + (bass * 0.02)
        self.phaseOffset = mid * math.pi
    end

    -- Two clocks rather than one.
    --
    -- The pen's position along the curve is what the crank advances, and the
    -- damping that shrinks the figure runs on its own steady clock. These used
    -- to be the same value, and the effect was that cranking to draw the figure
    -- faster also wound it down toward nothing sooner. The control meant to give
    -- you more of the drawing was taking it away instead.
    --
    -- The restart stays on the damping clock, because what actually runs out is
    -- the pendulums' travel and damping is what describes that. So cranking now
    -- draws more of a figure inside the life it already had, rather than
    -- shortening that life.
    self.penTime = self.penTime + PEN_SPEED_PER_FRAME + math.abs(context.crankDelta) / 400
    self.dampingTime = self.dampingTime + PEN_SPEED_PER_FRAME

    local centreX = context.width / 2
    local centreY = context.height / 2
    local damping = math.exp(-self.dampingTime * DAMPING_RATE)
    local amplitude = 96 * damping

    local penX = centreX + math.sin(self.penTime * self.frequencyX) * amplitude
    local penY = centreY + math.sin(self.penTime * self.frequencyY + self.phaseOffset) * amplitude * 0.62

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
--
-- Shown as Screened Porch, which is where most people have actually seen this.

local MoireInterference = {
    name = "Screened Porch",
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
    --
    -- It is sized against the screen rather than by eye. The screen is 240 tall,
    -- so a radius of 100 leaves a 20 pixel margin top and bottom, which is as
    -- large as it can be and still read as a disc sitting on the pattern rather
    -- than as a band across it.
    if mid > 0.25 then
        local holeRadius = 36 + mid * 64

        graphics.setColor(graphics.kColorWhite)
        graphics.fillCircleAtPoint(centreX, centreY, holeRadius)
        graphics.setColor(graphics.kColorBlack)
        graphics.drawCircleAtPoint(centreX, centreY, holeRadius)
    end
end

Visualizers.register(MoireInterference)
