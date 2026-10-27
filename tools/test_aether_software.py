#!/usr/bin/env python3
"""Build a separate, unsigned Mac test app from the production sources; no product local-file feature."""
from pathlib import Path
import argparse
import plistlib
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--probe', choices=['software', 'ass', 'external', 'native', 'hardware', 'codecs'], default='software')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
project = root / 'build/AetherSoftwareTests/Probe.xcodeproj'
project.mkdir(parents=True, exist_ok=True)
source = root / 'BoraMin.xcodeproj/project.pbxproj'
data = plistlib.loads(subprocess.check_output(['plutil', '-convert', 'xml1', '-o', '-', str(source)]))
for obj in data['objects'].values():
    if obj.get('isa') == 'PBXFileReference' and obj.get('sourceTree') == 'SOURCE_ROOT':
        path = obj['path']
        if path == 'MacOS/MacApp.swift':
            probe = {'ass': 'Tests/StyledASSPlaybackProbe.swift', 'external': 'Tests/ExternalSubtitleProbe.swift', 'software': 'Tests/AetherSoftwarePlaybackProbe.swift', 'native': 'Tests/MacPlaybackProbe.swift', 'hardware': 'Tests/PlaybackProbe.swift', 'codecs': 'Tests/MKVCodecTests.swift'}[args.probe]
            entry = (root / probe).read_text()
            if args.probe in ('native', 'hardware', 'codecs'):
                # Browser views reference this production model, normally defined beside @main.
                model = (root / 'MacOS/MacApp.swift').read_text().split('@MainActor final class MacLibrary:', 1)[1]
                entry += '\nimport SwiftUI\n@MainActor final class MacLibrary:' + model
            generated_entry = project.parent / 'ProbeEntry.swift'
            generated_entry.write_text(entry)
            path = str(generated_entry)
        obj['path'] = str(root / path)
        obj['sourceTree'] = '<absolute>'
    if obj.get('isa') == 'XCLocalSwiftPackageReference':
        obj['relativePath'] = str(root / obj['relativePath'])
    if obj.get('isa') == 'PBXProject':
        obj['projectDirPath'] = str(root)
    if obj.get('isa') == 'XCBuildConfiguration':
        settings = obj['buildSettings']
        settings['CODE_SIGNING_ALLOWED'] = 'NO'
        settings['ENABLE_APP_SANDBOX'] = 'NO'
(project / 'project.pbxproj').write_bytes(plistlib.dumps(data))
# Preserve the checked-in scheme's target identifiers and build configuration.
schemes = project / 'xcshareddata/xcschemes'
schemes.mkdir(parents=True, exist_ok=True)
text = (root / 'BoraMin.xcodeproj/xcshareddata/xcschemes/BoraMin macOS.xcscheme').read_text()
(schemes / 'BoraMin macOS.xcscheme').write_text(text.replace('container:BoraMin.xcodeproj', 'container:' + str(project)))
print(project)
