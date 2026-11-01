#!/usr/bin/env python3
"""Generate App/PadCB.xcodeproj/project.pbxproj deterministically."""
import hashlib
import os

SWIFT_FILES = [
    "PadCBApp.swift", "HomeView.swift", "PCBPlaceholderView.swift",
    "SchematicEditorView.swift", "SymbolChooserView.swift", "FileListView.swift",
    "SchematicDocument.swift", "SchematicCanvasView.swift", "SymbolRenderer.swift",
    "SymbolDrawList.swift",
    "SExpr.swift", "KiCadSymbol.swift", "LibraryStore.swift",
]


def oid(tag):
    return hashlib.md5(("padcb:" + tag).encode()).hexdigest()[:24].upper()


def main():
    out = []
    w = out.append
    fileref = {f: oid("ref:" + f) for f in SWIFT_FILES}
    buildfile = {f: oid("build:" + f) for f in SWIFT_FILES}
    assets_ref, assets_build = oid("ref:assets"), oid("build:assets")
    symbols_ref, symbols_build = oid("ref:symbols"), oid("build:symbols")
    plist_ref = oid("ref:plist")
    app_ref = oid("ref:app")
    main_group, prod_group, app_group = oid("g:main"), oid("g:prod"), oid("g:app")
    target = oid("target")
    proj = oid("project")
    src_phase, fw_phase, res_phase = oid("ph:src"), oid("ph:fw"), oid("ph:res")
    proj_cl, target_cl = oid("cl:proj"), oid("cl:target")
    proj_dbg, proj_rel = oid("cfg:projdbg"), oid("cfg:projrel")
    tgt_dbg, tgt_rel = oid("cfg:tgtdbg"), oid("cfg:tgtrel")

    w("// !$*UTF8*$!")
    w("{")
    w("\tarchiveVersion = 1;")
    w("\tclasses = {\n\t};")
    w("\tobjectVersion = 56;")
    w("\tobjects = {")
    w("")
    w("/* Begin PBXBuildFile section */")
    for f in SWIFT_FILES:
        w(f"\t\t{buildfile[f]} = {{isa = PBXBuildFile; fileRef = {fileref[f]}; }};")
    w(f"\t\t{assets_build} = {{isa = PBXBuildFile; fileRef = {assets_ref}; }};")
    w(f"\t\t{symbols_build} = {{isa = PBXBuildFile; fileRef = {symbols_ref}; }};")
    w("/* End PBXBuildFile section */")
    w("")
    w("/* Begin PBXFileReference section */")
    for f in SWIFT_FILES:
        w(f"\t\t{fileref[f]} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {f}; sourceTree = \"<group>\"; }};")
    w(f"\t\t{assets_ref} = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = \"<group>\"; }};")
    w(f"\t\t{symbols_ref} = {{isa = PBXFileReference; lastKnownFileType = folder; path = Symbols; sourceTree = \"<group>\"; }};")
    w(f"\t\t{plist_ref} = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; }};")
    w(f"\t\t{app_ref} = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = PadCB.app; sourceTree = BUILT_PRODUCTS_DIR; }};")
    w("/* End PBXFileReference section */")
    w("")
    w("/* Begin PBXFrameworksBuildPhase section */")
    w(f"\t\t{fw_phase} = {{")
    w("\t\t\tisa = PBXFrameworksBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (\n\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
    w("/* End PBXFrameworksBuildPhase section */")
    w("")
    w("/* Begin PBXGroup section */")
    w(f"\t\t{main_group} = {{")
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    w(f"\t\t\t\t{app_group},")
    w(f"\t\t\t\t{assets_ref},")
    w(f"\t\t\t\t{prod_group},")
    w("\t\t\t);")
    w('\t\t\tsourceTree = "<group>";')
    w("\t\t};")
    w(f"\t\t{prod_group} = {{")
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    w(f"\t\t\t\t{app_ref},")
    w("\t\t\t);")
    w("\t\t\tname = Products;")
    w('\t\t\tsourceTree = "<group>";')
    w("\t\t};")
    w(f"\t\t{app_group} = {{")
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    for f in SWIFT_FILES:
        w(f"\t\t\t\t{fileref[f]},")
    w(f"\t\t\t\t{symbols_ref},")
    w(f"\t\t\t\t{plist_ref},")
    w("\t\t\t);")
    w("\t\t\tpath = PadCB;")
    w('\t\t\tsourceTree = "<group>";')
    w("\t\t};")
    w("/* End PBXGroup section */")
    w("")
    w("/* Begin PBXNativeTarget section */")
    w(f"\t\t{target} = {{")
    w("\t\t\tisa = PBXNativeTarget;")
    w(f"\t\t\tbuildConfigurationList = {target_cl};")
    w("\t\t\tbuildPhases = (")
    w(f"\t\t\t\t{src_phase},")
    w(f"\t\t\t\t{fw_phase},")
    w(f"\t\t\t\t{res_phase},")
    w("\t\t\t);")
    w("\t\t\tbuildRules = (\n\t\t\t);")
    w("\t\t\tdependencies = (\n\t\t\t);")
    w("\t\t\tname = PadCB;")
    w(f"\t\t\tproductReference = {app_ref};")
    w('\t\t\tproductType = "com.apple.product-type.application";')
    w("\t\t};")
    w("/* End PBXNativeTarget section */")
    w("")
    w("/* Begin PBXProject section */")
    w(f"\t\t{proj} = {{")
    w("\t\t\tisa = PBXProject;")
    w("\t\t\tattributes = {")
    w("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    w("\t\t\t\tLastSwiftUpdateCheck = 1500;")
    w("\t\t\t\tLastUpgradeCheck = 1500;")
    w("\t\t\t\tTargetAttributes = {")
    w(f"\t\t\t\t\t{target} = {{")
    w("\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;")
    w("\t\t\t\t\t};")
    w("\t\t\t\t};")
    w("\t\t\t};")
    w(f"\t\t\tbuildConfigurationList = {proj_cl};")
    w('\t\t\tcompatibilityVersion = "Xcode 14.0";')
    w("\t\t\tdevelopmentRegion = en;")
    w("\t\t\thasScannedForEncodings = 0;")
    w("\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);")
    w(f"\t\t\tmainGroup = {main_group};")
    w(f"\t\t\tproductRefGroup = {prod_group};")
    w('\t\t\tprojectDirPath = "";')
    w('\t\t\tprojectRoot = "";')
    w("\t\t\ttargets = (")
    w(f"\t\t\t\t{target},")
    w("\t\t\t);")
    w("\t\t};")
    w("/* End PBXProject section */")
    w("")
    w("/* Begin PBXResourcesBuildPhase section */")
    w(f"\t\t{res_phase} = {{")
    w("\t\t\tisa = PBXResourcesBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (")
    w(f"\t\t\t\t{assets_build},")
    w(f"\t\t\t\t{symbols_build},")
    w("\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
    w("/* End PBXResourcesBuildPhase section */")
    w("")
    w("/* Begin PBXSourcesBuildPhase section */")
    w(f"\t\t{src_phase} = {{")
    w("\t\t\tisa = PBXSourcesBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (")
    for f in SWIFT_FILES:
        w(f"\t\t\t\t{buildfile[f]},")
    w("\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
    w("/* End PBXSourcesBuildPhase section */")
    w("")
    proj_cfg = """\t\t\tbuildSettings = {
\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;
\t\t\t\tSDKROOT = iphoneos;
\t\t\t};"""
    tgt_cfg = """\t\t\tbuildSettings = {
\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tINFOPLIST_FILE = PadCB/Info.plist;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 0.1;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.user.padcb;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_STRICT_CONCURRENCY = minimal;
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tTARGETED_DEVICE_FAMILY = 2;
\t\t\t};"""
    w("/* Begin XCBuildConfiguration section */")
    for cid, cfg, name in ((proj_dbg, proj_cfg, "Debug"), (proj_rel, proj_cfg, "Release"),
                           (tgt_dbg, tgt_cfg, "Debug"), (tgt_rel, tgt_cfg, "Release")):
        w(f"\t\t{cid} = {{")
        w("\t\t\tisa = XCBuildConfiguration;")
        w(cfg)
        w(f"\t\t\tname = {name};")
        w("\t\t};")
    w("/* End XCBuildConfiguration section */")
    w("")
    w("/* Begin XCConfigurationList section */")
    for clid, cfgs in ((proj_cl, (proj_dbg, proj_rel)), (target_cl, (tgt_dbg, tgt_rel))):
        w(f"\t\t{clid} = {{")
        w("\t\t\tisa = XCConfigurationList;")
        w("\t\t\tbuildConfigurations = (")
        for c in cfgs:
            w(f"\t\t\t\t{c},")
        w("\t\t\t);")
        w("\t\t\tdefaultConfigurationIsVisible = 0;")
        w("\t\t\tdefaultConfigurationName = Release;")
        w("\t\t};")
    w("/* End XCConfigurationList section */")
    w("\t};")
    w(f"\trootObject = {proj};")
    w("}")

    dest_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "PadCB.xcodeproj")
    os.makedirs(dest_dir, exist_ok=True)
    with open(os.path.join(dest_dir, "project.pbxproj"), "w") as f:
        f.write("\n".join(out) + "\n")
    print("wrote", os.path.join(dest_dir, "project.pbxproj"))


if __name__ == "__main__":
    main()
