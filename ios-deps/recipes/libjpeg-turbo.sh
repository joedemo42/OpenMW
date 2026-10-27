# libjpeg-turbo: JPEG images for OSG's jpeg plugin. Static libjpeg API only (no TurboJPEG, no tools), Arm Neon SIMD.
DEP_ARTIFACTS=(libjpeg)
DEP_LICENSES=(LICENSE.md README.ijg)
LIBJPEG_TURBO_VERSION=3.2.0

libjpeg-turbo_download() {
    fetch "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/$LIBJPEG_TURBO_VERSION/libjpeg-turbo-$LIBJPEG_TURBO_VERSION.tar.gz" \
        6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e
}

libjpeg-turbo_build() {  # <simulator|device>
    prepare_source "libjpeg-turbo-$LIBJPEG_TURBO_VERSION.tar.gz"
    target_env "$1"
    # CMake leaves CMAKE_SYSTEM_PROCESSOR empty for iOS; libjpeg-turbo picks its SIMD code from it
    cmake_build "$BUILD_DIR/libjpeg-turbo/src" -DCMAKE_SYSTEM_PROCESSOR=aarch64 -DREQUIRE_SIMD=ON \
        -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_TURBOJPEG=OFF -DWITH_TOOLS=OFF
}

libjpeg-turbo_xcframework() {
    xcframework libjpeg install/lib/libjpeg.a install/include
}
