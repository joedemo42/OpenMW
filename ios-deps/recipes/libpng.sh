# libpng: PNG images for OSG's png plugin. Static, Arm Neon filters, zlib from the iOS SDK.
DEP_ARTIFACTS=(libpng)
DEP_LICENSES=(LICENSE)
LIBPNG_VERSION=1.6.58

libpng_download() {
    fetch "https://download.sourceforge.net/libpng/libpng-$LIBPNG_VERSION.tar.xz" \
        28eb403f51f0f7405249132cecfe82ea5c0ef97f1b32c5a65828814ae0d34775
}

libpng_build() {  # <simulator|device>
    prepare_source "libpng-$LIBPNG_VERSION.tar.xz"
    target_env "$1"
    cmake_build "$BUILD_DIR/libpng/src" -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_FRAMEWORK=OFF -DPNG_TESTS=OFF \
        -DPNG_TOOLS=OFF
}

libpng_xcframework() {
    xcframework libpng install/lib/libpng16.a install/include
}
