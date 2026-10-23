#!/usr/bin/env python3
"""Generate an ignored MP4 fixture for AVKit's built-in audio/subtitle controls."""
from pathlib import Path
import subprocess
root = Path(__file__).resolve().parent.parent
folder = root/'build/NativeTrackTests'
folder.mkdir(parents=True, exist_ok=True)
for language, text in [('eng', 'English subtitles — rendered by AVPlayer'),
                       ('fra', 'Sous-titres français — AVPlayer')]:
    (folder/f'{language}.srt').write_text(
        f'1\n00:00:00,500 --> 00:00:15,000\n{text}\n\n'
        f'2\n00:00:15,100 --> 00:01:59,000\n{text}\n')
subprocess.run(['ffmpeg', '-v', 'error', '-y',
    '-f', 'lavfi', '-i', 'testsrc2=size=960x540:rate=30',
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
    '-f', 'lavfi', '-i', 'sine=frequency=880:sample_rate=48000',
    '-i', str(folder/'eng.srt'), '-i', str(folder/'fra.srt'), '-t', '120',
    '-map', '0:v', '-map', '1:a', '-map', '2:a', '-map', '3:s', '-map', '4:s',
    '-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '32', '-g', '60',
    '-c:a', 'aac', '-b:a', '96k', '-c:s', 'mov_text',
    '-metadata:s:a:0', 'language=eng', '-metadata:s:a:1', 'language=fra',
    '-metadata:s:s:0', 'language=eng', '-metadata:s:s:1', 'language=fra',
    '-disposition:a:0', 'default', '-disposition:a:1', '0',
    '-disposition:s:0', '0', '-disposition:s:1', '0',
    '-movflags', '+faststart', str(folder/'native-tracks.mp4')], check=True)
print(folder/'native-tracks.mp4')
