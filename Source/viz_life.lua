-- Simulation visualizers.
--
-- These three run a system rather than drawing a formula, which means each
-- frame depends on the last. That makes them more expensive than the geometric
-- ones, so each keeps its working set deliberately small and two of them draw
-- into a persistent image rather than redrawing everything every frame.

import "visualizers"

local graphics <const> = playdate.graphics


-- ---------------------------------------------------------------------------
-- Cellular automaton
-- ---------------------------------------------------------------------------
--
-- An elementary cellular automaton scrolling upward, one new row per frame,
-- with each new row seeded from the current spectrum. Pure 1-bit: every pixel
-- is either on or off and no dithering is involved, which is why it looks
-- right on this screen in a way it would not in colour.
--
-- Rather than redrawing the whole history every frame, the previous frame's
-- image is blitted upward by one row and only the new row is drawn. That turns
-- an expensive full redraw into two image copies.
--
-- Shown as Triforce, because rule 90 draws a Sierpinski triangle and that is
-- what most people have actually seen one in.

-- How far the crank has to turn to shear the pattern by one pixel. A full
-- revolution is 360 degrees, so this works out to twelve pixels of shear per
-- turn.
local CRANK_DEGREES_PER_SHEAR_PIXEL <const> = 30

local CellularAutomaton = {
    name = "Triforce",

    -- Eight rather than four, because rule 90 draws a Sierpinski triangle and at
    -- four pixels the triangles were too fine to read as triangles.
    --
    -- This is the scroll speed as well as the cell size, because the history
    -- moves up by exactly one cell every time a row is added, and a row is added
    -- every frame. Adding rows every other frame was tried, to keep the original
    -- pace with the larger cells, and it was visibly jerky: an eight pixel jump
    -- fifteen times a second reads as a stutter no matter what the frame rate
    -- says. Smooth motion needs one step per frame, so the pattern now travels
    -- twice as fast as it used to and that is the price of the bigger triangles.
    cellSize = 8,

    ruleNumber = 30,
}

function CellularAutomaton:reset()
    self.columnCount = 400 // self.cellSize
    self.currentRow = {}

    -- Fractions of a pixel of shear left over from previous frames.
    self.unspentSidewaysShift = 0

    -- Start from a single live cell in the middle, which is the classic
    -- starting condition and produces the familiar triangular growth.
    for column = 1, self.columnCount do
        self.currentRow[column] = 0
    end
    self.currentRow[self.columnCount // 2] = 1

    -- Two images are used so the history can be scrolled by drawing one into
    -- the other at an offset, then swapping them.
    self.historyImage = graphics.image.new(400, 240, graphics.kColorWhite)
    self.scratchImage = graphics.image.new(400, 240, graphics.kColorWhite)
    self.ruleNumber = 30
end

-- Apply the rule to one cell given its three neighbours. An elementary rule is
-- a number from 0 to 255 whose bits say what each of the eight possible
-- neighbourhoods produces.
function CellularAutomaton:applyRule(leftCell, centreCell, rightCell)
    local neighbourhoodIndex = leftCell * 4 + centreCell * 2 + rightCell
    return (self.ruleNumber >> neighbourhoodIndex) & 1
end

function CellularAutomaton:draw(context)
    if not self.historyImage then
        self:reset()
    end

    local bass, mid, treble = Visualizers.bassMidTreble(context)

    -- A beat switches rule, so the texture changes character on the music.
    -- These four are the visually interesting elementary rules.
    if context.beat then
        local interestingRules = { 30, 90, 110, 150 }
        self.ruleNumber = interestingRules[math.random(#interestingRules)]
    end

    -- The crank tilts the scroll sideways, which shears the whole pattern.
    --
    -- The shear has to be a whole number of pixels, because it is an image blit
    -- offset, and the movement available in one frame is usually a fraction of
    -- one. So the fraction is carried over rather than discarded, which is what
    -- makes a slow steady turn produce a slow steady shear.
    --
    -- This was previously math.floor of the raw movement, which was broken in
    -- both directions at once. Thirty degrees inside a single frame is two and a
    -- half revolutions per second, so cranking forward at any sane speed did
    -- nothing at all. Meanwhile math.floor rounds toward negative infinity, so
    -- the smallest backward movement floored to minus one and sheared a full
    -- pixel every frame. Cranking one way did nothing and the other way ran away.
    self.unspentSidewaysShift =
        (self.unspentSidewaysShift or 0) + context.crankDelta / CRANK_DEGREES_PER_SHEAR_PIXEL

    -- Compute the next row from the current one.
    local nextRow = {}
    local columnCount = self.columnCount
    for column = 1, columnCount do
        local leftColumn = column == 1 and columnCount or column - 1
        local rightColumn = column == columnCount and 1 or column + 1
        nextRow[column] = self:applyRule(
            self.currentRow[leftColumn],
            self.currentRow[column],
            self.currentRow[rightColumn]
        )
    end

    -- Treble sprinkles fresh cells in, so a busy passage keeps injecting new
    -- structure instead of letting the pattern settle.
    local sprinkleCount = math.floor(treble * 6)
    for _ = 1, sprinkleCount do
        nextRow[math.random(columnCount)] = 1
    end

    -- Bass widens the seed at the centre, which thickens the growth.
    if bass > 0.5 then
        nextRow[columnCount // 2] = 1
    end

    self.currentRow = nextRow

    -- Scroll the history up by one cell and draw the new row at the bottom.
    --
    -- Truncate toward zero, so both directions behave the same way.
    local sidewaysShift = 0
    if self.unspentSidewaysShift >= 1 then
        sidewaysShift = math.floor(self.unspentSidewaysShift)
    elseif self.unspentSidewaysShift <= -1 then
        sidewaysShift = math.ceil(self.unspentSidewaysShift)
    end
    self.unspentSidewaysShift = self.unspentSidewaysShift - sidewaysShift

    graphics.pushContext(self.scratchImage)
        graphics.clear(graphics.kColorWhite)
        self.historyImage:draw(sidewaysShift, -self.cellSize)

        -- Draw the new row as runs of consecutive live cells rather than one
        -- rectangle per cell, which cuts the number of draw calls by roughly
        -- an order of magnitude.
        local rowTop = 240 - self.cellSize
        local runStartColumn = nil
        for column = 1, columnCount + 1 do
            local cellIsAlive = column <= columnCount and self.currentRow[column] == 1

            if cellIsAlive and not runStartColumn then
                runStartColumn = column
            elseif not cellIsAlive and runStartColumn then
                graphics.fillRect(
                    (runStartColumn - 1) * self.cellSize,
                    rowTop,
                    (column - runStartColumn) * self.cellSize,
                    self.cellSize
                )
                runStartColumn = nil
            end
        end
    graphics.popContext()

    self.historyImage, self.scratchImage = self.scratchImage, self.historyImage
    self.historyImage:draw(0, 0)
end

Visualizers.register(CellularAutomaton)


-- ---------------------------------------------------------------------------
-- Boids
-- ---------------------------------------------------------------------------
--
-- A flock following three rules: steer toward the average position of nearby
-- neighbours, steer away from ones that are too close, and match their average
-- heading. The crank steers an attractor that the flock chases, which makes
-- this the visualizer you play with rather than watch.
--
-- Shown as Koi, for how a flock of them moves in a pond.

local Boids = {
    name = "Koi",
    boidCount = 44,
    attractorAngle = 0,
}

function Boids:reset()
    self.boids = {}
    for boidNumber = 1, self.boidCount do
        self.boids[boidNumber] = {
            x = math.random(400),
            y = math.random(240),
            velocityX = math.random() * 2 - 1,
            velocityY = math.random() * 2 - 1,
        }
    end
    self.attractorAngle = 0
end

function Boids:draw(context)
    if not self.boids then
        self:reset()
    end

    local bass, mid, treble = Visualizers.bassMidTreble(context)

    -- The crank moves the attractor around an ellipse. Turning the crank walks
    -- the target around the screen and the flock follows.
    self.attractorAngle = self.attractorAngle + context.crankDelta / 200
    local attractorX = 200 + math.cos(self.attractorAngle) * 130
    local attractorY = 120 + math.sin(self.attractorAngle) * 78

    -- Bass tightens the flock, treble pushes them apart, so the shape breathes
    -- with the music.
    local cohesionStrength = 0.0016 + bass * 0.004
    local separationStrength = 0.05 + treble * 0.12
    local separationDistanceSquared = 150 + treble * 400
    local neighbourDistanceSquared = 2600

    -- A beat scatters the flock, which then re-forms.
    local scatterImpulse = context.beat and (1.6 + mid * 2.4) or 0

    local boids = self.boids
    local boidCount = #boids

    for firstIndex = 1, boidCount do
        local boid = boids[firstIndex]

        local neighbourCount = 0
        local sumX, sumY = 0, 0
        local sumVelocityX, sumVelocityY = 0, 0
        local separationX, separationY = 0, 0

        for secondIndex = 1, boidCount do
            if secondIndex ~= firstIndex then
                local other = boids[secondIndex]
                local differenceX = other.x - boid.x
                local differenceY = other.y - boid.y
                local distanceSquared = differenceX * differenceX + differenceY * differenceY

                if distanceSquared < neighbourDistanceSquared then
                    neighbourCount = neighbourCount + 1
                    sumX = sumX + other.x
                    sumY = sumY + other.y
                    sumVelocityX = sumVelocityX + other.velocityX
                    sumVelocityY = sumVelocityY + other.velocityY

                    if distanceSquared < separationDistanceSquared and distanceSquared > 0.01 then
                        separationX = separationX - differenceX / distanceSquared
                        separationY = separationY - differenceY / distanceSquared
                    end
                end
            end
        end

        if neighbourCount > 0 then
            -- Cohesion, toward the middle of the neighbours.
            boid.velocityX = boid.velocityX + (sumX / neighbourCount - boid.x) * cohesionStrength
            boid.velocityY = boid.velocityY + (sumY / neighbourCount - boid.y) * cohesionStrength

            -- Alignment, matching the neighbours' average heading.
            boid.velocityX = boid.velocityX + (sumVelocityX / neighbourCount - boid.velocityX) * 0.04
            boid.velocityY = boid.velocityY + (sumVelocityY / neighbourCount - boid.velocityY) * 0.04
        end

        -- Separation, away from anyone too close.
        boid.velocityX = boid.velocityX + separationX * separationStrength
        boid.velocityY = boid.velocityY + separationY * separationStrength

        -- Chase the attractor the crank controls.
        boid.velocityX = boid.velocityX + (attractorX - boid.x) * 0.0022
        boid.velocityY = boid.velocityY + (attractorY - boid.y) * 0.0022

        if scatterImpulse > 0 then
            boid.velocityX = boid.velocityX + (math.random() * 2 - 1) * scatterImpulse
            boid.velocityY = boid.velocityY + (math.random() * 2 - 1) * scatterImpulse
        end

        -- Cap the speed so the flock stays coherent instead of accelerating
        -- away after a scatter.
        local speed = math.sqrt(boid.velocityX * boid.velocityX + boid.velocityY * boid.velocityY)
        local maximumSpeed = 2.6 + mid * 2.2
        if speed > maximumSpeed then
            boid.velocityX = boid.velocityX / speed * maximumSpeed
            boid.velocityY = boid.velocityY / speed * maximumSpeed
        end

        boid.x = boid.x + boid.velocityX
        boid.y = boid.y + boid.velocityY

        -- Wrap at the edges, so the flock never piles up in a corner.
        if boid.x < 0 then boid.x = 400 end
        if boid.x > 400 then boid.x = 0 end
        if boid.y < 0 then boid.y = 240 end
        if boid.y > 240 then boid.y = 0 end

        -- Each boid is a short line along its heading, which reads as a
        -- direction at this size where a triangle would just be a blob.
        graphics.drawLine(
            boid.x, boid.y,
            boid.x - boid.velocityX * 2.4, boid.y - boid.velocityY * 2.4
        )
    end

    -- The attractor itself, so it is clear what the crank is doing.
    graphics.drawCircleAtPoint(attractorX, attractorY, 5)
    graphics.drawCircleAtPoint(attractorX, attractorY, 2)
end

Visualizers.register(Boids)


-- ---------------------------------------------------------------------------
-- Slime mould
-- ---------------------------------------------------------------------------
--
-- Physarum: agents that lay a trail behind them and steer toward the strongest
-- trail ahead. Three simple rules produce the branching networks the organism
-- is famous for.
--
-- Two structures are kept. A coarse grid holds the trail strength the agents
-- sense, which is what has to be cheap. A persistent image holds the visible
-- trails, which accumulate rather than being redrawn, so the network builds up
-- over time without any per frame cost for the history.

-- How the food source pulls the colony toward it.
--
-- Two mechanisms, and the important part is that they do not overlap. Each owns
-- a range and hands over to the other, because having both pull at once is what
-- made the colony stop being a colony.
--
-- Far out, a gentle bias on the heading turns an agent roughly the right way.
-- That is all it does: it is deliberately weak, because an agent that beelines
-- is an agent that is not laying an interesting trail on the way.
--
-- Near in, the bias switches off entirely and the food takes over as a mound
-- laid into the sensing grid, which agents climb with exactly the same rule they
-- use for each other's trails. Convergence on food is then emergent rather than
-- commanded, which is both how the real organism does it and what leaves room
-- for the branching to survive.
--
-- Getting this balance wrong is instructive in both directions. The bias started
-- at 0.05 as the only mechanism, which is at most 0.16 radians against a trail
-- rule that turns by 0.5 to 1.3, so food was outvoted ten to one and ignored.
-- Adding the mound and raising the bias to 0.16 overcorrected: every agent
-- beelined and then orbited, so the only thing drawn was the ellipse the food
-- travels on.
local FOOD_MOUND_RADIUS_IN_CELLS <const> = 9
local FOOD_MOUND_PEAK <const> = 1.6
local FOOD_HEADING_BIAS <const> = 0.05

-- Where the bias stops and the mound takes over. Slightly wider than the mound
-- itself, so the two overlap rather than leaving a band where neither applies.
local FOOD_BIAS_HANDOVER_DISTANCE <const> = 60

-- A small random turn on every agent every frame.
--
-- This is the piece that was missing, and weakening the food twice did not
-- replace it. Every rule in here is deterministic: sense three points, turn to
-- the strongest, repeat. Agents in the same place facing the same way therefore
-- do the same thing forever, which is why the colony kept settling into one tidy
-- shape rather than sprawling. Physarum models include a random component for
-- exactly this reason, and it is what turns a tidy shape into a branching one.
local WANDER_TURN <const> = 0.3

-- Agents that reach the middle of the mound get scattered hard instead of being
-- allowed to settle on it. Without this they arrive and stay, and 170 agents
-- sitting on one point is a blob rather than a network. Scattering them sends
-- them back out along whichever trail they happen to pick up, which is what
-- draws branches radiating from the food rather than a ring around it.
local FOOD_CORE_DISTANCE <const> = 28
local FOOD_SCATTER_TURN <const> = 2.0

local SlimeMould = {
    name = "Slime",
    agentCount = 170,
    gridColumnCount = 80,
    gridRowCount = 48,
    foodAngle = 0,
}

function SlimeMould:reset()
    self.agents = {}
    for agentNumber = 1, self.agentCount do
        -- Start spread across the screen facing outward from the middle. A
        -- tight ring was tried and left the colony a long time recovering from
        -- being a ring, which is not a shape it ever produces on its own.
        local startAngle = (agentNumber / self.agentCount) * math.pi * 2
        local startDistance = 30 + (agentNumber % 7) * 14
        self.agents[agentNumber] = {
            x = 200 + math.cos(startAngle) * startDistance,
            y = 120 + math.sin(startAngle) * startDistance * 0.6,
            heading = startAngle,
        }
    end

    self.trailGrid = {}
    for cellIndex = 1, self.gridColumnCount * self.gridRowCount do
        self.trailGrid[cellIndex] = 0
    end

    self.trailImage = graphics.image.new(400, 240, graphics.kColorWhite)
    self.foodAngle = 0
    self.framesSinceClear = 0
end

-- Sample the trail strength at a point, in screen coordinates.
function SlimeMould:senseAt(x, y)
    local column = math.floor(x / 400 * self.gridColumnCount)
    local row = math.floor(y / 240 * self.gridRowCount)
    if column < 0 or column >= self.gridColumnCount or row < 0 or row >= self.gridRowCount then
        return -1
    end
    return self.trailGrid[row * self.gridColumnCount + column + 1]
end

function SlimeMould:draw(context)
    if not self.agents then
        self:reset()
    end

    local bass, mid, treble = Visualizers.bassMidTreble(context)

    -- The crank walks a food source around, which the colony grows toward.
    self.foodAngle = self.foodAngle + context.crankDelta / 240
    local foodX = 200 + math.cos(self.foodAngle) * 120
    local foodY = 120 + math.sin(self.foodAngle) * 70

    local sensorDistance = 8 + treble * 10
    local turnAmount = 0.5 + mid * 0.8
    local moveSpeed = 1.1 + bass * 1.4

    graphics.pushContext(self.trailImage)
        for _, agent in ipairs(self.agents) do
            -- Sense ahead, to the left and to the right, then turn toward
            -- whichever direction has the strongest trail.
            local aheadStrength = self:senseAt(
                agent.x + math.cos(agent.heading) * sensorDistance,
                agent.y + math.sin(agent.heading) * sensorDistance)
            local leftStrength = self:senseAt(
                agent.x + math.cos(agent.heading - 0.6) * sensorDistance,
                agent.y + math.sin(agent.heading - 0.6) * sensorDistance)
            local rightStrength = self:senseAt(
                agent.x + math.cos(agent.heading + 0.6) * sensorDistance,
                agent.y + math.sin(agent.heading + 0.6) * sensorDistance)

            if leftStrength > aheadStrength and leftStrength > rightStrength then
                agent.heading = agent.heading - turnAmount
            elseif rightStrength > aheadStrength and rightStrength > leftStrength then
                agent.heading = agent.heading + turnAmount
            elseif aheadStrength < 0 then
                -- Facing off the edge, so turn back toward the middle.
                agent.heading = agent.heading + math.pi * 0.5
            end

            -- Turn toward the food the crank controls, but only from far enough
            -- away that there is no mound to sense yet. Inside that distance the
            -- sensing above is already steering toward it, and applying both at
            -- once is what collapsed the colony onto the food.
            local towardFoodX = foodX - agent.x
            local towardFoodY = foodY - agent.y
            local distanceToFoodSquared = towardFoodX * towardFoodX + towardFoodY * towardFoodY

            if distanceToFoodSquared
                > FOOD_BIAS_HANDOVER_DISTANCE * FOOD_BIAS_HANDOVER_DISTANCE then
                local towardFood = math.atan(towardFoodY, towardFoodX)
                local headingDifference =
                    (towardFood - agent.heading + math.pi * 3) % (math.pi * 2) - math.pi
                agent.heading = agent.heading + headingDifference * FOOD_HEADING_BIAS

            elseif distanceToFoodSquared
                < FOOD_CORE_DISTANCE * FOOD_CORE_DISTANCE then
                -- Arrived. Scatter rather than settle, so the food is somewhere
                -- the network passes through instead of somewhere it ends.
                agent.heading = agent.heading
                    + (math.random() - 0.5) * FOOD_SCATTER_TURN
            end

            -- Wander, so that two agents in the same place facing the same way
            -- do not stay identical forever.
            agent.heading = agent.heading + (math.random() - 0.5) * WANDER_TURN

            agent.x = agent.x + math.cos(agent.heading) * moveSpeed
            agent.y = agent.y + math.sin(agent.heading) * moveSpeed

            -- Wrap rather than reflect, so the network can span the screen.
            if agent.x < 0 then agent.x = 400 end
            if agent.x > 400 then agent.x = 0 end
            if agent.y < 0 then agent.y = 240 end
            if agent.y > 240 then agent.y = 0 end

            -- Deposit into the sensing grid and draw into the visible image.
            local column = math.floor(agent.x / 400 * self.gridColumnCount)
            local row = math.floor(agent.y / 240 * self.gridRowCount)
            if column >= 0 and column < self.gridColumnCount
                and row >= 0 and row < self.gridRowCount then
                local cellIndex = row * self.gridColumnCount + column + 1
                self.trailGrid[cellIndex] = math.min(1, self.trailGrid[cellIndex] + 0.35)
            end

            graphics.fillRect(agent.x, agent.y, 2, 2)
        end
    graphics.popContext()

    -- Lay the food into the sensing grid as a mound, strongest at the middle and
    -- falling off to nothing at the edge, so there is a slope for agents to
    -- climb rather than a cliff they can only find by landing on it.
    --
    -- It goes in after the agents have moved, so it is never flattened by an
    -- agent depositing on the same cell, and it is laid fresh every frame so the
    -- decay that thins out old trails does not thin this out too.
    --
    -- The peak sits above the 1.0 an agent trail is capped at, which is what
    -- makes the colony prefer food over its own path once it can smell it.
    local foodColumn = math.floor(foodX / 400 * self.gridColumnCount)
    local foodRow = math.floor(foodY / 240 * self.gridRowCount)
    local trailGrid = self.trailGrid

    for columnOffset = -FOOD_MOUND_RADIUS_IN_CELLS, FOOD_MOUND_RADIUS_IN_CELLS do
        local column = foodColumn + columnOffset
        if column >= 0 and column < self.gridColumnCount then
            for rowOffset = -FOOD_MOUND_RADIUS_IN_CELLS, FOOD_MOUND_RADIUS_IN_CELLS do
                local row = foodRow + rowOffset
                if row >= 0 and row < self.gridRowCount then
                    local distance = math.sqrt(columnOffset * columnOffset
                        + rowOffset * rowOffset)
                    if distance <= FOOD_MOUND_RADIUS_IN_CELLS then
                        local strength = FOOD_MOUND_PEAK
                            * (1 - distance / FOOD_MOUND_RADIUS_IN_CELLS)
                        local cellIndex = row * self.gridColumnCount + column + 1
                        if strength > trailGrid[cellIndex] then
                            trailGrid[cellIndex] = strength
                        end
                    end
                end
            end
        end
    end

    -- Decay the sensing grid only every third frame. Touching four thousand
    -- cells every frame is the single most expensive thing here, and the
    -- behaviour is indistinguishable at a third of the rate.
    self.framesSinceClear = self.framesSinceClear + 1
    if self.framesSinceClear % 3 == 0 then
        for cellIndex = 1, #trailGrid do
            trailGrid[cellIndex] = trailGrid[cellIndex] * 0.9
        end
    end

    -- The visible trails accumulate forever, so the image is wiped
    -- periodically. Doing it on a beat makes the reset feel musical rather
    -- than arbitrary.
    if context.beat and self.framesSinceClear > 260 then
        self.framesSinceClear = 0
        graphics.pushContext(self.trailImage)
            graphics.clear(graphics.kColorWhite)
        graphics.popContext()
    end

    self.trailImage:draw(0, 0)

    -- The food source, so the crank's effect is visible.
    graphics.drawCircleAtPoint(foodX, foodY, 6)
end

Visualizers.register(SlimeMould)
