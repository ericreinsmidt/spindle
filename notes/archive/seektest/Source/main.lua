-- Minimal, isolated characterisation of playdate.sound.fileplayer:setOffset().
--
-- No library scan, no watchdog, no reload-on-divergence, no crank, no UI state.
-- Two files, a handful of strategies, and a fixed sampling schedule. It runs
-- start to finish on its own; just launch it and wait about two minutes.
--
-- Context: the dev forum reports that setOffset() does not account for the
-- fileplayer's internal buffer, and that offsets smaller than the buffer
-- produce a garbage getOffset() (a poster saw 24345; this project saw
-- 24347.79 and 97391.09) followed by the player dying. The compensation
-- suggested there is: setOffset(target + bufferSize).
--
-- Separately, Panic acknowledged getLength()/getOffset() being wrong for MP3
-- ("counting samples instead of pairs"), fixed for sampleplayer in 1.12.2 but
-- apparently never for MP3 fileplayers.

import "CoreLibs/graphics"

local gfx <const> = playdate.graphics
local snd <const> = playdate.sound

local LOG_PATH <const> = "seektest-log.txt"
local TARGET <const> = 30.0 -- seconds; well past any plausible buffer
local SETTLE_BEFORE_SEEK <const> = 3.0
local SAMPLE_AT <const> = { 0, 1, 2, 3, 5, 8 } -- seconds after the seek

-- file, bufferSize (nil = SDK default), compensate for buffer in the target
local TRIALS <const> = {
	{ file = "music/tone-44k.mp3", buffer = nil, compensate = false },
	{ file = "music/tone-44k.mp3", buffer = 2.0, compensate = false },
	{ file = "music/tone-44k.mp3", buffer = 2.0, compensate = true },
	{ file = "music/tone-44k.mp3", buffer = 0.25, compensate = false },
	{ file = "music/real.mp3", buffer = nil, compensate = false },
	{ file = "music/real.mp3", buffer = 2.0, compensate = true },
}

local logBuffer = {}

local function flushLog()
	if #logBuffer == 0 then return end
	local f = playdate.file.open(LOG_PATH, playdate.file.kFileAppend)
	if f then
		f:write(table.concat(logBuffer))
		f:close()
	end
	logBuffer = {}
end

local function log(fmt, ...)
	local line = select("#", ...) > 0 and string.format(fmt, ...) or fmt
	print(line)
	logBuffer[#logBuffer + 1] = line .. "\n"
	flushLog() -- this test is short; correctness beats efficiency
end

--------------------------------------------------------------------------------

-- Listen mode. The automated trials proved the *reported* numbers are garbage
-- but that the player keeps playing. Numbers cannot tell us whether the audio
-- actually moved - only ears can. So: play a real track, jump to a known
-- position on demand, and let the listener judge.
local LISTEN_FILE <const> = "music/real.mp3"
local LISTEN_TARGET <const> = 30.0

local listenMode = true
local listenPlayer = nil
local listenSeekedAt = nil

local trialIndex = 0
local trial, player = nil, nil
local baseLength, askedFor = 0, 0
local stage = "next"
local stageStart = 0
local nextSample = 1
local status = "starting"

local function now()
	return playdate.getCurrentTimeMilliseconds() / 1000
end

local function startTrial()
	trialIndex = trialIndex + 1
	if trialIndex > #TRIALS then
		log("=== all trials complete ===")
		status = "DONE - pull the log"
		stage = "done"
		return
	end

	trial = TRIALS[trialIndex]
	if player then player:stop() end

	local p, err = snd.fileplayer.new(trial.file)
	if not p then
		log("trial %d: LOAD FAILED %s (%s)", trialIndex, trial.file, tostring(err))
		stage = "next"
		return
	end

	player = p
	if trial.buffer then player:setBufferSize(trial.buffer) end
	baseLength = player:getLength() or 0

	log("--- trial %d: %s | buffer %s | compensate %s | length %.2f",
		trialIndex, trial.file, tostring(trial.buffer), tostring(trial.compensate), baseLength)

	player:play(1)
	stage = "settling"
	stageStart = now()
	status = string.format("trial %d/%d: settling", trialIndex, #TRIALS)
end

local function applySeek()
	askedFor = TARGET
	if trial.compensate then
		askedFor = TARGET + (trial.buffer or 0)
	end

	local before = player:getOffset() or -1
	player:setOffset(askedFor)
	log("trial %d: seek | target %.2f | asked %.2f | offset %.2f -> %.2f | length %.2f",
		trialIndex, TARGET, askedFor, before, player:getOffset() or -1, player:getLength() or -1)

	stage = "sampling"
	stageStart = now()
	nextSample = 1
	status = string.format("trial %d/%d: sampling", trialIndex, #TRIALS)
end

local function sample(elapsed)
	local offset = player:getOffset() or -1
	local length = player:getLength() or -1
	log("trial %d:   t+%ds offset %.2f length %.2f (base %.2f) %s",
		trialIndex, elapsed, offset, length, baseLength,
		player:isPlaying() and "playing" or "STOPPED")
end

local function finishTrial()
	local offset = player:getOffset() or -1
	local length = player:getLength() or -1

	-- A seek held if the file length is intact and the playhead is at or past
	-- where we aimed, having advanced by roughly the sampling window.
	local lengthOk = math.abs(length - baseLength) < 1.0
	local offsetOk = offset >= TARGET - 2.0

	log("trial %d: RESULT length %s, offset %s (length %.2f vs %.2f, offset %.2f vs target %.2f)",
		trialIndex,
		lengthOk and "HELD" or "COLLAPSED",
		offsetOk and "HELD" or "LOST",
		length, baseLength, offset, TARGET)

	stage = "next"
end

--------------------------------------------------------------------------------

playdate.display.setRefreshRate(20) -- nothing here needs a fast frame rate
playdate.setAutoLockDisabled(true)
gfx.setBackgroundColor(gfx.kColorWhite)

log("=== seektest start, SDK target %.1fs, %d trials ===", TARGET, #TRIALS)

-- A: restart from the beginning. B: jump to LISTEN_TARGET.
-- The only question that matters: does what you hear jump forward?
local function updateListenMode()
	if playdate.buttonJustPressed(playdate.kButtonA) then
		if listenPlayer then listenPlayer:stop() end
		listenPlayer = snd.fileplayer.new(LISTEN_FILE)
		if listenPlayer then
			listenPlayer:play(1)
			listenSeekedAt = nil
			log("LISTEN: restarted from 0")
		end
	end

	if playdate.buttonJustPressed(playdate.kButtonB) and listenPlayer then
		listenPlayer:setOffset(LISTEN_TARGET)
		listenSeekedAt = playdate.getSecondsSinceEpoch()
		log("LISTEN: asked for %.1fs | reported offset %.2f length %.2f",
			LISTEN_TARGET, listenPlayer:getOffset() or -1, listenPlayer:getLength() or -1)
	end

	gfx.clear()
	gfx.drawText("*Listen Test*", 4, 4)
	gfx.drawText("A = play from 0", 4, 28)
	gfx.drawText(string.format("B = jump to %.0fs", LISTEN_TARGET), 4, 48)

	if listenPlayer then
		gfx.drawText(string.format("reported: offset %.2f  length %.2f",
			listenPlayer:getOffset() or -1, listenPlayer:getLength() or -1), 4, 80)
		gfx.drawText(listenPlayer:isPlaying() and "playing" or "STOPPED", 4, 100)

		-- Our own playhead estimate, ignoring the broken getters entirely.
		if listenSeekedAt then
			local ours = LISTEN_TARGET + (playdate.getSecondsSinceEpoch() - listenSeekedAt)
			gfx.drawText(string.format("our estimate: %.1fs", ours), 4, 120)
		end
	else
		gfx.drawText("press A to start", 4, 80)
	end

	gfx.drawText("Does the AUDIO jump? Trust ears, not numbers.", 4, 216)
end

function playdate.update()
	if listenMode then
		updateListenMode()
		return
	end

	if stage == "next" then
		startTrial()
	elseif stage == "settling" then
		if now() - stageStart >= SETTLE_BEFORE_SEEK then applySeek() end
	elseif stage == "sampling" then
		local elapsed = now() - stageStart
		if nextSample <= #SAMPLE_AT and elapsed >= SAMPLE_AT[nextSample] then
			sample(SAMPLE_AT[nextSample])
			nextSample = nextSample + 1
			if nextSample > #SAMPLE_AT then finishTrial() end
		end
	end

	gfx.clear()
	gfx.drawText("*Seek Test*", 4, 4)
	gfx.drawText(status, 4, 24)
	if trial then
		gfx.drawText(trial.file, 4, 44)
		gfx.drawText(string.format("buffer %s  compensate %s",
			tostring(trial.buffer), tostring(trial.compensate)), 4, 64)
	end
	if player then
		gfx.drawText(string.format("offset %.2f  length %.2f  (base %.2f)",
			player:getOffset() or -1, player:getLength() or -1, baseLength), 4, 88)
	end
	gfx.drawText("runs unattended - wait for DONE", 4, 216)
end
