# ICU: OpenMW's localisation (MessageFormat, plural rules, locale data). Static; uc + i18n + data merged into
# libicu.a, data filtered with OpenMW's extern/icufilters.json. ICU runs its own tools to build the data, so a
# cross build needs a host build first (build/icu/host), as in OpenMW's Android CI.
DEP_ARTIFACTS=(ICU)
DEP_LICENSES=(LICENSE)
ICU_VERSION=78.3
# OpenMW's extern/CMakeLists.txt options
ICU_OPTIONS=(--enable-static --disable-shared --disable-tests --disable-samples --disable-icuio --disable-extras)

icu_download() {
    fetch "https://github.com/unicode-org/icu/releases/download/release-$ICU_VERSION/icu4c-$ICU_VERSION-sources.tgz" \
        3a2e7a47604ba702f345878308e6fefeca612ee895cf4a5f222e7955fabfe0c0
    # the data sources: the sources tarball only has the prebuilt data, which the data filter cannot apply to
    fetch "https://github.com/unicode-org/icu/releases/download/release-$ICU_VERSION/icu4c-$ICU_VERSION-data.zip" \
        9d8b3899096aeb83e4e21ef8a40fec9e03b28db18c48452efac882ce25a91e27
}

icu_build() {  # <simulator|device>
    prepare_source "icu4c-$ICU_VERSION-sources.tgz"
    local src="$BUILD_DIR/icu/src/source" host="$BUILD_DIR/icu/host"
    if [ ! -f "$src/data/locales/root.txt" ]; then
        [ -f "$SOURCE_DIR/icu/icu4c-$ICU_VERSION-data.zip" ] || icu_download
        rm -rf "$src/data" && unzip -q "$SOURCE_DIR/icu/icu4c-$ICU_VERSION-data.zip" -d "$src"
    fi
    local hostflags="-isysroot $(xcrun --sdk macosx --show-sdk-path)"
    echo "==> build icu (host tools)"
    configure_build "$host" "$src/configure" "${ICU_OPTIONS[@]}" \
        CC="$(xcrun --sdk macosx -f clang)" CXX="$(xcrun --sdk macosx -f clang++)" \
        CFLAGS="$hostflags -O2" CXXFLAGS="$hostflags -O2" LDFLAGS="$hostflags"
    make -C "$host" -j "$JOBS"

    target_env "$1"
    local flags="-target $TRIPLE -isysroot $SDK_PATH"
    # --build and --host both given and different: autoconf cross-compiles without trying to run target programs
    configure_build "$TARGET_DIR/build" "$src/configure" --build="$(sh "$src/config.guess")" \
        --host=aarch64-apple-darwin --with-cross-build="$host" "${ICU_OPTIONS[@]}" --disable-tools \
        --prefix="$TARGET_DIR/install" CC="$(xcrun --sdk "$SDK" -f clang)" CXX="$(xcrun --sdk "$SDK" -f clang++)" \
        CFLAGS="$flags -O3" CXXFLAGS="$flags -O3" LDFLAGS="$flags" \
        ICU_DATA_FILTER_FILE="$DEPS_DIR/../extern/icufilters.json"
    make -C "$TARGET_DIR/build" -j "$JOBS"
    make -C "$TARGET_DIR/build" install > /dev/null

    mkdir -p "$TARGET_DIR/lib"
    libtool -static -no_warning_for_no_symbols -o "$TARGET_DIR/lib/libicu.a" \
        "$TARGET_DIR/install/lib/libicuuc.a" "$TARGET_DIR/install/lib/libicui18n.a" "$TARGET_DIR/install/lib/libicudata.a"
    [ -z "$(strong_duplicates "$TARGET_DIR/lib/libicu.a" symbols)" ] || die "libicu.a: strong symbols defined more than once"
}

icu_xcframework() {
    xcframework ICU lib/libicu.a install/include
}
