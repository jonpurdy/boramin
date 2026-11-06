#!/usr/bin/env python3
"""Build/run an isolated Mac probe using production Xcode sources and dependencies."""
import argparse
import plistlib
from pathlib import Path
import shutil
import subprocess
import sys

PROBE_SOURCES = {
    'ass': 'Tests/StyledASSPlaybackProbe.swift',
    'external': 'Tests/ExternalSubtitleProbe.swift',
    'software': 'Tests/AetherSoftwarePlaybackProbe.swift',
    'native': 'Tests/MacPlaybackProbe.swift',
    'hardware': 'Tests/PlaybackProbe.swift',
    'codecs': 'Tests/MKVCodecTests.swift',
    'connections': 'Tests/ConnectionOpeningProbe.swift',
    'failure': 'Tests/PlaybackFailureProbe.swift',
    'browsing': 'Tests/SMBBrowsingServiceTests.swift',
    'cancellation': 'Tests/BrowserCancellationTests.swift',
    'deletion': 'Tests/SMBDeletionProbe.swift',
    'http': 'Tests/HTTPTransportTests.swift',
}


def generate_project(root, folder, mode):
    project = folder / 'Probe.xcodeproj'
    project.mkdir(parents=True, exist_ok=True)
    source = root / 'BoraMin.xcodeproj/project.pbxproj'
    data = plistlib.loads(subprocess.check_output(['plutil', '-convert', 'xml1', '-o', '-', str(source)]))
    for obj in data['objects'].values():
        if obj.get('isa') == 'PBXFileReference' and obj.get('sourceTree') == 'SOURCE_ROOT':
            path = obj['path']
            if path == 'MacOS/MacApp.swift':
                probe = PROBE_SOURCES[mode]
                entry = (root / probe).read_text()
                if mode in ('native', 'hardware', 'codecs', 'connections', 'failure', 'browsing', 'cancellation', 'deletion', 'http'):
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
            if mode == 'failure' and settings.get('PRODUCT_NAME') == 'BoraMin':
                settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.example.BoraMin.PlaybackFailureProbe'
    (project / 'project.pbxproj').write_bytes(plistlib.dumps(data))
    # Preserve the checked-in scheme's target identifiers and build configuration.
    schemes = project / 'xcshareddata/xcschemes'
    schemes.mkdir(parents=True, exist_ok=True)
    text = (root / 'BoraMin.xcodeproj/xcshareddata/xcschemes/BoraMin macOS.xcscheme').read_text()
    (schemes / 'BoraMin macOS.xcscheme').write_text(text.replace('container:BoraMin.xcodeproj', 'container:' + str(project)))
    return project

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--generate-only', action='store_true', help='Generate the Xcode project without building or running it')
parser.add_argument('probe', choices=PROBE_SOURCES)
parser.add_argument('fixtures', nargs='*', help='Fixture paths/arguments passed to the probe')
args = parser.parse_args()
if not args.generate_only and not args.fixtures:
    parser.error('fixture arguments are required unless --generate-only is set')

root = Path(__file__).resolve().parent.parent
folder = root / 'build/AetherSoftwareTests'
project = generate_project(root, folder, args.probe)
print(project, flush=True)
if args.generate_only:
    sys.exit(0)

log = folder / f'{args.probe}-build.log'
command = ['xcodebuild', '-project', str(project), '-scheme', 'BoraMin macOS',
           '-configuration', 'Release', '-destination', 'platform=macOS,arch=arm64',
           '-clonedSourcePackagesDirPath', str(root/'build/AetherPackages'),
           '-derivedDataPath', str(folder/'Derived'), 'build']
print(f'Building {args.probe} probe; log: {log}', flush=True)
with log.open('w') as output:
    result = subprocess.run(command, cwd=root, stdout=output, stderr=subprocess.STDOUT)
if result.returncode:
    print('\n'.join(log.read_text().splitlines()[-70:]), file=sys.stderr)
    sys.exit(result.returncode)
app = folder/'Derived/Build/Products/Release/BoraMin.app'
try:
    subprocess.run([sys.executable, str(root/'tools/verify_media_linkage.py'), str(app)], cwd=root, check=True)
    # The generated project/product is shared by modes; run sequentially.
    command = [str(app/'Contents/MacOS/BoraMin'), *args.fixtures]
    if args.probe == 'failure' and args.fixtures == ['live']:
        log = folder / 'live-playback.log'
        with log.open('w') as output:
            try:
                subprocess.run(command, cwd=root, stdout=output, stderr=subprocess.STDOUT,
                               check=True, timeout=2400)
            finally:
                print(f'Live playback results: {log}', flush=True)
                for line in log.read_text(errors='replace').splitlines():
                    if line.startswith(('PASS ', 'FAIL ', 'INCOMPLETE ')):
                        print(line, flush=True)
    else:
        subprocess.run(command, cwd=root, check=True, timeout=240)
finally:
    if args.probe == 'failure' and args.fixtures == ['live']:
        shutil.rmtree(app, ignore_errors=True)
