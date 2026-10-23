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
SDK=$(xcrun --sdk macosx --show-sdk-path)
xcrun clang -target arm64-apple-macos15.0 -isysroot "$SDK" -Ivendor/ffmpeg-macos/include -c Player/MediaBridge.c -o build/macOS-tests/MediaBridge.o
swift build --package-path vendor/AMSMB2 -c release
swiftc -O -target arm64-apple-macos15.0 -sdk "$SDK" -module-cache-path build/MacModuleCache \
  -import-objc-header Player/Player-Bridging-Header.h \
  -I vendor/AMSMB2/.build/arm64-apple-macosx/release/Modules \
  -I vendor/AMSMB2/Dependencies/libsmb2/include -Xcc -Ivendor/AMSMB2/Dependencies/libsmb2/lib \
  Player/Playback.swift Player/PlaybackPositions.swift Player/Streaming.swift Player/StreamingAudioLoader.swift MacOS/MacPlayback.swift \
  Tests/MacPlaybackProbe.swift build/macOS-tests/MediaBridge.o \
  vendor/AMSMB2/.build/arm64-apple-macosx/release/libAMSMB2.a \
  -Lvendor/ffmpeg-macos/lib -lavformat -lavcodec -lavutil -lswresample \
  -framework AudioToolbox -framework VideoToolbox -framework AVKit -lz -lbz2 -liconv -o build/macOS-tests/MacPlaybackProbe
build/macOS-tests/MacPlaybackProbe "$PWD/build/NativeTrackTests/native-tracks.mp4" "$PWD/build/MKVFixtures/h264-bframes.mkv"
