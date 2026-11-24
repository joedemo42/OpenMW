# Melo-Controller: on-screen game controller in SwiftUI (touch controls and their layout editor). A Swift package
# without tags: pinned by commit, compiled with swiftc into a static framework. Library evolution, module interface
# only: the app build compiles the interface with its own compiler, so the framework survives Xcode updates.
# About 30 s per slice.
DEP_ARTIFACTS=(MeloController)
DEP_LICENSES=(LICENSE)  # GPL-3.0
MELO_COMMIT=b16a8e394679994a8d5585aa2faeb1cb37c4f221

melo-controller_download() {
    fetch "https://github.com/stossy11/Melo-Controller/archive/$MELO_COMMIT.tar.gz" \
        03d582b88a5839fa704999a8807e6bb49a6e86ced6efe3915dc0e9f77266caf3
}

melo-controller_build() {  # <simulator|device>
    prepare_source "$MELO_COMMIT.tar.gz"
    target_env "$1"
    local src="$BUILD_DIR/melo-controller/src" fw="$TARGET_DIR/MeloController.framework" stamp
    # the source only changes through prepare_source, which removes the build output
    stamp="$SDK_PATH $MIN_IOS"
    [ -f "$fw/MeloController" ] && [ "$(cat "$TARGET_DIR/.built" 2>/dev/null)" = "$stamp" ] && return
    rm -rf "$TARGET_DIR" && mkdir -p "$fw/Modules/MeloController.swiftmodule"
    # module interface named by the triple without the OS version (arm64-apple-ios[-simulator]); #file and #filePath
    # relative to the repository (no build paths in the app binary)
    xcrun -sdk "$SDK" swiftc -target "$TRIPLE" -sdk "$SDK_PATH" -module-name MeloController -swift-version 5 \
        -parse-as-library -O -whole-module-optimization -enable-library-evolution \
        -file-prefix-map "$(dirname "$DEPS_DIR")/=" \
        -emit-library -static -o "$fw/MeloController" \
        -emit-module-interface-path "$fw/Modules/MeloController.swiftmodule/${TRIPLE/$MIN_IOS/}.swiftinterface" \
        -module-cache-path "$TARGET_DIR/module-cache" \
        $(find "$src/Sources/Melo-Controller" -name '*.swift' | sort)
    rm -rf "$TARGET_DIR/module-cache"
    plutil -create xml1 "$fw/Info.plist"
    plutil -insert CFBundleExecutable -string MeloController "$fw/Info.plist"
    plutil -insert CFBundleIdentifier -string com.stossy11.MeloController "$fw/Info.plist"
    plutil -insert CFBundleName -string MeloController "$fw/Info.plist"
    plutil -insert CFBundlePackageType -string FMWK "$fw/Info.plist"
    plutil -insert MinimumOSVersion -string "$MIN_IOS" "$fw/Info.plist"
    echo "$stamp" > "$TARGET_DIR/.built"
}

melo-controller_xcframework() {
    xcframework MeloController MeloController.framework
}
