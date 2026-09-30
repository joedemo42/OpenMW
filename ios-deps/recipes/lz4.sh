# LZ4: compressed BSA archives (v105) and the navmesh disk cache. Static library only, no CLI.
DEP_ARTIFACTS=(LZ4)
LZ4_VERSION=1.10.0

lz4_download() {
    fetch "https://github.com/lz4/lz4/releases/download/v$LZ4_VERSION/lz4-$LZ4_VERSION.tar.gz" \
        537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b
}

lz4_build() {  # <simulator|device>
    prepare_source "lz4-$LZ4_VERSION.tar.gz"
    target_env "$1"
    cmake_build "$BUILD_DIR/lz4/src/build/cmake" -DLZ4_BUILD_CLI=OFF
}

lz4_xcframework() {
    xcframework LZ4 install/lib/liblz4.a install/include
}
