#!/bin/zsh
# Build and deploy the isolated seek characterisation test.
#
#   ./build.sh            compile only
#   ./build.sh sim        compile, then open in the Simulator
#   ./build.sh device     compile, then copy to a mounted PLAYDATE volume
#   ./build.sh log        print the test log back off the device
set -e

SDK="${PLAYDATE_SDK_PATH:-$HOME/Developer/PlaydateSDK}"
OUT="SeekTest.pdx"
BUNDLE_ID="com.example.seektest"
VOL=/Volumes/PLAYDATE

cd "${0:a:h}"

case "$1" in
log)
	[[ -d "$VOL" ]] || { echo "Device not mounted."; exit 1; }
	cat "$VOL/Data/$BUNDLE_ID/seektest-log.txt"
	exit 0
	;;
esac

"$SDK/bin/pdc" Source "$OUT"
echo "ok: $OUT"

case "$1" in
sim)
	open -a "$SDK/bin/Playdate Simulator.app" "$OUT"
	;;
device)
	if [[ ! -d "$VOL" ]]; then
		PORT=$(find /dev -maxdepth 1 -name 'cu.usbmodem*' 2>/dev/null | head -1)
		[[ -n "$PORT" ]] || { echo "No Playdate found. Connect it over USB."; exit 1; }
		"$SDK/bin/pdutil" "$PORT" datadisk || true
		for i in {1..30}; do [[ -d "$VOL" ]] && break; sleep 1; done
		[[ -d "$VOL" ]] || { echo "Device never mounted."; exit 1; }
	fi

	rm -rf "$VOL/Games/$OUT"
	cp -R "$OUT" "$VOL/Games/"
	mkdir -p "$VOL/Data/$BUNDLE_ID/music"

	SEED="$SDK/Disk/Data/$BUNDLE_ID/music"
	[[ -d "$SEED" ]] && cp "$SEED"/*.mp3 "$VOL/Data/$BUNDLE_ID/music/" 2>/dev/null || true

	rm -f "$VOL/Data/$BUNDLE_ID/seektest-log.txt"
	dot_clean -m "$VOL/Games/$OUT" 2>/dev/null || true
	dot_clean -m "$VOL/Data/$BUNDLE_ID" 2>/dev/null || true

	echo "copied to $VOL/Games/$OUT (log cleared)"
	echo "then: diskutil eject $VOL"
	;;
esac
