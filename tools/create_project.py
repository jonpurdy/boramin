#!/usr/bin/env python3
"""Generate a reproducible Xcode project; keep signing choices on regeneration."""
from pathlib import Path
import hashlib, json, subprocess, os
root = Path(__file__).resolve().parent.parent
project = root / 'BoraMin.xcodeproj'
project.mkdir(exist_ok=True)
def ident(s): return hashlib.sha256(s.encode()).hexdigest()[:24].upper()
objects = {}
def obj(key, isa, **values):
    objects[ident(key)] = dict(isa=isa, **values)
    return ident(key)
previous = {}
pbx = project / 'project.pbxproj'
if pbx.exists():
    old = json.loads(subprocess.check_output(['plutil','-convert','json','-o','-',str(pbx)]))
    for o in old['objects'].values():
        settings = o.get('buildSettings', {})
        if 'PRODUCT_BUNDLE_IDENTIFIER' in settings:
            previous[o['name']] = {k:v for k,v in settings.items() if k in ['PRODUCT_BUNDLE_IDENTIFIER','DEVELOPMENT_TEAM','PROVISIONING_PROFILE_SPECIFIER']}
files = sorted((root/'Player').glob('*')) + [root/'Shared/ICloudSync.swift']
source_ids, file_ids = [], []
for f in files:
    kind = {'.swift':'sourcecode.swift','.c':'sourcecode.c.c','.h':'sourcecode.c.h','.plist':'text.plist.xml'}[f.suffix]
    file_ids.append(obj(f.name,'PBXFileReference',lastKnownFileType=kind,path=f.name if f.parent.name == 'Player' else str(f.relative_to(root)),sourceTree='<group>' if f.parent.name == 'Player' else 'SOURCE_ROOT'))
    if f.suffix in ['.swift','.c']:
        source_ids.append(obj('build'+f.name,'PBXBuildFile',fileRef=ident(f.name)))
obj('code','PBXGroup',path='Player',sourceTree='<group>',children=file_ids)
obj('app','PBXFileReference',explicitFileType='wrapper.application',path='BoraMin.app',sourceTree='BUILT_PRODUCTS_DIR')
obj('products','PBXGroup',name='Products',sourceTree='<group>',children=[ident('app')])
obj('main','PBXGroup',sourceTree='<group>',children=[ident('code'),ident('products')])
obj('sources','PBXSourcesBuildPhase',buildActionMask=2147483647,files=source_ids,runOnlyForDeploymentPostprocessing=0)
obj('package','XCLocalSwiftPackageReference',relativePath='vendor/AMSMB2')
obj('smb','XCSwiftPackageProductDependency',productName='AMSMB2')
obj('smbbuild','PBXBuildFile',productRef=ident('smb'))
obj('frameworks','PBXFrameworksBuildPhase',buildActionMask=2147483647,files=[ident('smbbuild')],runOnlyForDeploymentPostprocessing=0)
file_ids.append(obj('tv-icons','PBXFileReference',lastKnownFileType='folder.assetcatalog',path='Assets/BoraMinTV.xcassets',sourceTree='SOURCE_ROOT'))
# The code group was already created; append the asset reference explicitly.
objects[ident('code')]['children']=file_ids
resources=[obj('tv-icons-build','PBXBuildFile',fileRef=ident('tv-icons'))]
if os.environ.get('BORAMIN_SMOKE_FIXTURE'):
    obj('smoke','PBXFileReference',lastKnownFileType='file',path=str(Path(os.environ['BORAMIN_SMOKE_FIXTURE']).resolve()),sourceTree='<absolute>')
    resources.append(obj('smokebuild','PBXBuildFile',fileRef=ident('smoke')))
obj('resources','PBXResourcesBuildPhase',buildActionMask=2147483647,files=resources,runOnlyForDeploymentPostprocessing=0)
obj('target','PBXNativeTarget',buildConfigurationList=ident('targetconfigs'),buildPhases=[ident('sources'),ident('frameworks'),ident('resources')],
    buildRules=[],dependencies=[],name='BoraMin',productName='BoraMin',productReference=ident('app'),
    productType='com.apple.product-type.application',packageProductDependencies=[ident('smb')])
obj('project','PBXProject',attributes={'LastUpgradeCheck':'2630'},buildConfigurationList=ident('projectconfigs'),
    compatibilityVersion='Xcode 14.0',developmentRegion='en',knownRegions=['en','Base'],mainGroup=ident('main'),
    productRefGroup=ident('products'),projectDirPath='',projectRoot='',targets=[ident('target')],packageReferences=[ident('package')])
for group in ['target','project']:
    for config in ['Debug','Release']:
        settings = dict(SDKROOT='appletvos',TVOS_DEPLOYMENT_TARGET='26.6',SWIFT_VERSION='5.0',CLANG_ENABLE_MODULES='YES',
            SWIFT_OPTIMIZATION_LEVEL='-Onone' if config=='Debug' else '-O', GCC_OPTIMIZATION_LEVEL='0' if config=='Debug' else '3')
        if group=='target':
            settings.update(ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon',PRODUCT_NAME='$(TARGET_NAME)',PRODUCT_BUNDLE_IDENTIFIER='com.example.BoraMin',TARGETED_DEVICE_FAMILY='3',
                SUPPORTED_PLATFORMS='appletvos',CODE_SIGN_STYLE='Automatic',CODE_SIGN_ENTITLEMENTS='Config/BoraMin.entitlements',GENERATE_INFOPLIST_FILE='YES',INFOPLIST_FILE='Player/Info.plist',
                SWIFT_OBJC_BRIDGING_HEADER='Player/Player-Bridging-Header.h',HEADER_SEARCH_PATHS=['$(SRCROOT)/vendor/ffmpeg/include'],
                LIBRARY_SEARCH_PATHS=['$(SRCROOT)/vendor/ffmpeg/lib'],OTHER_LDFLAGS=['-lavformat','-lavcodec','-lswresample','-lavutil','-framework','AudioToolbox','-framework','CoreMedia','-framework','VideoToolbox','-lz','-lbz2','-liconv'],
                MARKETING_VERSION='0.1',CURRENT_PROJECT_VERSION='1',ENABLE_USER_SCRIPT_SANDBOXING='YES')
            settings.update(previous.get(config,{}))
        obj(group+config,'XCBuildConfiguration',buildSettings=settings,name=config)
    obj(group+'configs','XCConfigurationList',buildConfigurations=[ident(group+'Debug'),ident(group+'Release')],defaultConfigurationIsVisible=0,defaultConfigurationName='Release')
data=dict(archiveVersion='1',classes={},objectVersion='56',objects=objects,rootObject=ident('project'))
pbx.write_text(json.dumps(data,indent=2))
subprocess.run(['plutil','-convert','xml1',str(pbx)],check=True)
schemes=project/'xcshareddata'/'xcschemes';schemes.mkdir(parents=True,exist_ok=True)
reference=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident("target")}" BuildableName="BoraMin.app" BlueprintName="BoraMin" ReferencedContainer="container:BoraMin.xcodeproj"/>'
(schemes/'BoraMin.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2630" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Release" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print(project)
