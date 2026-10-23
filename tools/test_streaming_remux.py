#!/usr/bin/env python3
"""Verify independent VP9/AAC fragments, original payloads/timestamps and size limits."""
from pathlib import Path
import json
import subprocess
import tempfile
root = Path(__file__).resolve().parent.parent
source = next((root.parent/'atv vp9-av1 testing').glob('Real 4K*.mkv'))
prefix = subprocess.check_output(['brew', '--prefix', 'ffmpeg'], text=True).strip()
def run(args, **kwargs): return subprocess.run([str(x) for x in args], check=True, cwd=root, **kwargs)
def packets(path, stream):
    return json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', stream,
        '-show_packets', '-show_data_hash', 'sha256', '-show_entries', 'packet=pts_time,data_hash',
        '-of', 'json', str(path)]))['packets']
with tempfile.TemporaryDirectory(prefix='boramin-remux-tests-') as temporary:
    temporary = Path(temporary)
    run(['xcrun', '--sdk', 'macosx', 'clang', 'Player/MediaBridge.c', 'Tests/RemuxTests.c',
        '-IPlayer', f'-I{prefix}/include', f'-L{prefix}/lib', '-lavformat', '-lavcodec', '-lavutil',
        '-lswresample', '-o', temporary/'tests'])
    run([temporary/'tests', source, temporary])
    for stream in ['v:0', 'a:0']:
        original, remuxed = packets(source, stream), packets(temporary/'stream.mp4', stream)
        assert [p['data_hash'] for p in original] == [p['data_hash'] for p in remuxed], stream
        error = max(abs(float(a['pts_time']) - float(b['pts_time'])) for a,b in zip(original,remuxed))
        assert error <= 1/44100 + 0.000001, (stream, error)
        print(f'PASS {stream}: {len(original)} identical compressed packets; maximum PTS error {error:.6f}s', flush=True)
