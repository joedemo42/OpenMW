# FFmpeg: OpenMW's audio decoding and video playback. Only the components Morrowind's data needs (scanned: Bink video
# with DCT or RDFT audio, MPEG-1 Layer III, 16-bit PCM WAV); avcodec, avformat, avutil, swscale and swresample merged
# into libFFmpeg.a. No external libraries (autodetect off, which also drops pthreads: enabled again), Neon assembly,
# LGPL. ponytail: formats of mods (Ogg Vorbis, 8-bit PCM, ...) are one more entry below each.
DEP_ARTIFACTS=(FFmpeg)
FFMPEG_VERSION=9.0.2
FFMPEG_DECODERS=(bink binkaudio_dct binkaudio_rdft mp3float pcm_s16le)
FFMPEG_DEMUXERS=(bink mp3 wav)
FFMPEG_PARSERS=(mpegaudio)

ffmpeg_download() {
    fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" \
        8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
}

ffmpeg_build() {  # <simulator|device>
    prepare_source "ffmpeg-$FFMPEG_VERSION.tar.xz"
    target_env "$1"
    local flags="-target $TRIPLE -isysroot $SDK_PATH" lib libs=() expected enabled
    local IFS=,
    # --pkg-config=false: the host's pkg-config would report Homebrew's macOS packages; configure warns about it
    configure_build "$TARGET_DIR/build" "$BUILD_DIR/ffmpeg/src/configure" --prefix="$TARGET_DIR/install" \
        --enable-cross-compile --target-os=darwin --arch=aarch64 --cc="$(xcrun --sdk "$SDK" -f clang)" \
        --extra-cflags="$flags" --extra-ldflags="$flags" --pkg-config=false \
        --enable-static --disable-shared --enable-pic --disable-debug --disable-programs --disable-doc \
        --disable-network --disable-avdevice --disable-avfilter --disable-autodetect --enable-pthreads \
        --disable-everything --enable-decoder="${FFMPEG_DECODERS[*]}" --enable-demuxer="${FFMPEG_DEMUXERS[*]}" \
        --enable-parser="${FFMPEG_PARSERS[*]}"
    unset IFS
    make -C "$TARGET_DIR/build" -j "$JOBS"
    make -C "$TARGET_DIR/build" install > /dev/null

    # exactly the requested components (configure may enable others as dependencies)
    expected=$( { printf '%s_decoder\n' "${FFMPEG_DECODERS[@]}"; printf '%s_demuxer\n' "${FFMPEG_DEMUXERS[@]}"
        printf '%s_parser\n' "${FFMPEG_PARSERS[@]}"; } | sort)
    enabled=$(sed -n -E 's/^#define CONFIG_([A-Z0-9_]+_(DECODER|ENCODER|DEMUXER|MUXER|PARSER|BSF|PROTOCOL|HWACCEL|INDEV|OUTDEV|FILTER)) 1$/\1/p' \
        "$TARGET_DIR/build/config_components.h" | tr '[:upper:]' '[:lower:]' | sort)
    [ "$enabled" = "$expected" ] || die "ffmpeg components: '${enabled//$'\n'/ }', expected '${expected//$'\n'/ }'"

    for lib in avformat avcodec swscale swresample avutil; do libs+=("$TARGET_DIR/install/lib/lib$lib.a"); done
    mkdir -p "$TARGET_DIR/lib"
    libtool -static -no_warning_for_no_symbols -o "$TARGET_DIR/lib/libFFmpeg.a" "${libs[@]}" 2>&1 \
        | { grep -v 'same member name' || true; }
    [ -z "$(strong_duplicates "$TARGET_DIR/lib/libFFmpeg.a" symbols)" ] \
        || die "libFFmpeg.a: strong symbols defined more than once"
}

ffmpeg_xcframework() {
    xcframework FFmpeg lib/libFFmpeg.a install/include
}
