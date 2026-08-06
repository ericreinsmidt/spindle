-- The playback state glyphs.
--
-- Drawn from primitives rather than shipped as images, so there is nothing to
-- keep in step with the code and nothing to regenerate if a size changes. They
-- are small enough that the drawing is a handful of lines each, and a 1-bit
-- screen wants hard edges anyway, which is exactly what primitives give.
--
-- Every glyph fits inside a square of GLYPH_SIZE with its top left at the point
-- passed in, so a row of them can be laid out by stepping along.
--
-- Two states deliberately have no glyph: playing in order, and repeat off. Those
-- are the normal cases, and showing nothing for normal is what makes the row
-- readable at a glance. A row with one glyph in it means one thing is unusual.

import "CoreLibs/graphics"

Glyphs = {}

local graphics <const> = playdate.graphics

Glyphs.SIZE = 20


-- Draw part of a circle as a short chain of straight lines.
--
-- The SDK has an arc call, but these are drawn at radius seven where the
-- difference is a pixel at most, and doing it here keeps the whole file
-- dependent on nothing but drawLine.
local function drawArcSegment(centreX, centreY, radius, startDegrees, endDegrees)
    local previousX, previousY

    for degrees = startDegrees, endDegrees, 10 do
        local radians = math.rad(degrees)
        local pointX = centreX + math.cos(radians) * radius
        local pointY = centreY + math.sin(radians) * radius

        if previousX then
            graphics.drawLine(previousX, previousY, pointX, pointY)
        end
        previousX, previousY = pointX, pointY
    end
end


-- A solid arrowhead with its point at the given place, aimed along an angle.
local function drawArrowHead(tipX, tipY, headingRadians, size)
    local leftAngle = headingRadians + 2.6
    local rightAngle = headingRadians - 2.6

    graphics.fillTriangle(
        tipX, tipY,
        tipX + math.cos(leftAngle) * size, tipY + math.sin(leftAngle) * size,
        tipX + math.cos(rightAngle) * size, tipY + math.sin(rightAngle) * size)
end


function Glyphs.drawPlay(left, top)
    graphics.fillTriangle(
        left + 5, top + 3,
        left + 5, top + 17,
        left + 16, top + 10)
end


function Glyphs.drawPause(left, top)
    graphics.fillRect(left + 5, top + 3, 4, 14)
    graphics.fillRect(left + 12, top + 3, 4, 14)
end


-- Two arrows crossing, which is the shuffle mark everywhere else so there is no
-- reason to invent a different one here.
--
-- Both heads sit at the right hand corners rather than at the ends of the
-- strokes. Drawn at the ends they were only ten pixels apart and merged into one
-- blob, which is the sort of thing that only shows up when you look at the glyph
-- rather than at the code.
function Glyphs.drawShuffle(left, top)
    local strokes = {
        { startX = left + 1, startY = top + 4, endX = left + 13, endY = top + 15,
          tipX = left + 15, tipY = top + 17 },
        { startX = left + 1, startY = top + 15, endX = left + 13, endY = top + 4,
          tipX = left + 15, tipY = top + 2 },
    }

    for _, stroke in ipairs(strokes) do
        graphics.drawLine(stroke.startX, stroke.startY, stroke.endX, stroke.endY)
        drawArrowHead(stroke.tipX, stroke.tipY,
            math.atan(stroke.endY - stroke.startY, stroke.endX - stroke.startX), 4)
    end
end


-- A record, used as the mark for "album" wherever a glyph needs to say that the
-- thing being shuffled is whole records rather than single tracks.
function Glyphs.drawRecord(left, top)
    local centreX = left + Glyphs.SIZE / 2
    local centreY = top + Glyphs.SIZE / 2

    graphics.drawCircleAtPoint(centreX, centreY, 8)
    graphics.fillCircleAtPoint(centreX, centreY, 2)
end


-- Two arrows chasing each other round a circle.
function Glyphs.drawRepeat(left, top)
    local centreX = left + Glyphs.SIZE / 2
    local centreY = top + Glyphs.SIZE / 2
    local radius = 7.5

    -- Two arcs with a gap at each end, so the arrowheads have somewhere to sit
    -- rather than overlapping the line they belong to.
    drawArcSegment(centreX, centreY, radius, 20, 155)
    drawArcSegment(centreX, centreY, radius, 200, 335)

    -- Each head points along the circle where its own arc ends, a quarter turn
    -- from the radius, which is what makes the pair read as going round rather
    -- than as two loose ticks.
    for _, tipDegrees in ipairs({ 155, 335 }) do
        local tipAngle = math.rad(tipDegrees)
        drawArrowHead(
            centreX + math.cos(tipAngle) * radius,
            centreY + math.sin(tipAngle) * radius,
            tipAngle + math.pi / 2, 4)
    end
end


-- The same circle with a 1 inside it, for repeating one track.
--
-- The digit is drawn by hand rather than set in the body font, because that font
-- is 18 pixels tall and would fill the ring completely.
function Glyphs.drawRepeatTrack(left, top)
    Glyphs.drawRepeat(left, top)

    local centreX = left + Glyphs.SIZE / 2
    local centreY = top + Glyphs.SIZE / 2

    -- Clear a hole for the digit first. The ring passes close enough to the
    -- middle at this size that a 1 drawn straight on top of it reads as part of
    -- the ring rather than as a number.
    graphics.setColor(graphics.kColorWhite)
    graphics.fillRect(centreX - 3, centreY - 5, 7, 11)
    graphics.setColor(graphics.kColorBlack)

    graphics.drawLine(centreX + 1, centreY - 4, centreX + 1, centreY + 4)
    graphics.drawLine(centreX - 1, centreY - 2, centreX + 1, centreY - 4)
end
