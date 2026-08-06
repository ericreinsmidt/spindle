-- The visualizer registry and the context every visualizer receives.
--
-- Visualizers are plugins rather than bespoke screens. Each one is a table with
-- a name, an optional reset function called when it becomes visible, and a draw
-- function called once per frame. Registering one makes it appear in the picker
-- with no other wiring.
--
-- Everything a visualizer reacts to was computed on the Mac during ingest and
-- read from a binary sidecar, because the Playdate SDK provides no FFT. Looking
-- up a spectrum row costs one string.byte per band, so a visualizer can be rich
-- without spending real CPU on analysis.

import "analysis"

Visualizers = {}

-- Every registered visualizer, in the order they were registered, which is the
-- order the picker steps through them.
Visualizers.registry = {}

-- A table of shared sine values, because several visualizers evaluate sine
-- thousands of times per frame across a grid and calling math.sin that often is
-- the difference between comfortable and unusable.
--
-- The table covers sin(pi * z) for z from 0 to 2, which is one full period, so
-- any argument can be folded into range with a modulo rather than a call.
local SINE_TABLE_SIZE <const> = 1024
local sineTable = {}
for tableIndex = 0, SINE_TABLE_SIZE - 1 do
    sineTable[tableIndex] = math.sin(math.pi * (tableIndex / SINE_TABLE_SIZE) * 2)
end


-- Look up sin(pi * z) for any z, folding into the table's single period.
function Visualizers.sinePi(z)
    local foldedIndex = math.floor((z % 2) * (SINE_TABLE_SIZE / 2)) % SINE_TABLE_SIZE
    return sineTable[foldedIndex]
end


function Visualizers.register(visualizer)
    table.insert(Visualizers.registry, visualizer)
end


-- Put the registry into a deliberate order.
--
-- Without this the order is an accident of which file was imported first and
-- where each register call happens to sit inside it, which makes reordering
-- mean shuffling code between files. Naming the order in one place keeps that
-- a single edit.
--
-- Anything registered but not named here is appended at the end rather than
-- dropped, so adding a visualizer and forgetting to list it still works.
function Visualizers.setOrder(orderedNames)
    local byName = {}
    for _, visualizer in ipairs(Visualizers.registry) do
        byName[visualizer.name] = visualizer
    end

    local reordered = {}
    local alreadyPlaced = {}

    for _, name in ipairs(orderedNames) do
        local visualizer = byName[name]
        if visualizer then
            table.insert(reordered, visualizer)
            alreadyPlaced[name] = true
        end
    end

    for _, visualizer in ipairs(Visualizers.registry) do
        if not alreadyPlaced[visualizer.name] then
            table.insert(reordered, visualizer)
        end
    end

    Visualizers.registry = reordered
end


function Visualizers.count()
    return #Visualizers.registry
end


function Visualizers.get(index)
    if #Visualizers.registry == 0 then
        return nil
    end
    local wrappedIndex = ((index - 1) % #Visualizers.registry) + 1
    return Visualizers.registry[wrappedIndex]
end


-- Build the per frame context. This is the only thing a visualizer sees, which
-- keeps them independent of how playback actually works.
--
-- bands holds sixteen values from zero to 255, bass first. energy is the mean
-- of those, scaled to zero through one. beat is true on exactly the frames
-- where an onset was detected. crankDelta is degrees moved since the last
-- frame, which is what makes a visualizer something you can play with rather
-- than only watch.
--
-- The crank movement is passed in rather than read here, because the screen has
-- to decide where it goes. Most visualizers get it as something to play with,
-- but one of them asks for it to be spent on scrubbing the track instead, and
-- only the screen is in a position to honour that.
function Visualizers.buildContext(analysis, positionInSeconds, lengthInSeconds,
                                  frameNumber, crankDeltaInDegrees)
    local bands = Analysis.bandsAtPosition(analysis, positionInSeconds)

    -- A visualizer should never have to check whether analysis exists, so a
    -- flat set of quiet bands stands in when there is none.
    if not bands then
        bands = {}
        for bandNumber = 1, 16 do
            bands[bandNumber] = 0
        end
    end

    local bandTotal = 0
    for _, bandValue in ipairs(bands) do
        bandTotal = bandTotal + bandValue
    end

    return {
        -- The analysis object itself, for visualizers that need more than the
        -- current frame. The scope draws the whole track's waveform from it.
        analysis = analysis,

        bands = bands,
        bandCount = #bands,
        energy = (bandTotal / #bands) / 255,
        beat = Analysis.isOnBeat(analysis, positionInSeconds),
        crankDelta = crankDeltaInDegrees or 0,
        position = positionInSeconds,
        length = lengthInSeconds,
        frame = frameNumber,
        width = 400,
        height = 240,
    }
end


-- Split the spectrum into three broad ranges, which is what most visualizers
-- actually want rather than sixteen individual bands. Each is returned scaled
-- to zero through one.
function Visualizers.bassMidTreble(context)
    local bands = context.bands
    local bandCount = context.bandCount

    local function averageOfRange(firstBand, lastBand)
        local total = 0
        local count = 0
        for bandNumber = firstBand, math.min(lastBand, bandCount) do
            total = total + bands[bandNumber]
            count = count + 1
        end
        if count == 0 then
            return 0
        end
        return (total / count) / 255
    end

    return averageOfRange(1, 4), averageOfRange(5, 10), averageOfRange(11, bandCount)
end
