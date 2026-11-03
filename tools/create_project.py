#!/usr/bin/env python3
"""Generate BoraMin's shared Xcode project with native iOS, tvOS and macOS targets."""
from pathlib import Path
from app_identity import APP_BUNDLE_ID
import argparse
import hashlib
import os
import plistlib
import re
import subprocess
from xml.sax.saxutils import escape

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--include-cloud-probe', action='store_true', help='Include the isolated iOS synthetic CloudKit regression screen')
parser.add_argument('--marketing-version', help='Set the app/framework version on every platform')
parser.add_argument('--build-number', type=int, help='Set the positive app/framework build number on every platform')
args = parser.parse_args()
if args.marketing_version is not None and not re.fullmatch(r'\d+\.\d+(?:\.\d+)?', args.marketing_version):
    parser.error('--marketing-version must contain two or three numeric components')
if args.build_number is not None and args.build_number < 1:
    parser.error('--build-number must be positive')
root = Path(__file__).resolve().parent.parent
project = root/'BoraMin.xcodeproj'
project.mkdir(exist_ok=True)
platforms = {
    'ios': dict(name='BoraMin iOS', sdk='iphoneos', folder='iOS', deployment=('IPHONEOS_DEPLOYMENT_TARGET', '26.0'), ffmpeg='ffmpeg-ios', icon='Assets/BoraMin.icon', icon_type='folder.iconcomposer.icon', icon_name='BoraMin', entitlements='iOS/BoraMin.entitlements', info='iOS/Info.plist'),
    'tvos': dict(name='BoraMin tvOS', sdk='appletvos', folder='Player', deployment=('TVOS_DEPLOYMENT_TARGET', '26.2'), ffmpeg='ffmpeg', icon='Assets/BoraMinTV.xcassets', icon_type='folder.assetcatalog', icon_name='AppIcon', entitlements='Config/BoraMin.entitlements', info='Player/Info.plist'),
    'macos': dict(name='BoraMin macOS', sdk='macosx', folder='MacOS', deployment=('MACOSX_DEPLOYMENT_TARGET', '15.0'), ffmpeg='ffmpeg-macos', icon='MacOS/Assets.xcassets', icon_type='folder.assetcatalog', icon_name='AppIcon', entitlements='MacOS/BoraMin.entitlements', info='MacOS/Info.plist'),
}
# Preserve per-platform signing and version choices, including the first migration.
previous = {}
for path, legacy_platform in [(project, 'tvos'), (root/'iOS/BoraMin.xcodeproj', 'ios'), (root/'BoraMinMac.xcodeproj', 'macos')]:
    pbx = path/'project.pbxproj'
    if not pbx.exists():
        continue
    old = plistlib.loads(subprocess.check_output(['plutil', '-convert', 'xml1', '-o', '-', str(pbx)]))
    for target in old['objects'].values():
        if target.get('isa') != 'PBXNativeTarget' or target.get('productType') != 'com.apple.product-type.application':
            continue
        platform = next((p for p, v in platforms.items() if v['name'] == target['name']), legacy_platform)
        configs = old['objects'][target['buildConfigurationList']]['buildConfigurations']
        for config_id in configs:
            config = old['objects'][config_id]
            settings = config['buildSettings']
            keys = ['DEVELOPMENT_TEAM', 'MARKETING_VERSION', 'CURRENT_PROJECT_VERSION']
            if settings.get('PRODUCT_BUNDLE_IDENTIFIER') == APP_BUNDLE_ID:
                keys += ['PROVISIONING_PROFILE_SPECIFIER']
            previous.setdefault((platform, config['name']), {k: settings[k] for k in keys if k in settings})

version_overrides = {}
if args.marketing_version is not None:
    version_overrides['MARKETING_VERSION'] = args.marketing_version
if args.build_number is not None:
    version_overrides['CURRENT_PROJECT_VERSION'] = str(args.build_number)
for settings in previous.values():
    settings.update(version_overrides)

objects = {}
def ident(key):
    return hashlib.sha256(key.encode()).hexdigest()[:24].upper()
def obj(key, isa, **values):
    objects[ident(key)] = dict(isa=isa, **values)
    return ident(key)
def file_ref(path, kind=None):
    rel = str(path.relative_to(root))
    if kind is None:
        kind = {'.swift': 'sourcecode.swift', '.c': 'sourcecode.c.c', '.h': 'sourcecode.c.h', '.plist': 'text.plist.xml', '.entitlements': 'text.plist.entitlements'}[path.suffix]
    return obj('file:'+rel, 'PBXFileReference', lastKnownFileType=kind, path=rel, sourceTree='SOURCE_ROOT')

common = sorted([*root.glob('Shared/*.swift'), *[p for p in root.glob('Player/*') if p.suffix in ('.swift', '.c', '.h') and p.name != 'BoraMinApp.swift']])
all_files = sorted(set(common + list(root.glob('iOS/*.swift')) + list(root.glob('MacOS/*.swift')) + [root/'Player/BoraMinApp.swift']))
if args.include_cloud_probe:
    all_files += [root/'Tests/CloudSyncProbe.swift', root/'Tests/CloudSyncProbeScreen.swift']
for path in all_files:
    file_ref(path)
for spec in platforms.values():
    file_ref(root/spec['icon'], spec['icon_type'])
    file_ref(root/spec['info'])
    file_ref(root/spec['entitlements'])
obj('package', 'XCLocalSwiftPackageReference', relativePath='vendor/AMSMB2')
obj('aetherpackage', 'XCLocalSwiftPackageReference', relativePath='vendor/AetherEngine')
obj('asspackage', 'XCRemoteSwiftPackageReference', repositoryURL='https://github.com/mihai8804858/swift-ass-renderer.git', requirement={'kind': 'exactVersion', 'version': '1.3.1'})
aether_license = file_ref(root/'vendor/AetherEngine/AetherEngine-LICENSE.txt', 'text')
aether_notices = file_ref(root/'vendor/AetherEngine/Notices', 'folder')
ass_notices = file_ref(root/'vendor/Subtitle-notices', 'folder')
products = []
targets = []
for platform, spec in platforms.items():
    name = spec['name']
    product = obj(platform+':app', 'PBXFileReference', explicitFileType='wrapper.application', name=name+'.app', path='BoraMin.app', sourceTree='BUILT_PRODUCTS_DIR')
    products.append(product)
    sources = common + sorted(root.glob(spec['folder']+'/*.swift')) if platform != 'tvos' else common + [root/'Player/BoraMinApp.swift']
    if platform == 'ios' and args.include_cloud_probe:
        sources += [root/'Tests/CloudSyncProbe.swift', root/'Tests/CloudSyncProbeScreen.swift']
    # Keep the legacy FFmpeg implementation private to this framework. Otherwise
    # its static symbols in the app override AetherEngine's dynamic FFmpeg.
    media_product = obj(platform+':mediaapp', 'PBXFileReference', explicitFileType='wrapper.framework', path='BoraMinMedia.framework', sourceTree='BUILT_PRODUCTS_DIR')
    products.append(media_product)
    c_builds = [obj(platform+':cbuild:'+str(p.relative_to(root)), 'PBXBuildFile', fileRef=ident('file:'+str(p.relative_to(root)))) for p in sources if p.suffix == '.c']
    obj(platform+':mediasources', 'PBXSourcesBuildPhase', buildActionMask=2147483647, files=c_builds, runOnlyForDeploymentPostprocessing=0)
    obj(platform+':mediaframeworks', 'PBXFrameworksBuildPhase', buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
    media_target = obj(platform+':mediatarget', 'PBXNativeTarget', buildConfigurationList=ident(platform+':mediaconfigs'), buildPhases=[ident(platform+':mediasources'), ident(platform+':mediaframeworks')], buildRules=[], dependencies=[], name='BoraMinMedia '+platform, productName='BoraMinMedia', productReference=media_product, productType='com.apple.product-type.framework')
    targets.append(media_target)
    media_dependency = obj(platform+':mediadependency', 'PBXTargetDependency', target=media_target)
    media_link = obj(platform+':medialink', 'PBXBuildFile', fileRef=media_product)
    media_embed = obj(platform+':mediaembed', 'PBXBuildFile', fileRef=media_product, settings={'ATTRIBUTES': ['CodeSignOnCopy', 'RemoveHeadersOnCopy']})
    obj(platform+':embed', 'PBXCopyFilesBuildPhase', buildActionMask=2147483647, dstPath='', dstSubfolderSpec=10, files=[media_embed], name='Embed Frameworks', runOnlyForDeploymentPostprocessing=0)
    builds = [obj(platform+':build:'+str(p.relative_to(root)), 'PBXBuildFile', fileRef=ident('file:'+str(p.relative_to(root)))) for p in sources if p.suffix == '.swift']
    obj(platform+':sources', 'PBXSourcesBuildPhase', buildActionMask=2147483647, files=builds, runOnlyForDeploymentPostprocessing=0)
    obj(platform+':smb', 'XCSwiftPackageProductDependency', productName='AMSMB2')
    obj(platform+':aether', 'XCSwiftPackageProductDependency', package=ident('aetherpackage'), productName='AetherEngine')
    obj(platform+':ass', 'XCSwiftPackageProductDependency', package=ident('asspackage'), productName='SwiftAssRenderer')
    ass_build = obj(platform+':assbuild', 'PBXBuildFile', productRef=ident(platform+':ass'))
    aether_build = obj(platform+':aetherbuild', 'PBXBuildFile', productRef=ident(platform+':aether'))
    smb_build = obj(platform+':smbbuild', 'PBXBuildFile', productRef=ident(platform+':smb'))
    obj(platform+':frameworks', 'PBXFrameworksBuildPhase', buildActionMask=2147483647, files=[smb_build, aether_build, ass_build, media_link], runOnlyForDeploymentPostprocessing=0)
    resources = [obj(platform+':iconbuild', 'PBXBuildFile', fileRef=ident('file:'+spec['icon']))]
    resources.append(obj(platform+':aetherlicense', 'PBXBuildFile', fileRef=aether_license))
    resources.append(obj(platform+':aethernotices', 'PBXBuildFile', fileRef=aether_notices))
    resources.append(obj(platform+':assnotices', 'PBXBuildFile', fileRef=ass_notices))
    if platform == 'tvos' and os.environ.get('BORAMIN_SMOKE_FIXTURE'):
        fixture = obj('smoke', 'PBXFileReference', lastKnownFileType='file', path=str(Path(os.environ['BORAMIN_SMOKE_FIXTURE']).resolve()), sourceTree='<absolute>')
        resources.append(obj('smokebuild', 'PBXBuildFile', fileRef=fixture))
    obj(platform+':resources', 'PBXResourcesBuildPhase', buildActionMask=2147483647, files=resources, runOnlyForDeploymentPostprocessing=0)
    targets.append(obj(platform+':target', 'PBXNativeTarget', buildConfigurationList=ident(platform+':configs'), buildPhases=[ident(platform+':'+phase) for phase in ('sources', 'frameworks', 'resources', 'embed')], buildRules=[], dependencies=[media_dependency], name=name, productName='BoraMin', productReference=product, productType='com.apple.product-type.application', packageProductDependencies=[ident(platform+':smb'), ident(platform+':aether'), ident(platform+':ass')]))
    for config in ('Debug', 'Release'):
        settings = dict(SDKROOT=spec['sdk'], SUPPORTED_PLATFORMS=spec['sdk'], PRODUCT_NAME='BoraMin', PRODUCT_MODULE_NAME='BoraMin_'+platform, PRODUCT_BUNDLE_IDENTIFIER=APP_BUNDLE_ID, DEVELOPMENT_TEAM='EXAMPLE000', CODE_SIGN_STYLE='Automatic', CODE_SIGN_ENTITLEMENTS=spec['entitlements'], GENERATE_INFOPLIST_FILE='YES', INFOPLIST_FILE=spec['info'], MARKETING_VERSION='0.5.2', CURRENT_PROJECT_VERSION='7', ASSETCATALOG_COMPILER_APPICON_NAME=spec['icon_name'], SWIFT_OBJC_BRIDGING_HEADER='Player/Player-Bridging-Header.h', HEADER_SEARCH_PATHS=['$(SRCROOT)/vendor/'+spec['ffmpeg']+'/include'], LIBRARY_SEARCH_PATHS=['$(SRCROOT)/vendor/'+spec['ffmpeg']+'/lib'], OTHER_LDFLAGS=['-lavformat', '-lavcodec', '-lswresample', '-lavutil', '-framework', 'AudioToolbox', '-framework', 'CoreMedia', '-framework', 'VideoToolbox', '-lz', '-lbz2', '-liconv'])
        settings[spec['deployment'][0]] = spec['deployment'][1]
        if platform == 'tvos':
            settings['SUPPORTED_PLATFORMS'] = 'appletvos appletvsimulator'
            settings['HEADER_SEARCH_PATHS[sdk=appletvsimulator*]'] = ['$(SRCROOT)/vendor/ffmpeg-tvos-simulator/include']
            settings['LIBRARY_SEARCH_PATHS[sdk=appletvsimulator*]'] = ['$(SRCROOT)/vendor/ffmpeg-tvos-simulator/lib']
            settings['ARCHS[sdk=appletvsimulator*]'] = 'arm64'

        settings.update(previous.get((platform, config), {}))
        media_settings = dict(settings)
        media_settings.update(PRODUCT_NAME='BoraMinMedia', PRODUCT_MODULE_NAME='BoraMinMedia', PRODUCT_BUNDLE_IDENTIFIER=APP_BUNDLE_ID+'.media', DEFINES_MODULE='NO', SKIP_INSTALL='YES', EXPORTED_SYMBOLS_FILE='$(SRCROOT)/Config/MediaBridge.exports', INSTALL_PATH='$(LOCAL_LIBRARY_DIR)/Frameworks', DYLIB_INSTALL_NAME_BASE='@rpath')
        for key in ('SWIFT_OBJC_BRIDGING_HEADER', 'CODE_SIGN_ENTITLEMENTS', 'INFOPLIST_FILE', 'ASSETCATALOG_COMPILER_APPICON_NAME', 'PROVISIONING_PROFILE_SPECIFIER'):
            media_settings.pop(key, None)
        if platform == 'macos':
            media_settings.update(ARCHS='arm64', ENABLE_HARDENED_RUNTIME='YES')
        obj(platform+':media'+config, 'XCBuildConfiguration', buildSettings=media_settings, name=config)
        settings['OTHER_LDFLAGS'] = ['-framework', 'AudioToolbox', '-framework', 'CoreMedia', '-framework', 'VideoToolbox', '-lz', '-lbz2', '-liconv']
        settings['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks']

        if platform == 'macos':
            settings.update(ARCHS='arm64', COMBINE_HIDPI_IMAGES='YES', LD_RUNPATH_SEARCH_PATHS=['$(inherited)', '@executable_path/../Frameworks'], ENABLE_HARDENED_RUNTIME='YES')
        else:
            settings['TARGETED_DEVICE_FAMILY'] = '1,2' if platform == 'ios' else '3'
        if platform == 'ios' and args.include_cloud_probe:
            settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = '$(inherited) BORAMIN_CLOUD_PROBE'
        settings.update(previous.get((platform, config), {}))
        obj(platform+':'+config, 'XCBuildConfiguration', buildSettings=settings, name=config)
    obj(platform+':mediaconfigs', 'XCConfigurationList', buildConfigurations=[ident(platform+':media'+c) for c in ('Debug', 'Release')], defaultConfigurationIsVisible=0, defaultConfigurationName='Release')
    obj(platform+':configs', 'XCConfigurationList', buildConfigurations=[ident(platform+':'+c) for c in ('Debug', 'Release')], defaultConfigurationIsVisible=0, defaultConfigurationName='Release')

# Logical groups keep shared code visible once while target membership stays explicit.
groups = []
for folder in ('Player', 'Shared', 'iOS', 'MacOS', 'Config', 'Assets', 'Tests'):
    children = [key for key, value in objects.items() if value['isa'] == 'PBXFileReference' and value.get('sourceTree') == 'SOURCE_ROOT' and value['path'].startswith(folder+'/')]
    if children:
        groups.append(obj('group:'+folder, 'PBXGroup', name=folder, sourceTree='<group>', children=children))
obj('products', 'PBXGroup', name='Products', sourceTree='<group>', children=products)
obj('main', 'PBXGroup', sourceTree='<group>', children=groups+[ident('products')])
for config in ('Debug', 'Release'):
    obj('project:'+config, 'XCBuildConfiguration', buildSettings=dict(SWIFT_VERSION='5.0', DEBUG_INFORMATION_FORMAT='dwarf' if config == 'Debug' else 'dwarf-with-dsym', CLANG_ENABLE_MODULES='YES', SWIFT_OPTIMIZATION_LEVEL='-Onone' if config == 'Debug' else '-O', GCC_OPTIMIZATION_LEVEL='0' if config == 'Debug' else '3', ENABLE_USER_SCRIPT_SANDBOXING='YES'), name=config)
obj('project:configs', 'XCConfigurationList', buildConfigurations=[ident('project:'+c) for c in ('Debug', 'Release')], defaultConfigurationIsVisible=0, defaultConfigurationName='Release')
obj('project', 'PBXProject', attributes={'LastUpgradeCheck': '2630', 'TargetAttributes': {target: {'SystemCapabilities': {'com.apple.iCloud': {'enabled': 1}, 'com.apple.Push': {'enabled': 1}}} for target in targets if objects[target]['productType'] == 'com.apple.product-type.application'}}, buildConfigurationList=ident('project:configs'), compatibilityVersion='Xcode 14.0', developmentRegion='en', knownRegions=['en', 'Base'], mainGroup=ident('main'), productRefGroup=ident('products'), projectDirPath='', projectRoot='', targets=targets, packageReferences=[ident('package'), ident('aetherpackage'), ident('asspackage')])
(project/'project.pbxproj').write_bytes(plistlib.dumps(dict(archiveVersion='1', classes={}, objectVersion='56', objects=objects, rootObject=ident('project'))))
schemes = project/'xcshareddata/xcschemes'
schemes.mkdir(parents=True, exist_ok=True)
for platform, spec in platforms.items():
    ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident(platform+":target")}" BuildableName="BoraMin.app" BlueprintName="{escape(spec["name"])}" ReferencedContainer="container:BoraMin.xcodeproj"/>'
    (schemes/(spec['name']+'.xcscheme')).write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2630" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForRunning="YES" buildForTesting="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Release" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugServiceExtension="internal"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
(schemes/'BoraMin.xcscheme').unlink(missing_ok=True)
print(project)
