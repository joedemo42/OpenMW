# RecastNavigation: navmesh generation and path finding. The OpenMW fork commit OpenMW's extern/CMakeLists.txt pins,
# with its settings (static, no demo/tests/examples). OpenMW links Recast, Detour and DebugUtils, merged into
# libRecastNavigation.a; headers in include/recastnavigation (as a desktop install).
DEP_ARTIFACTS=(RecastNavigation)
RECASTNAVIGATION_COMMIT=03259f3287ff8330f0d66fcd98d022edddffaa97

recastnavigation_download() {
    fetch "https://github.com/OpenMW/recastnavigation/archive/$RECASTNAVIGATION_COMMIT.zip" \
        b337d8ceebd66641e1a9b9ca2c3dbaebc5aa68a3a30f09435e5c420c177b2c62
}

recastnavigation_build() {  # <simulator|device>
    prepare_source "$RECASTNAVIGATION_COMMIT.zip"
    target_env "$1"
    cmake_build "$BUILD_DIR/recastnavigation/src" -DRECASTNAVIGATION_DEMO=OFF -DRECASTNAVIGATION_TESTS=OFF \
        -DRECASTNAVIGATION_EXAMPLES=OFF

    local lib libs=()
    for lib in Recast Detour DebugUtils; do libs+=("$TARGET_DIR/install/lib/lib$lib.a"); done
    mkdir -p "$TARGET_DIR/lib"
    libtool -static -no_warning_for_no_symbols -o "$TARGET_DIR/lib/libRecastNavigation.a" "${libs[@]}"
    [ -z "$(strong_duplicates "$TARGET_DIR/lib/libRecastNavigation.a" symbols)" ] \
        || die "libRecastNavigation.a: strong symbols defined more than once"
}

recastnavigation_xcframework() {
    xcframework RecastNavigation lib/libRecastNavigation.a install/include
}
