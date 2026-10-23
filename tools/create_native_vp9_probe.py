#!/usr/bin/env python3
"""Generate an isolated native AVPlayer probe project; fixtures live under build/."""
from pathlib import Path
import hashlib
import plistlib
import argparse
import subprocess

root = Path(__file__).resolve().parent.parent
folder = root / 'build/NativeVP9Probe'
project = folder / 'NativeVP9Probe.xcodeproj'
project.mkdir(parents=True, exist_ok=True)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--make-fixtures', action='store_true', help='Remux local VP9 HDR fixture MKV without re-encoding video')
args = parser.parse_args()
if args.make_fixtures:
    source = next((root.parent/'atv vp9-av1 testing').glob('Real 4K*.mkv'))
    fixtures = folder/'fixtures'
    fixtures.mkdir(exist_ok=True)
    variants = [
        ('vp9.mkv', ['-map','0:v:0','-map','0:a:0','-c','copy']),
        ('vp9.webm', ['-map','0:v:0','-an','-c:v','copy']),
        ('vp9.mp4', ['-map','0:v:0','-map','0:a:0','-c','copy','-movflags','+faststart']),
        ('vp9-video.mp4', ['-map','0:v:0','-an','-c:v','copy','-movflags','+faststart']),
        ('vp9-fragmented.mp4', ['-map','0:v:0','-map','0:a:0','-c','copy','-movflags','+frag_keyframe+empty_moov+default_base_moof'])]
    for name, options in variants:
        subprocess.run(['ffmpeg','-v','error','-y','-i',str(source),'-t','4',*options,str(fixtures/name)],check=True)
    subprocess.run(['ffmpeg','-v','error','-y','-i',str(source),'-t','24','-map','0:v:0','-map','0:a:0','-c','copy','-movflags','+faststart',str(fixtures/'vp9-long.mp4')],check=True)
    subprocess.run(['ffmpeg','-v','error','-y','-f','lavfi','-i','testsrc2=size=640x360:rate=30','-f','lavfi','-i','sine=frequency=440:sample_rate=48000','-t','4','-c:v','libx264','-preset','ultrafast','-c:a','aac','-movflags','+faststart',str(fixtures/'control.mp4')],check=True)
(folder/'ProbeInfo.plist').write_bytes(plistlib.dumps({'NSAppTransportSecurity': {'NSAllowsLocalNetworking': True}}))
# Streamed compatibility fixtures: compressed video/audio copied without re-encoding.
# HEVC is optional because the user's movie is not distributed with this project.
if args.make_fixtures:
    controls = [('vp9', source, []), ('control', fixtures/'control.mp4', [])]
    hevc = root/'build/MKVFixtures/hevc-hdr.mkv'
    if hevc.exists(): controls.append(('hevc', hevc, ['-tag:v', 'hvc1']))
    for name, media, extra in controls:
        destination = fixtures/'hls'/name
        destination.mkdir(parents=True, exist_ok=True)
        subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', str(media), '-t', '12',
                        '-map', '0:v:0', '-map', '0:a:0', '-c', 'copy', *extra,
                        '-f', 'hls', '-hls_time', '2', '-hls_segment_type', 'fmp4',
                        '-hls_playlist_type', 'vod', '-hls_segment_filename', str(destination/'segment%d.m4s'),
                        '-master_pl_name', 'master.m3u8', str(destination/'index.m3u8')], check=True)
objects = {}
def ident(key): return hashlib.sha256(key.encode()).hexdigest()[:24].upper()
def obj(key, isa, **values):
    objects[ident(key)] = dict(isa=isa, **values)
    return ident(key)
source = obj('source', 'PBXFileReference', lastKnownFileType='sourcecode.swift', path=str(root/'Tests/NativeVP9Probe.swift'), sourceTree='<absolute>')
sourcebuild = obj('source-build', 'PBXBuildFile', fileRef=source)
resources = []
refs = [source]
for file in sorted((folder/'fixtures').iterdir()):
    ref = obj(file.name, 'PBXFileReference', lastKnownFileType='folder' if file.is_dir() else 'file', path=str(file), sourceTree='<absolute>')
    refs.append(ref)
    resources.append(obj('build-'+file.name, 'PBXBuildFile', fileRef=ref))
app = obj('app', 'PBXFileReference', explicitFileType='wrapper.application', path='NativeVP9Probe.app', sourceTree='BUILT_PRODUCTS_DIR')
products = obj('products', 'PBXGroup', children=[app], sourceTree='<group>')
main = obj('main', 'PBXGroup', children=refs+[products], sourceTree='<group>')
sources = obj('sources', 'PBXSourcesBuildPhase', buildActionMask=2147483647, files=[sourcebuild], runOnlyForDeploymentPostprocessing=0)
resourcephase = obj('resources', 'PBXResourcesBuildPhase', buildActionMask=2147483647, files=resources, runOnlyForDeploymentPostprocessing=0)
frameworks = obj('frameworks', 'PBXFrameworksBuildPhase', buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
target = obj('target', 'PBXNativeTarget', buildConfigurationList=ident('target-configs'), buildPhases=[sources,frameworks,resourcephase], buildRules=[], dependencies=[], name='NativeVP9Probe', productName='NativeVP9Probe', productReference=app, productType='com.apple.product-type.application')
for kind in ['target','project']:
    settings = dict(SWIFT_VERSION='5.0', SDKROOT='iphoneos', IPHONEOS_DEPLOYMENT_TARGET='26.2', TVOS_DEPLOYMENT_TARGET='26.2', CLANG_ENABLE_MODULES='YES', SWIFT_OPTIMIZATION_LEVEL='-O')
    if kind == 'target':
        settings.update(PRODUCT_NAME='$(TARGET_NAME)', PRODUCT_BUNDLE_IDENTIFIER='com.example.BoraMin.NativeVP9Probe', DEVELOPMENT_TEAM='EXAMPLE000', CODE_SIGN_STYLE='Automatic', GENERATE_INFOPLIST_FILE='YES', INFOPLIST_KEY_UILaunchScreen_Generation='YES', INFOPLIST_KEY_UIApplicationSceneManifest_Generation='YES', TARGETED_DEVICE_FAMILY='1,2', SUPPORTED_PLATFORMS='iphoneos appletvos', MARKETING_VERSION='0.1', CURRENT_PROJECT_VERSION='1')
        settings['TARGETED_DEVICE_FAMILY[sdk=appletvos*]']='3'
        settings['INFOPLIST_FILE'] = str(folder/'ProbeInfo.plist')
    config = obj(kind+'release', 'XCBuildConfiguration', buildSettings=settings, name='Release')
    obj(kind+'-configs', 'XCConfigurationList', buildConfigurations=[config], defaultConfigurationIsVisible=0, defaultConfigurationName='Release')
projectid = obj('project', 'PBXProject', attributes={'LastUpgradeCheck':'2630'}, buildConfigurationList=ident('project-configs'), compatibilityVersion='Xcode 14.0', developmentRegion='en', knownRegions=['en','Base'], mainGroup=main, productRefGroup=products, projectDirPath='', projectRoot='', targets=[target])
(project/'project.pbxproj').write_bytes(plistlib.dumps(dict(archiveVersion='1', classes={}, objectVersion='56', objects=objects, rootObject=projectid)))
schemes = project/'xcshareddata/xcschemes'
schemes.mkdir(parents=True,exist_ok=True)
ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="NativeVP9Probe.app" BlueprintName="NativeVP9Probe" ReferencedContainer="container:NativeVP9Probe.xcodeproj"/>'
(schemes/'NativeVP9Probe.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2630" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForRunning="YES" buildForTesting="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction buildConfiguration="Release" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction></Scheme>''')
print(project)
