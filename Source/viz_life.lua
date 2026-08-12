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
-- right on this screen in a way it would not in color.
--
-- Rather than redrawing the whole history every frame, the previous frame's
-- image is blitted upward by one row and only the new row is drawn. That turns
-- an expensive full redraw into two image copies.
--
-- Shown as Hojo, for the clan who ruled Japan as regents from 1203 to 1333.
-- Their crest was the mitsu-uroko, three scales: three triangles arranged in
-- a triangle, which is exactly what rule 90 draws.
--
-- It was called Triforce, which is the same shape borrowed from somewhere
-- with an owner. Nobody owns the shape. The mon predates Nintendo by six
-- centuries and a Sierpinski gasket falls out of arithmetic rather than out
-- of anyone's artwork. But they do own the word, and Hojo is both free and
-- the older name for the thing on screen.
--
-- Written without the macrons that belong on Hojo, because the font is
-- Panic's Roobert and there is no reason to think it carries them.

-- The crank is a rule dial.
--
-- It used to shear the pattern sideways, which was a poor use of it: the shear
-- was driven by how fast the crank was moving rather than where it had got to,
-- so it only existed on frames where the crank was actually turning, and the
-- leaned rows scrolled off the top about a second later. The whole effect
-- erased itself no matter how far you turned.
--
-- Turning the crank now walks through the rules below instead, reseeding on each
-- one, so you can go looking for a pattern rather than waiting for the music to
-- hand you one.
--
-- Ordered so that turning the dial moves through a character rather than
-- jumping about: the sparse gaskets first, then the solid and nested ones, then
-- the complicated and the chaotic. Rule 90 is first because it is the one the
-- visualizer is named after, and it is where the dial starts.
--
-- Every one of these was run from a single seed cell for two screens of rows
-- before being put on the dial, because most of the 256 elementary rules are
-- useless here for one of three reasons. Any odd rule turns an all-dead
-- neighborhood live, so the empty background flips on every row and the screen
-- strobes. Many die out or settle into a solid block. And several are
-- indistinguishable from each other given this starting condition: rule 18 was
-- on the dial until it turned out to draw a gasket identical to rule 90's for
-- every row that fits on the screen, which would have been a dial position that
-- appeared to do nothing.
--
-- These nine are distinct from one another, none goes blank, and all sit between
-- 15 and 42 percent ink, which is the range that reads as a pattern rather than
-- as either an empty screen or a filled one.
local DIAL_RULES <const> = { 90, 60, 22, 126, 94, 150, 54, 110, 30 }

-- A quarter turn per rule, so one full revolution moves four along and the whole
-- list is two turns end to end. The dial wraps rather than stopping, so there is
-- no dead end to crank against.
local CRANK_DEGREES_PER_RULE <const> = 90

local CellularAutomaton = {
    name = "Hojo",

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

    ruleNumber = 90,
}

-- Start over from a single live cell in the middle, which is the classic
-- starting condition and produces the familiar triangular growth.
function CellularAutomaton:seed()
    for column = 1, self.columnCount do
        self.currentRow[column] = 0
    end
    self.currentRow[self.columnCount // 2] = 1
    self.rowsSinceSeed = 0
end

function CellularAutomaton:reset()
    self.columnCount = 400 // self.cellSize
    self.currentRow = {}
    self:seed()

    -- Where the dial has been turned to, in degrees, and which rule that works
    -- out to. Both start at rule 90 so the namesake is what you get on arrival.
    self.dialDegrees = 0
    self.dialIndex = 1
    self.ruleNumber = DIAL_RULES[1]

    -- Set once the dial has actually been moved a whole step. Until then the
    -- music picks the rules, and afterward it stops picking them.
    self.crankHasTakenOver = false

    -- Two images are used so the history can be scrolled by drawing one into
    -- the other at an offset, then swapping them.
    self.historyImage = graphics.image.new(400, 240, graphics.kColorWhite)
    self.scratchImage = graphics.image.new(400, 240, graphics.kColorWhite)
end

-- Apply the rule to one cell given its three neighbors. An elementary rule is
-- a number from 0 to 255 whose bits say what each of the eight possible
-- neighborhoods produces.
function CellularAutomaton:applyRule(leftCell, centerCell, rightCell)
    local neighborhoodIndex = leftCell * 4 + centerCell * 2 + rightCell
    return (self.ruleNumber >> neighborhoodIndex) & 1
end

function CellularAutomaton:draw(context)
    if not self.historyImage then
        self:reset()
    end

    local bass, mid, treble = Visualizers.bassMidTreble(context)

    -- The pattern is restarted from a single cell rather than run forever, and
    -- the rule is only changed at that moment.
    --
    -- It used to switch rule on every beat, which is why the Sierpinski triangle
    -- the thing is named after was almost never visible. A gasket takes a full
    -- screen of rows to draw itself, about thirty frames, and any rule change
    -- part way through replaces it with something else. On most music the rule
    -- changed several times a second, so what you saw was the noise four rules
    -- make when interleaved, with the triangle appearing only in the gap after a
    -- reset.
    --
    -- Now a run is left alone until it has had time to draw a whole screen, and
    -- then the next beat starts a fresh one from a single cell. The triangle
    -- grows from its apex, fills the screen, and is replaced by another.
    self.rowsSinceSeed = (self.rowsSinceSeed or 0) + 1

    local screenIsFull = self.rowsSinceSeed >= (240 // self.cellSize)
    if screenIsFull and context.beat then
        -- The beat always starts a fresh run, but it only chooses the rule while
        -- the dial is untouched. Once the crank has been used, picking a rule
        -- out of the music would throw away the one just chosen by hand, so the
        -- beat is left doing the thing that is still wanted: regrowing the
        -- triangle from its apex in time with the track.
        if not self.crankHasTakenOver then
            -- Rule 90 is the one that draws the triangle, so it comes up half
            -- the time rather than a quarter. The other three are here for
            -- variety and all produce something worth looking at on their own.
            local rules = { 90, 90, 30, 110, 150 }
            self.ruleNumber = rules[math.random(#rules)]
        end

        self:seed()
    end

    -- The rule dial.
    --
    -- The dial reads accumulated crank position rather than this frame's
    -- movement, so where you have turned it to is what decides the rule and it
    -- stays there when you let go. Degrees are kept unrounded and the step is
    -- taken from the total, which means a slow turn crosses each boundary once
    -- rather than a fraction of a step being lost every frame.
    --
    -- The modulo wraps the dial, and Lua's modulo takes the sign of its divisor,
    -- so cranking backward past the first rule lands on the last one rather than
    -- on a negative index.
    self.dialDegrees = self.dialDegrees + context.crankDelta

    local dialIndex =
        math.floor(self.dialDegrees / CRANK_DEGREES_PER_RULE) % #DIAL_RULES + 1

    if dialIndex ~= self.dialIndex then
        self.dialIndex = dialIndex
        self.ruleNumber = DIAL_RULES[dialIndex]

        -- A whole step of the dial is what counts as taking over, not any
        -- movement at all, so brushing the crank does not silently stop the
        -- music choosing rules.
        self.crankHasTakenOver = true

        -- Start the new rule from a single cell. Changing rule part way through
        -- a run replaces whatever was being drawn with something else, which is
        -- what made the triangle so rarely visible when the beat was doing the
        -- changing. Reseeding means the dial always shows a rule from its apex.
        self:seed()
    end

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

    -- Treble sprinkles fresh cells in, but only once the triangle has finished
    -- drawing itself.
    --
    -- A single stray cell anywhere in a rule 90 field starts its own cone of
    -- pattern, which grows until it collides with the real one and destroys it.
    -- Six of them a frame is why the screen turned to noise within a second of
    -- every reset. Held back until the gasket is complete, they add texture to
    -- something that has already been seen rather than preventing it being seen
    -- at all.
    if screenIsFull then
        local sprinkleCount = math.floor(treble * 4)
        for _ = 1, sprinkleCount do
            nextRow[math.random(columnCount)] = 1
        end
    end

    -- Bass widens the seed at the center, once the figure is drawn, for the
    -- same reason.
    if screenIsFull and bass > 0.5 then
        nextRow[columnCount // 2] = 1
    end

    self.currentRow = nextRow

    -- Scroll the history up by one cell and draw the new row at the bottom.
    graphics.pushContext(self.scratchImage)
        graphics.clear(graphics.kColorWhite)
        self.historyImage:draw(0, -self.cellSize)

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
-- neighbors, steer away from ones that are too close, and match their average
-- heading. The crank steers an attractor that the flock chases, which makes
-- this the visualizer you play with rather than watch.
--
-- Shown as Koi, for how a flock of them moves in a pond.

-- How close a boid gets to the attractor before it stops being pulled in and
-- starts being pushed out.
--
-- Without this every boid ends up sitting on the attractor. The pull is
-- proportional to distance, so it never lets go, and the flock collapses into a
-- knot about eighty pixels across with the rest of the screen empty. That is not
-- a flock, it is a pile.
--
-- Real flocking around a point is an orbit, not a collision, so inside this
-- radius the pull reverses. A boid that arrives is pushed back out, overshoots,
-- is pulled in again, and the result is a ring that circulates and breathes
-- instead of a dot. The same fix Slime needed for its food source.
-- The push is matched to the pull rather than picked freely. The pull is
-- proportional to distance, so at the orbit boundary it is radius times
-- KOI_PULL. Making the push at the middle about the same size means the two
-- balance into an orbit; making it much larger, which the first attempt did by a
-- factor of sixty, fires the flock off the screen instead.
local KOI_ORBIT_RADIUS <const> = 95
local KOI_PULL <const> = 0.0022
local KOI_PUSH <const> = KOI_ORBIT_RADIUS * KOI_PULL


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
    --
    -- The separation distance is what decides how much of the screen the flock
    -- occupies, and it was far too small. At twelve to twenty three pixels,
    -- forty four boids sit in a blob about eighty pixels across whatever else is
    -- happening, which is why this looked like a knot rather than a flock. It
    -- covered under five percent of the screen. Simulating the loop offline and
    -- measuring showed the separation radius is the only lever that moves that
    -- number: the attractor, the cohesion and the orbit all barely touch it.
    --
    -- Forty two to fifty two pixels puts the flock across a little under half the
    -- screen, which is spread out and still plainly one flock. The strength went
    -- up with it because the force falls off as one over distance squared, so a
    -- setting tuned for twelve pixels is nearly nothing at forty.
    local cohesionStrength = 0.0008 + bass * 0.0018
    local separationStrength = 1.1 + treble * 0.9
    local separationDistanceSquared = 1800 + treble * 900

    -- Wider than the separation distance, so alignment and cohesion still act
    -- across boids that separation is pushing apart. Under it, the flock cannot
    -- hold together at all.
    local neighborDistanceSquared = 9000

    -- A beat scatters the flock, which then re-forms.
    local scatterImpulse = context.beat and (1.6 + mid * 2.4) or 0

    local boids = self.boids
    local boidCount = #boids

    for firstIndex = 1, boidCount do
        local boid = boids[firstIndex]

        local neighborCount = 0
        local sumX, sumY = 0, 0
        local sumVelocityX, sumVelocityY = 0, 0
        local separationX, separationY = 0, 0

        for secondIndex = 1, boidCount do
            if secondIndex ~= firstIndex then
                local other = boids[secondIndex]
                local differenceX = other.x - boid.x
                local differenceY = other.y - boid.y
                local distanceSquared = differenceX * differenceX + differenceY * differenceY

                if distanceSquared < neighborDistanceSquared then
                    neighborCount = neighborCount + 1
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

        if neighborCount > 0 then
            -- Cohesion, toward the middle of the neighbors.
            boid.velocityX = boid.velocityX + (sumX / neighborCount - boid.x) * cohesionStrength
            boid.velocityY = boid.velocityY + (sumY / neighborCount - boid.y) * cohesionStrength

            -- Alignment, matching the neighbors' average heading.
            boid.velocityX = boid.velocityX + (sumVelocityX / neighborCount - boid.velocityX) * 0.04
            boid.velocityY = boid.velocityY + (sumVelocityY / neighborCount - boid.velocityY) * 0.04
        end

        -- Separation, away from anyone too close.
        boid.velocityX = boid.velocityX + separationX * separationStrength
        boid.velocityY = boid.velocityY + separationY * separationStrength

        -- Chase the attractor the crank controls, but orbit it rather than land
        -- on it. Outside the orbit radius it pulls, inside it pushes.
        local toAttractorX = attractorX - boid.x
        local toAttractorY = attractorY - boid.y
        local attractorDistance =
            math.sqrt(toAttractorX * toAttractorX + toAttractorY * toAttractorY)

        if attractorDistance > KOI_ORBIT_RADIUS then
            boid.velocityX = boid.velocityX + toAttractorX * KOI_PULL
            boid.velocityY = boid.velocityY + toAttractorY * KOI_PULL
        elseif attractorDistance > 1 then
            -- Strongest right at the middle and easing off toward the radius, so
            -- the boundary is somewhere to settle rather than a wall to bounce
            -- against.
            local howFarInside = 1 - attractorDistance / KOI_ORBIT_RADIUS
            boid.velocityX = boid.velocityX
                - toAttractorX / attractorDistance * KOI_PUSH * howFarInside
            boid.velocityY = boid.velocityY
                - toAttractorY / attractorDistance * KOI_PUSH * howFarInside
        end

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
-- Slime mold
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

local SlimeMold = {
    name = "Slime",
    agentCount = 170,
    gridColumnCount = 80,
    gridRowCount = 48,
    foodAngle = 0,
}

function SlimeMold:reset()
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
function SlimeMold:senseAt(x, y)
    local column = math.floor(x / 400 * self.gridColumnCount)
    local row = math.floor(y / 240 * self.gridRowCount)
    if column < 0 or column >= self.gridColumnCount or row < 0 or row >= self.gridRowCount then
        return -1
    end
    return self.trailGrid[row * self.gridColumnCount + column + 1]
end

function SlimeMold:draw(context)
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
    -- behavior is indistinguishable at a third of the rate.
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

Visualizers.register(SlimeMold)
