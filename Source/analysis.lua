-- Reading the precomputed analysis files.
--
-- The Playdate SDK provides no FFT, only a single amplitude level per frame,
-- so the spectrum every visualizer needs is computed on the Mac during ingest
-- and shipped alongside the audio. On the device this costs one string.byte
-- lookup per band per frame, which is why visualizers can be rich without
-- spending any real CPU.
--
-- The file format, written by tools/ingest.py, is deliberately plain so it can
-- be read with string.byte and a loop rather than depending on string.unpack:
--
--     offset 0   4 bytes   magic "SPNA"
--     offset 4   1 byte    format version
--     offset 5   1 byte    frames per second
--     offset 6   1 byte    band count
--     offset 7   1 byte    waveform point count
--     offset 8   4 bytes   frame count, big endian
--     offset 12  4 bytes   onset count, big endian
--     offset 16  ...       band bytes, frame count times band count
--     then       ...       onset frame indices, two bytes each, big endian
--     then       ...       waveform bytes, one per point

Analysis = {}

local HEADER_SIZE_IN_BYTES <const> = 16
local EXPECTED_MAGIC <const> = "SPNA"
local SUPPORTED_FORMAT_VERSION <const> = 2


-- Read a big endian unsigned integer out of a byte string. The position is one
-- based, matching how Lua indexes strings.
local function readBigEndianInteger(byteString, startPosition, byteWidth)
    local accumulatedValue = 0
    for byteOffset = 0, byteWidth - 1 do
        accumulatedValue = accumulatedValue * 256 + string.byte(byteString, startPosition + byteOffset)
    end
    return accumulatedValue
end


-- Load the analysis for one track. Returns a table on success, or nil plus a
-- short reason on failure. A missing or malformed analysis file is not fatal:
-- the player still works, visualizers simply have nothing to react to.
function Analysis.load(analysisPath)
    if not analysisPath or not playdate.file.exists(analysisPath) then
        return nil, "no analysis file"
    end

    local fileHandle = playdate.file.open(analysisPath, playdate.file.kFileRead)
    if not fileHandle then
        return nil, "could not open analysis file"
    end

    local fileSizeInBytes = playdate.file.getSize(analysisPath)
    local fileContents = fileHandle:read(fileSizeInBytes)
    fileHandle:close()

    if not fileContents or #fileContents < HEADER_SIZE_IN_BYTES then
        return nil, "analysis file is truncated"
    end

    if string.sub(fileContents, 1, 4) ~= EXPECTED_MAGIC then
        return nil, "not an analysis file"
    end

    local formatVersion = string.byte(fileContents, 5)
    if formatVersion ~= SUPPORTED_FORMAT_VERSION then
        return nil, "analysis format version " .. formatVersion .. " is not supported"
    end

    local framesPerSecond = string.byte(fileContents, 6)
    local bandCount = string.byte(fileContents, 7)
    local waveformPointCount = string.byte(fileContents, 8)
    local frameCount = readBigEndianInteger(fileContents, 9, 4)
    local onsetCount = readBigEndianInteger(fileContents, 13, 4)

    -- The band data stays as a raw string and is indexed on demand. A four
    -- minute track holds around eighty thousand band values, and unpacking
    -- that into a Lua table every time a track is selected would be wasteful
    -- when only one row of sixteen is needed per frame.
    local bandDataStartPosition = HEADER_SIZE_IN_BYTES + 1
    local bandDataLengthInBytes = frameCount * bandCount

    -- Onsets are unpacked immediately. Even a busy four minute track only has
    -- a few hundred, and visualizers want to look ahead to the next one.
    local onsetFrames = {}
    local onsetDataStartPosition = bandDataStartPosition + bandDataLengthInBytes
    for onsetIndex = 0, onsetCount - 1 do
        local position = onsetDataStartPosition + onsetIndex * 2
        if position + 1 <= #fileContents then
            table.insert(onsetFrames, readBigEndianInteger(fileContents, position, 2))
        end
    end

    -- The waveform is unpacked too, because the scrub bar draws every point on
    -- every frame and it is only a couple of hundred values.
    local waveform = {}
    local waveformStartPosition = onsetDataStartPosition + onsetCount * 2
    for pointIndex = 0, waveformPointCount - 1 do
        local position = waveformStartPosition + pointIndex
        if position <= #fileContents then
            table.insert(waveform, string.byte(fileContents, position))
        end
    end

    return {
        framesPerSecond = framesPerSecond,
        bandCount = bandCount,
        frameCount = frameCount,
        onsetFrames = onsetFrames,
        waveform = waveform,
        rawFileContents = fileContents,
        bandDataStartPosition = bandDataStartPosition,

        -- Tracks which onset was most recently passed, so isOnBeat can report
        -- a beat exactly once rather than for every frame after it.
        lastReportedOnsetIndex = 0,
    }
end


-- Return the band values for the analysis frame covering the given playback
-- position, as a table of numbers from zero to 255. Returns nil when there is
-- no analysis or the position falls outside it.
function Analysis.bandsAtPosition(analysis, positionInSeconds)
    if not analysis then
        return nil
    end

    local frameIndex = math.floor(positionInSeconds * analysis.framesPerSecond)
    if frameIndex < 0 or frameIndex >= analysis.frameCount then
        return nil
    end

    local rowStartPosition = analysis.bandDataStartPosition + frameIndex * analysis.bandCount
    local bandValues = {}
    for bandNumber = 1, analysis.bandCount do
        bandValues[bandNumber] = string.byte(analysis.rawFileContents, rowStartPosition + bandNumber - 1)
    end
    return bandValues
end


-- Report whether an onset falls at the given playback position, returning true
-- exactly once per onset. Visualizers call this every frame and use it to
-- trigger something on the beat.
--
-- Seeking backwards resets the tracking, so scrubbing back through a track
-- does not silently swallow every beat you have already passed.
function Analysis.isOnBeat(analysis, positionInSeconds)
    if not analysis or #analysis.onsetFrames == 0 then
        return false
    end

    local currentFrame = math.floor(positionInSeconds * analysis.framesPerSecond)

    -- If the playhead moved backwards, rewind the onset cursor to match.
    if analysis.lastReportedOnsetIndex > 0
        and analysis.onsetFrames[analysis.lastReportedOnsetIndex] > currentFrame then
        analysis.lastReportedOnsetIndex = 0
        for onsetIndex, onsetFrame in ipairs(analysis.onsetFrames) do
            if onsetFrame > currentFrame then
                break
            end
            analysis.lastReportedOnsetIndex = onsetIndex
        end
        return false
    end

    local nextOnsetIndex = analysis.lastReportedOnsetIndex + 1
    local nextOnsetFrame = analysis.onsetFrames[nextOnsetIndex]

    if nextOnsetFrame and currentFrame >= nextOnsetFrame then
        analysis.lastReportedOnsetIndex = nextOnsetIndex
        return true
    end

    return false
end

