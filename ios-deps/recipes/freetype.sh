# FreeType: TrueType/OpenType fonts for OSG's freetype plugin (and MyGUI). Static, zlib from the iOS SDK;
# bzip2, PNG (colour bitmap glyphs), HarfBuzz and Brotli (WOFF2) are not needed.
DEP_ARTIFACTS=(freetype)
FREETYPE_VERSION=2.14.3

freetype_download() {
    fetch "https://download.savannah.gnu.org/releases/freetype/freetype-$FREETYPE_VERSION.tar.xz" \
        36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f
}

freetype_build() {  # <simulator|device>
    prepare_source "freetype-$FREETYPE_VERSION.tar.xz"
    target_env "$1"
    cmake_build "$BUILD_DIR/freetype/src" -DFT_REQUIRE_ZLIB=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON \
        -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON
}

freetype_xcframework() {
    xcframework freetype install/lib/libfreetype.a install/include
}
