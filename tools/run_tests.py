#!/usr/bin/env python3
"""Run Mac demux/audio and hardware controls against the adjacent lab fixture."""
from pathlib import Path
import hashlib, os, struct, subprocess, tempfile
root = Path(__file__).resolve().parent.parent
lab = root.parent/'atv vp9-av1 testing'
prefix = Path(subprocess.check_output(['brew','--prefix','ffmpeg'],text=True).strip())
def run(args): subprocess.run([str(x) for x in args],cwd=root,check=True)
run(['swift','build','--package-path',root/'vendor/AMSMB2','-c','release'])
with tempfile.TemporaryDirectory(prefix='boramin-tests-') as tmp:
    tmp=Path(tmp)
    run(['swiftc','Player/PlaybackPositions.swift','Tests/PlaybackPositionsTests.swift','-o',tmp/'position-tests'])
    run([tmp/'position-tests'])
    run(['swiftc','Player/Favorites.swift','Tests/FavoritesTests.swift','-o',tmp/'favorites-tests'])
    run([tmp/'favorites-tests'])
    run(['swiftc','Player/ConnectionPreferences.swift','Tests/ConnectionPreferencesTests.swift','-o',tmp/'connection-tests'])
    run([tmp/'connection-tests'])
    run(['swiftc','-parse-as-library','Player/ConnectionPreferences.swift','Player/Favorites.swift','Player/PlaybackPositions.swift','Shared/ICloudSync.swift','Tests/CloudSyncSchedulingTests.swift','-o',tmp/'cloud-scheduling-tests'])
    run([tmp/'cloud-scheduling-tests'])
    source=lab/'fixtures/middle.webm'
    audio=tmp/'audio.webm'; caf=tmp/'audio.caf'; packets=tmp/'packets.bin'
    run(['ffmpeg','-v','error','-f','lavfi','-i','color=size=64x64:rate=24:duration=2',
        '-f','lavfi','-i','sine=frequency=440:sample_rate=44100:duration=2','-c:v','libvpx-vp9','-c:a','libopus',audio])
    flags=[f'-I{prefix}/include',f'-L{prefix}/lib','-lavformat','-lavcodec','-lavutil','-lswresample']
    run(['xcrun','--sdk','macosx','clang','Player/MediaBridge.c','Tests/BridgeTests.c','-IPlayer',*flags,'-o',tmp/'bridge-tests'])
    run([tmp/'bridge-tests',source,audio,caf,packets])
    ivf=(lab/'fixtures/ready/sample.ivf').read_bytes(); offset=32; payload=bytearray()
    while offset<len(ivf):
        size=struct.unpack_from('<I',ivf,offset)[0];offset+=12
        payload.extend(ivf[offset:offset+size]);offset+=size
    assert hashlib.sha256(payload).digest()==hashlib.sha256(packets.read_bytes()).digest()
    print('PASS: original VP9 payloads match the lab IVF byte-for-byte',flush=True)
    actual=tmp/'actual.pcm'; reference=tmp/'reference.pcm'
    run(['ffmpeg','-v','error','-i',caf,'-f','s16le',actual])
    run(['ffmpeg','-v','error','-i',audio,'-map','0:a:0','-ar','48000','-ac','2','-f','s16le',reference])
    a=actual.read_bytes();b=reference.read_bytes()
    assert a[:len(b)]==b and not any(a[len(b):])
    print('PASS: Opus audio matches FFmpeg PCM exactly, padded to video duration',flush=True)
    run(['xcrun','--sdk','macosx','clang','Player/MediaBridge.c','Tests/StreamingTests.c','-IPlayer',*flags,'-o',tmp/'stream-tests'])
    run([tmp/'stream-tests',source,audio,caf])
    run(['xcrun','--sdk','macosx','clang','Player/MediaBridge.c','Tests/KeyframeTests.c','-IPlayer',*flags,'-o',tmp/'keyframe-tests'])
    run([tmp/'keyframe-tests',next(lab.glob('Real 4K*.mkv'))])
    run(['xcrun','--sdk','macosx','clang','-c','Player/MediaBridge.c',f'-I{prefix}/include','-o',tmp/'bridge.o'])
    run(['swiftc','-O','-module-cache-path',root/'build/MacModuleCache','-import-objc-header','Player/Player-Bridging-Header.h',
        '-I',root/'vendor/AMSMB2/.build/arm64-apple-macosx/release/Modules',
        '-I',root/'vendor/AMSMB2/Dependencies/libsmb2/include','-Xcc',f'-I{root}/vendor/AMSMB2/Dependencies/libsmb2/lib',
        'Player/Playback.swift','Player/Streaming.swift','Player/StreamingAudioLoader.swift','Tests/PlaybackProbe.swift',tmp/'bridge.o',
        root/'vendor/AMSMB2/.build/arm64-apple-macosx/release/libAMSMB2.a',*flags,'-o',tmp/'playback-probe'])
    run([tmp/'playback-probe',source,caf])
    h264 = tmp/'h264-bframes.mkv'; hevc = tmp/'hevc-main10.mkv'
    for output, codec, extra in [(h264, 'libx264', ['-preset','fast','-bf','3']),
                                  (hevc, 'libx265', ['-pix_fmt','yuv420p10le','-x265-params','log-level=error:pools=2:bframes=4'])]:
        run(['ffmpeg','-v','error','-f','lavfi','-i','testsrc2=size=320x180:rate=24','-t','8',
             '-c:v',codec,*extra,'-g','48',output])
    run(['swiftc','-O','-module-cache-path',root/'build/MacModuleCache','-import-objc-header','Player/Player-Bridging-Header.h',
        '-I',root/'vendor/AMSMB2/.build/arm64-apple-macosx/release/Modules',
        '-I',root/'vendor/AMSMB2/Dependencies/libsmb2/include','-Xcc',f'-I{root}/vendor/AMSMB2/Dependencies/libsmb2/lib',
        'Player/Playback.swift','Player/Streaming.swift','Player/StreamingAudioLoader.swift','Tests/MKVCodecTests.swift',tmp/'bridge.o',
        root/'vendor/AMSMB2/.build/arm64-apple-macosx/release/libAMSMB2.a',*flags,'-o',tmp/'mkv-codec-tests'])
    run([tmp/'mkv-codec-tests',h264,hevc])
