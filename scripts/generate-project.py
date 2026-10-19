#!/usr/bin/env python3
"""Generate the shared Xcode application project with pinned Sparkle updates."""
from pathlib import Path
import hashlib

root = Path(__file__).resolve().parent.parent
def uid(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
objects = []
def obj(name, contents):
    key = uid(name)
    objects.append(f'{key} = {{ {contents} }};')
    return key
sources = sorted((root / 'Sources/HushApp').glob('*.swift'))
build_sources, source_refs = [], []
for file in sources:
    ref = obj(str(file.relative_to(root)), f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{file.relative_to(root)}"; sourceTree = SOURCE_ROOT;')
    source_refs.append(ref)
    build_sources.append(obj('build-' + file.name, f'isa = PBXBuildFile; fileRef = {ref};'))
resources = []
for file, file_type in [('Resources/Assets.xcassets','folder.assetcatalog'),('Resources/Hush.icns','image.icns'),('Resources/PrivacyInfo.xcprivacy','text.xml'),('Vendor/Muesli/LICENSE','text'),('Vendor/Sparkle-LICENSE.txt','text')]:
    ref = obj(file, f'isa = PBXFileReference; lastKnownFileType = {file_type}; path = "{file}"; sourceTree = SOURCE_ROOT;')
    source_refs.append(ref)
    resources.append(obj('resource-' + file, f'isa = PBXBuildFile; fileRef = {ref};'))
product = obj('product', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = Hush.app; sourceTree = BUILT_PRODUCTS_DIR;')
products = obj('products', f'isa = PBXGroup; children = ({product},); name = Products; sourceTree = "<group>";')
group = obj('group', f'isa = PBXGroup; children = ({",".join(source_refs + [products])},); sourceTree = "<group>";')
package = obj('package', 'isa = XCLocalSwiftPackageReference; relativePath = .;')
dependency = obj('hushkit', f'isa = XCSwiftPackageProductDependency; package = {package}; productName = HushKit;')
package_build = obj('link-hushkit', f'isa = PBXBuildFile; productRef = {dependency};')
sparkle_package = obj('sparkle-package', 'isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/sparkle-project/Sparkle"; requirement = {kind = exactVersion; version = 2.10.0;};')
sparkle_dependency = obj('sparkle-product', f'isa = XCSwiftPackageProductDependency; package = {sparkle_package}; productName = Sparkle;')
sparkle_build = obj('link-sparkle', f'isa = PBXBuildFile; productRef = {sparkle_dependency};')
source_phase = obj('source-phase', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(build_sources)},); runOnlyForDeploymentPostprocessing = 0;')
resource_phase = obj('resource-phase', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(resources)},); runOnlyForDeploymentPostprocessing = 0;')
link_phase = obj('link-phase', f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({package_build},{sparkle_build},); runOnlyForDeploymentPostprocessing = 0;')
configs, project_configs = [], []
for name in ['Debug','Release']:
    settings = '''ARCHS = arm64; CODE_SIGN_IDENTITY = "-"; CODE_SIGN_STYLE = Manual; CODE_SIGN_ENTITLEMENTS = Resources/Hush.entitlements;
    DEVELOPMENT_TEAM = ZUT6837GB5; COMBINE_HIDPI_IMAGES = YES; CURRENT_PROJECT_VERSION = 9; ENABLE_APP_SANDBOX = YES; ENABLE_HARDENED_RUNTIME = YES;
    GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = Resources/Info.plist; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks";
    MACOSX_DEPLOYMENT_TARGET = 26.0; MARKETING_VERSION = 2.0.0; PRODUCT_BUNDLE_IDENTIFIER = app.hush.mac; PRODUCT_NAME = Hush;
    SDKROOT = macosx; SUPPORTED_PLATFORMS = macosx; SWIFT_VERSION = 6.0; SWIFT_STRICT_CONCURRENCY = complete; ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;'''
    if name == 'Debug': settings += ' SWIFT_OPTIMIZATION_LEVEL = "-Onone"; SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;'
    else: settings += ' SWIFT_OPTIMIZATION_LEVEL = "-O"; SWIFT_COMPILATION_MODE = wholemodule;'
    configs.append(obj('target-' + name, f'isa = XCBuildConfiguration; buildSettings = {{{settings}}}; name = {name};'))
    project_configs.append(obj('project-' + name, f'isa = XCBuildConfiguration; buildSettings = {{CLANG_ENABLE_MODULES = YES; MACOSX_DEPLOYMENT_TARGET = 26.0; SDKROOT = macosx;}}; name = {name};'))
configlist = obj('configs', f'isa = XCConfigurationList; buildConfigurations = ({",".join(configs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
project_configlist = obj('project-configs', f'isa = XCConfigurationList; buildConfigurations = ({",".join(project_configs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
target = obj('target', f'isa = PBXNativeTarget; buildConfigurationList = {configlist}; buildPhases = ({source_phase},{link_phase},{resource_phase},); buildRules = (); dependencies = (); name = Hush; packageProductDependencies = ({dependency},{sparkle_dependency},); productName = Hush; productReference = {product}; productType = "com.apple.product-type.application";')
project = obj('project', f'isa = PBXProject; attributes = {{LastUpgradeCheck = 2660;}}; buildConfigurationList = {project_configlist}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base,); mainGroup = {group}; productRefGroup = {products}; packageReferences = ({package},{sparkle_package},); projectDirPath = ""; projectRoot = ""; targets = ({target},);')
directory = root / 'Hush.xcodeproj'
directory.mkdir(exist_ok=True)
(directory / 'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(objects) + f'\n}}; rootObject = {project};}}\n')
schemes = directory / 'xcshareddata/xcschemes'
schemes.mkdir(parents=True, exist_ok=True)
reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Hush.app" BlueprintName="Hush" ReferencedContainer="container:Hush.xcodeproj"/>'
(schemes / 'Hush.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2660" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/>
<ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print('Generated Hush.xcodeproj')
