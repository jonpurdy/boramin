#!/usr/bin/env python3
"""Generate the iOS BoraMin player, retaining the installed companion identity and sync probes."""
from pathlib import Path
import hashlib, plistlib
root = Path(__file__).resolve().parent.parent
project = root/'BoraMinSyncTest.xcodeproj'
project.mkdir(exist_ok=True)
objects = {}
def ident(value): return hashlib.sha256(('sync-test-'+value).encode()).hexdigest()[:24].upper()
def obj(key, isa, **values):
    objects[ident(key)] = dict(isa=isa, **values)
    return ident(key)
refs=[]; sources=[]
for p in sorted([*root.glob('SyncTest/*.swift'), *root.glob('Shared/*.swift'), *[p for p in root.glob('Player/*') if p.suffix in ('.swift','.c','.h') and p.name != 'BoraMinApp.swift']]):
    rel=str(p.relative_to(root))
    refs.append(obj(rel,'PBXFileReference',lastKnownFileType={'.swift':'sourcecode.swift','.c':'sourcecode.c.c','.h':'sourcecode.c.h'}[p.suffix],path=rel,sourceTree='SOURCE_ROOT'))
    if p.suffix in ('.swift','.c'): sources.append(obj('build-'+rel,'PBXBuildFile',fileRef=ident(rel)))
obj('app','PBXFileReference',explicitFileType='wrapper.application',path='BoraMinSyncTest.app',sourceTree='BUILT_PRODUCTS_DIR')
obj('products','PBXGroup',name='Products',sourceTree='<group>',children=[ident('app')])
obj('main','PBXGroup',sourceTree='<group>',children=refs+[ident('products')])
obj('sources','PBXSourcesBuildPhase',buildActionMask=2147483647,files=sources,runOnlyForDeploymentPostprocessing=0)
obj('package','XCLocalSwiftPackageReference',relativePath='vendor/AMSMB2')
obj('smb','XCSwiftPackageProductDependency',productName='AMSMB2')
obj('smbbuild','PBXBuildFile',productRef=ident('smb'))
obj('frameworks','PBXFrameworksBuildPhase',buildActionMask=2147483647,files=[ident('smbbuild')],runOnlyForDeploymentPostprocessing=0)
refs.append(obj('icon','PBXFileReference',lastKnownFileType='folder.iconcomposer.icon',path='Assets/BoraMin.icon',sourceTree='SOURCE_ROOT'))
objects[ident('main')]['children'].insert(0,ident('icon'))
icon_build=obj('icon-build','PBXBuildFile',fileRef=ident('icon'))
obj('resources','PBXResourcesBuildPhase',buildActionMask=2147483647,files=[icon_build],runOnlyForDeploymentPostprocessing=0)
obj('target','PBXNativeTarget',buildConfigurationList=ident('target-configs'),buildPhases=[ident('sources'),ident('frameworks'),ident('resources')],buildRules=[],dependencies=[],name='BoraMinSyncTest',productName='BoraMinSyncTest',productReference=ident('app'),productType='com.apple.product-type.application',packageProductDependencies=[ident('smb')])
obj('project','PBXProject',attributes={'LastUpgradeCheck':'2630','TargetAttributes':{ident('target'):{'SystemCapabilities':{'com.apple.iCloud':{'enabled':1},'com.apple.Push':{'enabled':1}}}}},buildConfigurationList=ident('project-configs'),compatibilityVersion='Xcode 14.0',developmentRegion='en',knownRegions=['en','Base'],mainGroup=ident('main'),productRefGroup=ident('products'),projectDirPath='',projectRoot='',targets=[ident('target')],packageReferences=[ident('package')])
for group in ('target','project'):
    for config in ('Debug','Release'):
        settings=dict(SDKROOT='iphoneos',IPHONEOS_DEPLOYMENT_TARGET='26.0',TVOS_DEPLOYMENT_TARGET='17.0',SWIFT_VERSION='5.0',SWIFT_OPTIMIZATION_LEVEL='-Onone' if config=='Debug' else '-O',CLANG_ENABLE_MODULES='YES')
        if group=='target':
            settings.update(PRODUCT_NAME='$(TARGET_NAME)',PRODUCT_BUNDLE_IDENTIFIER='com.example.BoraMin.SyncTest',DEVELOPMENT_TEAM='EXAMPLE000',SUPPORTED_PLATFORMS='iphoneos',CODE_SIGN_STYLE='Automatic',CODE_SIGN_ENTITLEMENTS='SyncTest/SyncTest.entitlements',GENERATE_INFOPLIST_FILE='YES',INFOPLIST_FILE='SyncTest/Info.plist',MARKETING_VERSION='0.1',CURRENT_PROJECT_VERSION='1',ENABLE_USER_SCRIPT_SANDBOXING='YES',TARGETED_DEVICE_FAMILY='1,2')
            settings['TARGETED_DEVICE_FAMILY[sdk=appletvos*]']='3'
            settings['TARGETED_DEVICE_FAMILY[sdk=appletvsimulator*]']='3'
            settings.update(ASSETCATALOG_COMPILER_APPICON_NAME='BoraMin',SWIFT_OBJC_BRIDGING_HEADER='Player/Player-Bridging-Header.h',
                HEADER_SEARCH_PATHS=['$(SRCROOT)/vendor/ffmpeg-ios/include'],
                LIBRARY_SEARCH_PATHS=['$(SRCROOT)/vendor/ffmpeg-ios/lib'],
                OTHER_LDFLAGS=['-lavformat','-lavcodec','-lswresample','-lavutil','-framework','AudioToolbox','-framework','CoreMedia','-framework','VideoToolbox','-lz','-lbz2','-liconv'])
        obj(group+config,'XCBuildConfiguration',buildSettings=settings,name=config)
    obj(group+'-configs','XCConfigurationList',buildConfigurations=[ident(group+'Debug'),ident(group+'Release')],defaultConfigurationIsVisible=0,defaultConfigurationName='Release')
(project/'project.pbxproj').write_bytes(plistlib.dumps(dict(archiveVersion='1',classes={},objectVersion='56',objects=objects,rootObject=ident('project'))))
schemes=project/'xcshareddata/xcschemes';schemes.mkdir(parents=True,exist_ok=True)
ref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident("target")}" BuildableName="BoraMinSyncTest.app" BlueprintName="BoraMinSyncTest" ReferencedContainer="container:BoraMinSyncTest.xcodeproj"/>'
(schemes/'BoraMinSyncTest.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2630" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForRunning="YES" buildForTesting="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Release" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugServiceExtension="internal"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print(project)
