-- The playback state glyphs.
--
-- Every glyph is a bitmap with each pixel placed by hand, not a shape assembled
-- from drawing calls.
--
-- The first version was built from fillTriangle, drawCircleAtPoint and arcs
-- approximated with ten degree line segments, and it looked ragged for a reason
-- that is worth writing down: on a 1-bit screen with no antialiasing, a rotated
-- triangle or a stepped arc lands wherever the rasterizer decides, and the
-- result is stray single pixels and edges that wobble. Nothing about the code
-- was wrong. The approach was.
--
-- Placing pixels deliberately fixes it, and the shapes were chosen to suit a
-- pixel grid rather than being drawn at any angle that came up. Diagonals run at
-- 45 degrees, where every step is one pixel across and one down and the line
-- reads straight. Arrowheads on those diagonals are solid right triangles, which
-- is how an arrow is drawn on a grid without stray pixels. The two heads on the
-- repeat ring point straight across rather than along the curve, so the gaps in
-- the ring were put top and bottom to suit them.
--
-- The bitmaps were designed and reviewed at nine times magnification before
-- being brought over. They are turned into images once at load, so drawing one
-- is a blit.
--
-- Two states deliberately have no glyph: playing in order, and repeat off. Those
-- are the normal cases, and showing nothing for normal is what makes the row
-- readable at a glance. A row with one glyph in it means one thing is unusual.

import "CoreLibs/graphics"

Glyphs = {}

local graphics <const> = playdate.graphics

Glyphs.SIZE = 21


local playPixels <const> = {
    ".....................",
    ".....................",
    ".....................",
    ".....X...............",
    ".....XX..............",
    ".....XXX.............",
    ".....XXXX............",
    ".....XXXXX...........",
    ".....XXXXXX..........",
    ".....XXXXXXX.........",
    ".....XXXXXXXX........",
    ".....XXXXXXX.........",
    ".....XXXXXX..........",
    ".....XXXXX...........",
    ".....XXXX............",
    ".....XXX.............",
    ".....XX..............",
    ".....X...............",
    ".....................",
    ".....................",
    ".....................",
}

local pausePixels <const> = {
    ".....................",
    ".....................",
    ".....................",
    ".....XXXX...XXXX.....",
    ".....XXXX...XXXX.....",
    ".....XXXX...XXXX.....",
    ".....XXXX...XXXX.....",
    ".....XXXX...XXXX.....",
    ".....XXXX...XXXX.....",
    ".....XXXX...XXXX.....",
    ".....XXXX...XXXX.....",
    ".....XXXX...XXXX.....",
    ".....XXXX...XXXX.....",
    ".....XXXX...XXXX.....",
    ".....XXXX...XXXX.....",
    ".....XXXX...XXXX.....",
    ".....XXXX...XXXX.....",
    ".....XXXX...XXXX.....",
    ".....................",
    ".....................",
    ".....................",
}

local shufflePixels <const> = {
    ".....................",
    ".............XXXXX...",
    "..............XXXX...",
    ".XX............XXX...",
    "..XX..........XXXX...",
    "...XX........XX..X...",
    "....XX......XX.......",
    ".....XX....XX........",
    "......XX..XX.........",
    ".......XXXX..........",
    "........XX...........",
    ".......XXXX..........",
    "......XX..XX.........",
    ".....XX....XX........",
    "....XX......XX.......",
    "...XX........XX..X...",
    "..XX..........XXXX...",
    ".XX............XXX...",
    "..............XXXX...",
    ".............XXXXX...",
    ".....................",
}

local recordPixels <const> = {
    ".....................",
    "........XXXXX........",
    "......XXXXXXXXX......",
    "....XXXX.....XXXX....",
    "...X.X.........X.X...",
    "...XX...........XX...",
    "..XX.............XX..",
    "..XX.............XX..",
    ".XX......XXX......XX.",
    ".XX.....XXXXX.....XX.",
    ".XX.....XXXXX.....XX.",
    ".XX.....XXXXX.....XX.",
    ".XX......XXX......XX.",
    "..XX.............XX..",
    "..XX.............XX..",
    "...XX...........XX...",
    "...X.X.........X.X...",
    "....XXXX.....XXXX....",
    "......XXXXXXXXX......",
    "........XXXXX........",
    ".....................",
}

local repeatAllPixels <const> = {
    ".....................",
    "............X........",
    "........X...XX.......",
    "......XXX...XXX......",
    ".....XXX....XXXX.....",
    "....XX......XXXXX....",
    "...XX.......XX..XX...",
    "...XX.......X...XX...",
    "..XX.............XX..",
    "..XX.............XX..",
    "..XX.............XX..",
    "..XX.............XX..",
    "..XX.............XX..",
    "...XX...X.......XX...",
    "...XX..XX.......XX...",
    "....XXXXX......XX....",
    ".....XXXX....XXX.....",
    "......XXX...XXX......",
    ".......XX...X........",
    "........X............",
    ".....................",
}

local repeatTrackPixels <const> = {
    ".....................",
    "............X........",
    "........X...XX.......",
    "......XXX...XXX......",
    ".....XXX....XXXX.....",
    "....XX......XXXXX....",
    "...XX...........XX...",
    "...XX...........XX...",
    "..XX.....XX......XX..",
    "..XX....XXX......XX..",
    "..XX.....XX......XX..",
    "..XX.....XX......XX..",
    "..XX.....XX......XX..",
    "...XX...XXXX....XX...",
    "...XX...........XX...",
    "....XXXXX......XX....",
    ".....XXXX....XXX.....",
    "......XXX...XXX......",
    ".......XX...X........",
    "........X............",
    ".....................",
}

-- Turn a bitmap into an image once, so drawing one later is a single blit rather
-- than four hundred and forty one decisions.
--
-- The image starts clear rather than white, so a glyph sits on whatever is
-- behind it instead of carrying a square of background around with it.
local function imageFromPixels(pixelRows)
    local image = graphics.image.new(Glyphs.SIZE, Glyphs.SIZE, graphics.kColorClear)

    graphics.pushContext(image)
        graphics.setColor(graphics.kColorBlack)
        for rowNumber, row in ipairs(pixelRows) do
            for columnNumber = 1, #row do
                if string.sub(row, columnNumber, columnNumber) == "X" then
                    graphics.fillRect(columnNumber - 1, rowNumber - 1, 1, 1)
                end
            end
        end
    graphics.popContext()

    return image
end


local playImage <const> = imageFromPixels(playPixels)
local pauseImage <const> = imageFromPixels(pausePixels)
local shuffleImage <const> = imageFromPixels(shufflePixels)
local recordImage <const> = imageFromPixels(recordPixels)
local repeatAllImage <const> = imageFromPixels(repeatAllPixels)
local repeatTrackImage <const> = imageFromPixels(repeatTrackPixels)


function Glyphs.drawPlay(left, top) playImage:draw(left, top) end
function Glyphs.drawPause(left, top) pauseImage:draw(left, top) end
function Glyphs.drawShuffle(left, top) shuffleImage:draw(left, top) end
function Glyphs.drawRecord(left, top) recordImage:draw(left, top) end
function Glyphs.drawRepeat(left, top) repeatAllImage:draw(left, top) end
function Glyphs.drawRepeatTrack(left, top) repeatTrackImage:draw(left, top) end
