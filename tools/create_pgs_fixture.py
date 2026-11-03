#!/usr/bin/env python3
"""Generate a synthetic native-video MKV with embedded PGS and SRT subtitles."""
from pathlib import Path
import struct
import subprocess

root = Path(__file__).resolve().parent.parent
folder = root / 'build/ASSTests'
folder.mkdir(parents=True, exist_ok=True)

def segment(seconds, kind, body):
    return b'PG' + struct.pack('>IIBH', int(seconds * 90000), 0, kind, len(body)) + body

def composition(seconds, number, visible):
    body = struct.pack('>HHBHBBBB', 640, 360, 0x10, number, 0x80, 0, 0, int(visible))
    if visible:
        body += struct.pack('>HBBHH', 0, 0, 0, 290, 300)
    return segment(seconds, 0x16, body)

# An opaque white 60x20 caption rectangle on a 640x360 canvas. Each row
# is one palette-index run plus end-of-line, using the PGS segment layout.
rle = bytes([0, 0x80 | 60, 1, 0, 0]) * 20
objects = b'\0\0\0\xc0' + (len(rle) + 4).to_bytes(3, 'big') + struct.pack('>HH', 60, 20) + rle
palette = bytes([0, 0, 0, 16, 128, 128, 0, 1, 235, 128, 128, 255])
window = bytes([1, 0]) + struct.pack('>HHHH', 290, 300, 60, 20)
sup = bytearray()
for seconds, number in [(1, 1), (7, 3)]:
    sup += composition(seconds, number, True)
    sup += segment(seconds, 0x17, window)
    sup += segment(seconds, 0x14, palette)
    sup += segment(seconds, 0x15, objects)
    sup += segment(seconds, 0x80, b'')
    sup += composition(seconds + 4, number + 1, False) + segment(seconds + 4, 0x80, b'')
(folder / 'pgs.sup').write_bytes(sup)
(folder / 'pgs-plain.srt').write_text('1\n00:00:01,000 --> 00:00:11,000\nNative text control\n')
subprocess.run(['ffmpeg', '-v', 'error', '-y', '-f', 'lavfi', '-i', 'color=black:size=640x360:rate=24',
                '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
                '-i', str(folder / 'pgs.sup'), '-i', str(folder / 'pgs-plain.srt'), '-t', '12',
                '-map', '0:v', '-map', '1:a', '-map', '2:s', '-map', '3:s',
                '-c:v', 'libx264', '-preset', 'fast', '-g', '24', '-c:a', 'aac', '-c:s', 'copy',
                '-metadata:s:s:0', 'language=eng', '-metadata:s:s:0', 'title=Bitmap PGS',
                '-metadata:s:s:1', 'language=eng', '-metadata:s:s:1', 'title=Plain SRT',
                str(folder / 'pgs.mkv')], check=True)
print(folder / 'pgs.mkv')
