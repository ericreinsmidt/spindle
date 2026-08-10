#!/bin/zsh
# Build Spindle, and optionally push it to a Playdate mounted in data disk mode.
#
#   ./build.sh            compile only
#   ./build.sh sim        compile, then open in the Simulator
#   ./build.sh device     compile, mount the device over USB, and copy everything across
#   ./build.sh log        print the spike log back off the device
set -e

SDK="${PLAYDATE_SDK_PATH:-$HOME/Developer/PlaydateSDK}"
PDC="$SDK/bin/pdc"
OUT="Spindle.pdx"
BUNDLE_ID="com.reinsmidt.spindle"

cd "${0:a:h}"

[[ -x "$PDC" ]] || { echo "pdc not found at $PDC"; exit 1; }

# The two Roobert fonts belong to Panic and ship with the SDK, so they are not in
# this repository. They are copied in before every compile instead, which keeps
# them out of version control without anyone having to do anything by hand.
FONTS="$SDK/Resources/Fonts/Roobert"
mkdir -p Source/fonts
for FONT in Roobert-11-Bold Roobert-20-Medium; do
	for FILE in "$FONTS/$FONT".fnt "$FONTS/$FONT"-table-*.png; do
		[[ -f "$FILE" ]] || { echo "Missing $FILE. Is the SDK complete?"; exit 1; }
		cp "$FILE" Source/fonts/
	done
done

# The app carries its own instructions and its own conversion tool, so that a
# device with no music on it can explain itself without needing a website. pdc
# copies anything it does not recognize straight into the bundle, so these ride
# along untouched.
#
# ingest.py is copied in from tools/ rather than kept here, for the same reason
# the fonts are: one copy in the repository, no chance of the shipped tool and
# the real one drifting apart.
mkdir -p Source/docs
cp tools/ingest.py Source/docs/ingest.py

echo "building $OUT with SDK $(cat "$SDK/VERSION.txt")"
"$PDC" Source "$OUT"
echo "ok: $OUT"

case "$1" in
sim)
	open -a "$SDK/bin/Playdate Simulator.app" "$OUT"
	;;
device)
	VOL=/Volumes/PLAYDATE

	# pdutil can flip the device into data disk mode over serial, so the only
	# manual step is plugging in the USB cable.
	if [[ ! -d "$VOL" ]]; then
		# find rather than a glob, so this doesn't depend on the caller's
		# nullglob/bare-glob-qualifier settings.
		PORT=$(find /dev -maxdepth 1 -name 'cu.usbmodem*' 2>/dev/null | head -1)
		if [[ -z "$PORT" ]]; then
			echo "No Playdate found. Connect it over USB and unlock it, then rerun."
			exit 1
		fi
		echo "mounting data disk via $PORT"
		"$SDK/bin/pdutil" "$PORT" datadisk || true

		for i in {1..30}; do
			[[ -d "$VOL" ]] && break
			sleep 1
		done
		[[ -d "$VOL" ]] || { echo "Device never mounted at $VOL."; exit 1; }
	fi

	rm -rf "$VOL/Games/$OUT"
	cp -R "$OUT" "$VOL/Games/"
	mkdir -p "$VOL/Data/$BUNDLE_ID/music"

	# Seed the sample-rate test tones if the music folder is still empty.
	SEED="$SDK/Disk/Data/$BUNDLE_ID/music"
	if [[ -d "$SEED" ]] && [[ -z "$(ls -A "$VOL/Data/$BUNDLE_ID/music" 2>/dev/null)" ]]; then
		cp "$SEED"/*.mp3 "$VOL/Data/$BUNDLE_ID/music/" 2>/dev/null || true
		echo "seeded test tones into Data/$BUNDLE_ID/music/"
	fi

	# macOS leaves AppleDouble ._ files on FAT volumes; strip them.
	dot_clean -m "$VOL/Games/$OUT" 2>/dev/null || true
	dot_clean -m "$VOL/Data/$BUNDLE_ID" 2>/dev/null || true

	echo "copied to $VOL/Games/$OUT"
	echo "add your own MP3s to $VOL/Data/$BUNDLE_ID/music/"
	echo "then: diskutil eject $VOL"
	;;
log)
	# Pull the spike log back off the device.
	VOL=/Volumes/PLAYDATE
	[[ -d "$VOL" ]] || { echo "Device not mounted. Run ./build.sh device first."; exit 1; }
	cat "$VOL/Data/$BUNDLE_ID/spike-log.txt"
	;;
esac
