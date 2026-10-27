#!/bin/sh
# Run after building the Mac app and generating the native-tracks fixture.
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/macOS-tests build/MKVFixtures
if [ ! -f build/NativeTrackTests/native-tracks.mp4 ]; then
  python3 tools/create_native_tracks_fixture.py
fi
if [ ! -f build/MKVFixtures/h264-bframes.mkv ]; then
  ffmpeg -v error -f lavfi -i 'testsrc2=size=640x360:rate=24' \
    -f lavfi -i 'sine=frequency=440:sample_rate=48000' -t 12 \
    -c:v libx264 -preset fast -bf 3 -g 48 -c:a aac build/MKVFixtures/h264-bframes.mkv
fi
python3 tools/run_playback_probe.py native \
  "$PWD/build/NativeTrackTests/native-tracks.mp4" \
  "$PWD/build/MKVFixtures/h264-bframes.mkv"
