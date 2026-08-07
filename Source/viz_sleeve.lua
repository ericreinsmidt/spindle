-- Sleeve: the album cover at full height, torn apart by its own spectrum.
--
-- The cover is cut into one horizontal strip per analysis band and each strip
-- is pushed sideways by how loud its band is. Bass moves the bottom of the
-- picture, treble the top, and neighboring strips are pushed in opposite
-- directions so a loud passage shreds the cover into interleaved ribbons rather
-- than wobbling it as one piece.
--
-- The crank sets how far that push can go. Wind it all the way down and the
-- strips line up into the cover, sitting still and readable, which is the one
-- place in the app that shows artwork at any size. Wind it up and there is
-- nothing left of the picture but texture. Every position in between is the
-- interesting part, where the cover is still recognizable and visibly being
-- pulled apart by what you are listening to.
--
-- Strips wrap around the screen instead of sliding off it, so nothing is lost
-- at the extremes and the whole thing reads as a picture on a cylinder.
--
-- Cost is one image draw per strip, plus one more for each strip currently
-- straddling an edge. Sixteen to thirty two blits a frame, which is affordable
-- on a device bound by how much ink reaches the screen: the strips are the same
-- pixels the cover always was, just not where they started.

import "visualizers"
import "artwork"
import "library"

local graphics <const> = playdate.graphics


-- How much of the crank's travel it takes to open the shear all the way. Three
-- degrees per pixel puts a full turn at 120 pixels, so the whole range is a
-- little under two turns: enough that setting it is a deliberate act rather
-- than something a knock of the crank undoes.
local CRANK_DEGREES_PER_SHEAR_PIXEL <const> = 3

-- The furthest a strip can be pushed from where it belongs. At 260 a strong
-- transient travels most of the screen's width, which is past the point where
-- the cover survives as a picture, and that is deliberate. The top of the range
-- should be somewhere you would not want to leave it.
local MAXIMUM_SHEAR <const> = 260

-- Where the shear sits when the visualizer is first shown. Not zero, because a
-- visualizer that does nothing at all until you touch the crank looks broken
-- rather than restrained. At 46 the cover is plainly a cover and plainly moving.
local STARTING_SHEAR <const> = 46

-- What actually pushes a strip.
--
-- Almost none of it is the plain loudness of the band. On anything mastered in
-- the last forty years every band sits high and stays there, so a push taken
-- straight from the band value is a large constant that shreds the cover and
-- then holds it shredded. What is wanted is the opposite: a picture that sits
-- there and gets torn when something happens.
--
-- So each band is compared against a slow average of itself, and it is the
-- amount by which it currently exceeds that average which does the pushing. A
-- steady passage settles back toward its own baseline and the cover reassembles,
-- a snare pulls one strip out, and a chorus arriving pulls all of them.
--
-- A quarter of the push is still plain loudness, because a picture that is
-- perfectly still between transients reads as broken rather than as calm.
local BAND_BASELINE_FOLLOW <const> = 0.02
local TRANSIENT_SCALE <const> = 3.0
local STEADY_PUSH_SHARE <const> = 0.25

-- A beat briefly widens every push at once. This is the only thing here that
-- moves the whole picture rather than one strip, and it is what gives the
-- shredding a pulse instead of a shimmer.
local BEAT_KICK_STRENGTH <const> = 0.6
local BEAT_KICK_DECAY <const> = 0.82

-- The band values arrive at twenty frames a second and are drawn at thirty, so
-- each one is held for a frame and a half and the raw numbers step visibly.
-- Easing each strip toward its target hides that. Higher is more responsive and
-- more jittery; a third of the way per frame keeps transients legible while
-- smoothing the sample rate out of the movement.
local BAND_SMOOTHING <const> = 0.35

-- The screen, which is also the wrap distance. A strip pushed off one edge is
-- drawn again this far to the side so it comes back on the other.
local SCREEN_WIDTH <const> = 400
local SCREEN_HEIGHT <const> = 240

-- The size of the adapter mark used when an album has no cover at all.
local COVER_MARK_SIZE <const> = 140


local Sleeve = {
    name = "Sleeve",

    -- The picture being cut up, and the album it was loaded for. The album is
    -- kept so that a playlist, which changes album from track to track, reloads
    -- the cover when the record underneath it changes.
    coverImage = nil,
    loadedForAlbum = nil,

    shearAmount = STARTING_SHEAR,
    beatKick = 0,
    smoothedBands = {},
    baselineBands = {},
}


-- Find the largest cover available for an album, in the order we would rather
-- have them.
--
-- The 240 pixel version is what this is built for. The 140 pixel one is the
-- fallback for a library ingested before that size existed, and it works
-- correctly because everything below measures the image rather than assuming
-- how big it is. The adapter mark is the last resort, for a record whose files
-- carried no artwork, and it means the visualizer always has something to tear.
local function loadCoverForAlbum(album)
    local fullscreenPath = Library.fullscreenArtPathForAlbum(album)
    if fullscreenPath and playdate.file.exists(fullscreenPath) then
        local fullscreenImage = graphics.image.new(fullscreenPath)
        if fullscreenImage then
            return fullscreenImage
        end
    end

    if album and album.art and playdate.file.exists(album.art) then
        local smallerImage = graphics.image.new(album.art)
        if smallerImage then
            return smallerImage
        end
    end

    return Artwork.coverMarkImage(COVER_MARK_SIZE)
end


function Sleeve:reset()
    -- The cover itself is deliberately not cleared. Leaving the visualizer and
    -- coming back should not reload an image that is almost always the same one,
    -- and the album check in draw catches it when it is not.
    self.shearAmount = STARTING_SHEAR
    self.beatKick = 0
    self.smoothedBands = {}
    self.baselineBands = {}
end


function Sleeve:draw(context)
    -- Reload only when the record has actually changed. In a playlist this
    -- fires on every track boundary, which is what makes the cover follow along
    -- rather than staying on whatever was playing when the screen opened.
    if context.album ~= self.loadedForAlbum or not self.coverImage then
        self.coverImage = loadCoverForAlbum(context.album)
        self.loadedForAlbum = context.album
    end

    local coverImage = self.coverImage
    if not coverImage then
        return
    end

    local coverWidth, coverHeight = coverImage:getSize()
    local coverLeft = (SCREEN_WIDTH - coverWidth) // 2
    local coverTop = (SCREEN_HEIGHT - coverHeight) // 2

    -- The crank opens and closes the shear, and both ends of the range mean
    -- something: zero is the cover sitting still, and the maximum is past
    -- legibility on purpose.
    self.shearAmount = self.shearAmount + context.crankDelta / CRANK_DEGREES_PER_SHEAR_PIXEL
    if self.shearAmount < 0 then
        self.shearAmount = 0
    elseif self.shearAmount > MAXIMUM_SHEAR then
        self.shearAmount = MAXIMUM_SHEAR
    end

    if context.beat then
        self.beatKick = 1
    else
        self.beatKick = self.beatKick * BEAT_KICK_DECAY
    end

    local shearThisFrame = self.shearAmount * (1 + self.beatKick * BEAT_KICK_STRENGTH)

    local stripCount = context.bandCount

    Artwork.beginDrawing()

    for stripNumber = 1, stripCount do
        -- Strip boundaries are computed from the edges rather than from a strip
        -- height, so that a cover whose height does not divide by the band count
        -- loses no rows to rounding and leaves no gap between strips.
        local sourceTop = ((stripNumber - 1) * coverHeight) // stripCount
        local sourceBottom = (stripNumber * coverHeight) // stripCount
        local sourceHeight = sourceBottom - sourceTop

        if sourceHeight > 0 then
            -- Strip one is the top of the picture and band one is the bass, so
            -- the bands are read in reverse: low frequencies push the bottom of
            -- the cover, which is where a listener expects to feel them.
            local bandNumber = stripCount + 1 - stripNumber
            local bandLevel = (context.bands[bandNumber] or 0) / 255

            -- The baseline chases the band slowly, so it reads as where this
            -- band has been sitting lately rather than where it is now.
            local baseline = self.baselineBands[stripNumber] or bandLevel
            baseline = baseline + (bandLevel - baseline) * BAND_BASELINE_FOLLOW
            self.baselineBands[stripNumber] = baseline

            local transient = (bandLevel - baseline) * TRANSIENT_SCALE
            if transient < 0 then
                transient = 0
            elseif transient > 1 then
                transient = 1
            end

            local targetPush = STEADY_PUSH_SHARE * bandLevel
                + (1 - STEADY_PUSH_SHARE) * transient

            local smoothedPush = self.smoothedBands[stripNumber] or 0
            smoothedPush = smoothedPush + (targetPush - smoothedPush) * BAND_SMOOTHING
            self.smoothedBands[stripNumber] = smoothedPush

            -- Alternating the direction is what turns a shear into a tear. With
            -- every strip pushed the same way the cover only leans; pushed
            -- against each other they interleave.
            local direction = 1
            if stripNumber % 2 == 0 then
                direction = -1
            end

            local stripLeft = coverLeft + direction * smoothedPush * shearThisFrame

            coverImage:draw(stripLeft, coverTop + sourceTop,
                graphics.kImageUnflipped,
                0, sourceTop, coverWidth, sourceHeight)

            -- Wrap whichever way this strip has run off the screen, so ink that
            -- leaves one edge arrives at the other instead of being lost. Only
            -- the side that is actually overhanging is drawn, so a strip sitting
            -- comfortably on screen still costs a single blit.
            if stripLeft + coverWidth > SCREEN_WIDTH then
                coverImage:draw(stripLeft - SCREEN_WIDTH, coverTop + sourceTop,
                    graphics.kImageUnflipped,
                    0, sourceTop, coverWidth, sourceHeight)
            elseif stripLeft < 0 then
                coverImage:draw(stripLeft + SCREEN_WIDTH, coverTop + sourceTop,
                    graphics.kImageUnflipped,
                    0, sourceTop, coverWidth, sourceHeight)
            end
        end
    end

    Artwork.endDrawing()
end


Visualizers.register(Sleeve)
