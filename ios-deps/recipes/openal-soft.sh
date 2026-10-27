# OpenAL Soft: OpenMW's audio output (it relies on OpenAL Soft extensions: ALC_SOFT_PAUSE_DEVICE, reopen_device,
# AL_SOFT_events, EFX, HRTF). Static, CoreAudio backend only (RemoteIO on iOS), default HRTF data embedded; no
# utilities, examples, config tool or installed data files.
DEP_ARTIFACTS=(OpenAL)
DEP_LICENSES=(COPYING BSD-3Clause LICENSE-pffft fmt-11.2.0/LICENSE gsl/LICENSE)
DEP_NOTICES=(core/bs2b.h common/filesystem.h)
OPENAL_SOFT_VERSION=1.25.2

openal-soft_download() {
    fetch "https://openal-soft.org/openal-releases/openal-soft-$OPENAL_SOFT_VERSION.tar.bz2" \
        1dbaac44e7579d5bc8847ca8db4b2e8b9fd3961041f35ee20def4958301e1089
}

openal-soft_build() {  # <simulator|device>
    prepare_source "openal-soft-$OPENAL_SOFT_VERSION.tar.bz2"
    target_env "$1"
    local backend options=(
        -DLIBTYPE=STATIC -DALSOFT_REQUIRE_COREAUDIO=ON -DALSOFT_DLOPEN=OFF
        -DALSOFT_UTILS=OFF -DALSOFT_NO_CONFIG_UTIL=ON -DALSOFT_EXAMPLES=OFF -DALSOFT_TESTS=OFF
        -DALSOFT_INSTALL_CONFIG=OFF -DALSOFT_INSTALL_HRTF_DATA=OFF -DALSOFT_INSTALL_AMBDEC_PRESETS=OFF
        # the host's pkg-config would report Homebrew's macOS packages
        -DPKG_CONFIG_EXECUTABLE= -DCMAKE_DISABLE_FIND_PACKAGE_SDL3=ON
        # the 27 SDKs declare AURenderCallback [[clang::nonblocking]]; 1.25.2's CoreAudio callbacks are not annotated
        # and OpenAL Soft adds -Werror=function-effects whenever clang supports it. Skips the analysis only, same code.
        # ponytail: drop once a release annotates the CoreAudio callbacks (upstream 2dc741b54a: playback only)
        -DHAVE_WFUNCTION_EFFECTS=OFF
    )
    for backend in PIPEWIRE PULSEAUDIO ALSA OSS SOLARIS SNDIO JACK OBOE OPENSL PORTAUDIO; do
        options+=("-DALSOFT_BACKEND_$backend=OFF")
    done
    cmake_build "$BUILD_DIR/openal-soft/src" "${options[@]}"
}

openal-soft_xcframework() {
    xcframework OpenAL install/lib/libopenal.a install/include
}
