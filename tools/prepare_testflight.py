#!/usr/bin/env python3
"""Archive BoraMin and optionally export a locally saved TestFlight distribution.

Uses Xcode's standard archive/export workflow. Never uploads a build or copies
CloudKit records. The CloudKit Production schema must be deployed separately.
"""
from pathlib import Path
import argparse
import plistlib
import subprocess
from app_identity import APP_BUNDLE_ID

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('platform', choices=['ios', 'tvos', 'macos'])
parser.add_argument('--export', action='store_true', help='Also export an App Store Connect distribution locally (no upload)')
parser.add_argument('--build-number', type=int, help='Optional positive build number for the archive')
args = parser.parse_args()
if args.build_number is not None and args.build_number < 1:
    parser.error('--build-number must be positive')

project, scheme, destination = {
    'ios': ('BoraMin.xcodeproj', 'BoraMin iOS', 'generic/platform=iOS'),
    'tvos': ('BoraMin.xcodeproj', 'BoraMin tvOS', 'generic/platform=tvOS'),
    'macos': ('BoraMin.xcodeproj', 'BoraMin macOS', 'generic/platform=macOS'),
}[args.platform]
output = root/'build/TestFlight'/args.platform
archive = output/'BoraMin.xcarchive'
output.mkdir(parents=True, exist_ok=True)
command = ['xcodebuild', '-project', project, '-scheme', scheme, '-configuration', 'Release',
           '-destination', destination, '-derivedDataPath', str(root/'build/TestFlight/DerivedData'/args.platform),
           '-archivePath', str(archive), '-allowProvisioningUpdates', 'archive']
if args.platform == 'macos':
    # Bundled Mac media libraries support Apple Silicon, not Intel.
    command.extend(['ARCHS=arm64', 'ONLY_ACTIVE_ARCH=YES'])
if args.build_number is not None:
    command.append(f'CURRENT_PROJECT_VERSION={args.build_number}')
subprocess.run(command, cwd=root, check=True)
info = plistlib.loads((archive/'Info.plist').read_bytes())
if info.get('ApplicationProperties', {}).get('CFBundleIdentifier') != APP_BUNDLE_ID:
    raise SystemExit('Archive has the wrong app identity; refusing to export.')
print(f'Archive: {archive}', flush=True)
if args.export:
    options = root/'Config/TestFlightExportOptions.plist'
    settings = plistlib.loads(options.read_bytes())
    if settings.get('destination') != 'export' or settings.get('iCloudContainerEnvironment') != 'Production':
        raise SystemExit('Expected a local export with Production iCloud; refusing to continue.')
    subprocess.run(['xcodebuild', '-exportArchive', '-archivePath', str(archive),
                    '-exportPath', str(output/'Export'), '-exportOptionsPlist', str(options),
                    '-allowProvisioningUpdates'], cwd=root, check=True)
    print(f'Local distribution export: {output / "Export"}', flush=True)
