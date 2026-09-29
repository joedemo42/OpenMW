# MoltenVK: Vulkan on Metal, static library for Mesa/Zink.
DEP_ARTIFACTS=(MoltenVK)

moltenvk_download() {
    fetch_git https://github.com/KhronosGroup/MoltenVK.git v1.4.2 db66022459ffb663aa2b50f6b018bc2e124f5edf
    # sources of MoltenVK's own pinned dependencies (ExternalRevisions/), built per target below
    (cd "$SOURCE_DIR/moltenvk" && ./fetchDependencies --none)
}

moltenvk_build() {  # <simulator|device>
    prepare_source -
    target_env "$1"
    local src="$BUILD_DIR/moltenvk/src" flag=--ios destination="generic/platform=iOS" slice=ios-arm64 lib
    [ "$1" = simulator ] && { flag=--iossim; destination="generic/platform=iOS Simulator"; slice='ios-arm64*-simulator'; }
    (cd "$src" && ./fetchDependencies "$flag")
    # same as MoltenVK's 'make ios|iossim', but with a local derived data path
    xcodebuild build -quiet -project "$src/MoltenVKPackaging.xcodeproj" -scheme "MoltenVK Package (iOS only)" \
        -destination "$destination" -derivedDataPath "$TARGET_DIR/dd"
    # shellcheck disable=SC2086 # glob in $slice
    lib=$(echo "$src"/Package/Release/MoltenVK/static/MoltenVK.xcframework/$slice/libMoltenVK.a)
    [ -f "$lib" ] || die "MoltenVK build produced no $1 library"
    mkdir -p "$TARGET_DIR/lib"
    lipo "$lib" -thin arm64 -output "$TARGET_DIR/lib/libMoltenVK.a" 2>/dev/null || cp "$lib" "$TARGET_DIR/lib/"
    rm -rf "$TARGET_DIR/include" && cp -R "$src/Package/Release/MoltenVK/include" "$TARGET_DIR/include"
}

moltenvk_xcframework() {
    xcframework MoltenVK lib/libMoltenVK.a include
}
