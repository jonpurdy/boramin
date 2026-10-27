#!/usr/bin/env python3
"""Generate a local-only MKV with styled/animated ASS, SRT and an attached font."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent.parent
out = root/'build/ASSTests'
out.mkdir(parents=True, exist_ok=True)
font = Path('/System/Library/Fonts/Supplemental/Arial.ttf')
if not font.exists():
    raise SystemExit('Pass a Mac with the Arial system test font installed. Font is not bundled in the app.')
(out/'styled.ass').write_text(r'''[Script Info]
ScriptType: v4.00+
PlayResX: 640
PlayResY: 360
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,28,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,1,0,7,10,10,10,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:00:16.00,Default,,0,0,0,,{\an7\pos(40,30)\c&H0000FF&}Red positioned text
Dialogue: 0,0:00:00.00,0:00:16.00,Default,,0,0,0,,{\an7\pos(40,85)\c&H00FF00&\fnArial}Green embedded font
Dialogue: 0,0:00:00.00,0:00:16.00,Default,,0,0,0,,{\an7\move(40,165,400,165,0,14000)\t(0,14000,\fs40)}Animated text
''')
(out/'plain.srt').write_text('1\n00:00:00,000 --> 00:00:16,000\nPlain subtitle track\n')
subprocess.run(['ffmpeg','-v','error','-y','-f','lavfi','-i','testsrc2=size=640x360:rate=30','-f','lavfi','-i','sine=frequency=440:sample_rate=48000','-i',str(out/'styled.ass'),'-i',str(out/'plain.srt'),'-t','18','-map','0:v','-map','1:a','-map','2:s','-map','3:s','-c:v','libx264','-preset','fast','-g','30','-c:a','aac','-c:s','copy','-metadata:s:s:0','language=eng','-metadata:s:s:0','title=Styled ASS','-metadata:s:s:1','language=eng','-metadata:s:s:1','title=Plain SRT','-attach',str(font),'-metadata:s:t','mimetype=application/x-truetype-font','-metadata:s:t','filename=embedded-test-font.ttf',str(out/'styled.mkv')],check=True)
print(out/'styled.mkv')
