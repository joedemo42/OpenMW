# Boost: the libraries OpenMW uses, built with Boost's CMake build. OpenMW links iostreams and program_options
# (merged into libboost.a) and uses geometry and any header-only. Iostreams only for its stream templates,
# so no compression filters (zlib/bzip2/lzma/zstd).
DEP_ARTIFACTS=(Boost)
BOOST_VERSION=1.92.0

boost_download() {
    fetch "https://github.com/boostorg/boost/releases/download/boost-$BOOST_VERSION/boost-$BOOST_VERSION-cmake.tar.xz" \
        9bed76128d4e46755dbe818487788c6fceb6f72b378f4daa49b7e1e600d9088d
}

boost_build() {  # <simulator|device>
    prepare_source "boost-$BOOST_VERSION-cmake.tar.xz"
    target_env "$1"
    cmake_build "$BUILD_DIR/boost/src" -DBOOST_INCLUDE_LIBRARIES="iostreams;program_options;geometry;any" \
        -DBOOST_IOSTREAMS_ENABLE_ZLIB=OFF -DBOOST_IOSTREAMS_ENABLE_BZIP2=OFF -DBOOST_IOSTREAMS_ENABLE_LZMA=OFF \
        -DBOOST_IOSTREAMS_ENABLE_ZSTD=OFF

    # geometry's dependencies build more compiled libraries (graph, serialization, thread, ...); OpenMW links
    # none of them, and iostreams + program_options need no other compiled Boost library
    mkdir -p "$TARGET_DIR/lib"
    libtool -static -no_warning_for_no_symbols -o "$TARGET_DIR/lib/libboost.a" \
        "$TARGET_DIR/install/lib/libboost_iostreams.a" "$TARGET_DIR/install/lib/libboost_program_options.a"
    [ -z "$(strong_duplicates "$TARGET_DIR/lib/libboost.a" symbols)" ] \
        || die "libboost.a: strong symbols defined more than once"
}

boost_xcframework() {
    xcframework Boost lib/libboost.a install/include
}
