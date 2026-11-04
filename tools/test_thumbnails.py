#!/usr/bin/env python3
"""Synthetic, offline embedded PNG and device-local thumbnail cache regression checks."""
from pathlib import Path
import subprocess
import argparse
import tempfile
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--framework-dir', type=Path, help='Also test the built private BoraMinMedia framework')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
prefix = Path(subprocess.check_output(['brew', '--prefix', 'ffmpeg'], text=True).strip())
def run(args):
    subprocess.run([str(x) for x in args], cwd=root, check=True)
with tempfile.TemporaryDirectory(prefix='boramin-thumbnails-') as folder:
    tmp = Path(folder)
    run(['swiftc', '-parse-as-library', '-module-cache-path', root/'build/MacModuleCache',
         'Player/ThumbnailCache.swift', 'tvOS/TopShelf/TopShelfSnapshot.swift', 'Tests/ThumbnailCacheTests.swift', '-o', tmp/'cache-tests'])
    run([tmp/'cache-tests', tmp])
    video = tmp/'plain.mp4'
    run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'color=size=64x64:rate=1:duration=1', '-c:v', 'libx264', video])
    run(['ffmpeg', '-v', 'error', '-i', video, '-c', 'copy', '-attach', tmp/'illustration.png', '-attach', tmp/'cover.png',
         '-metadata:s:t:0', 'mimetype=image/png', '-metadata:s:t:1', 'mimetype=image/png', tmp/'cover.mkv'])
    run(['ffmpeg', '-v', 'error', '-i', video, '-i', tmp/'cover.png', '-map', '0:v', '-map', '1:v',
         '-c', 'copy', '-disposition:v:1', 'attached_pic', tmp/'cover.mp4'])
    (tmp/'huge.png').write_bytes((tmp/'cover.png').read_bytes() + bytes(17*1024*1024))
    run(['ffmpeg', '-v', 'error', '-i', video, '-c', 'copy', '-attach', tmp/'huge.png',
         '-metadata:s:t:0', 'mimetype=image/png', tmp/'huge.mkv'])
    run(['xcrun', '--sdk', 'macosx', 'clang', 'Player/MediaBridge.c', 'Tests/ArtworkTests.c', '-IPlayer',
         f'-I{prefix}/include', f'-L{prefix}/lib', '-lavformat', '-lavcodec', '-lavutil', '-lswresample', '-o', tmp/'artwork-tests'])
    run([tmp/'artwork-tests', tmp/'cover.png', tmp/'cover.mkv', tmp/'cover.mp4', video, tmp/'huge.mkv'])
    if args.framework_dir:
        frameworks = args.framework_dir.resolve()
        run(['xcrun', '--sdk', 'macosx', 'clang', 'Tests/ArtworkTests.c', '-IPlayer',
             f'-F{frameworks}', '-framework', 'BoraMinMedia', f'-Wl,-rpath,{frameworks}', '-o', tmp/'private-artwork-tests'])
        run([tmp/'private-artwork-tests', tmp/'cover.png', tmp/'cover.mkv', tmp/'cover.mp4', video, tmp/'huge.mkv'])
        print('PASS: artwork extraction through the production private media framework', flush=True)
