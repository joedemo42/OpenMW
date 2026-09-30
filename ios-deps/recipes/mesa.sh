# Mesa: desktop OpenGL (compatibility profile) through the Zink driver on MoltenVK, EGL surfaceless.
# Mesa only builds shared libraries; the static libMesa.a is assembled from the link inputs
# (objects + internal archives) of libEGL and libgallium plus libglapi_bridge (public gl* entry points).
DEP_REQUIRES=(moltenvk)
DEP_ARTIFACTS=(Mesa)
# 25.1.x: latest release working with MoltenVK. From 25.2 on, zink hard-requires robustness2
# nullDescriptor, which MoltenVK does not provide (25.1 still falls back to dummy descriptors).
MESA_VERSION=25.1.9

mesa_download() {
    fetch "https://archive.mesa3d.org/mesa-$MESA_VERSION.tar.xz" \
        412df33a1bb3c785ed698555a3972118a37c458e7accf6ae53f4bb87b3db454a
}

mesa_build() {  # <simulator|device>
    prepare_source "mesa-$MESA_VERSION.tar.xz"
    target_env "$1"
    local venv="$BUILD_DIR/.venv" bison slice=ios-arm64 subsystem=ios build="$TARGET_DIR/build"
    [ "$1" = simulator ] && { slice=ios-arm64-simulator; subsystem=ios-simulator; }

    # host tools: Python modules for Mesa's code generators, bison >= 3 (Homebrew keg)
    [ -x "$venv/bin/python3" ] || python3 -m venv "$venv"
    "$venv/bin/pip" install -q --disable-pip-version-check mako==1.4.3 PyYAML==6.0.3 packaging==26.3
    bison="$(brew --prefix bison@3.8 2> /dev/null)/bin"
    [ -x "$bison/bison" ] || die "host tool missing: Homebrew bison@3.8"
    local path="$venv/bin:$bison:$PATH"

    # zink looks for <moltenvk-dir>/include
    mkdir -p "$TARGET_DIR/moltenvk"
    ln -sfn "$ARTIFACTS_DIR/MoltenVK.xcframework/$slice/Headers" "$TARGET_DIR/moltenvk/include"

    local flags="'-target', '$TRIPLE', '-isysroot', '$SDK_PATH'"
    # Vulkan platform macros as MoltenVK's mvk_vulkan.h sets them on iOS; must be global so the first
    # vulkan.h include already declares the iOS/Metal types (upstream does this via -Dplatforms=macos)
    local defines="'-DVK_USE_PLATFORM_IOS_MVK', '-DVK_USE_PLATFORM_METAL_EXT'"
    # Mesa's own dylibs (only built to collect their link inputs) link the static MoltenVK (patched zink).
    # No -undefined dynamic_lookup: it would make meson's function checks succeed for missing functions.
    local link="$flags, '-L$ARTIFACTS_DIR/MoltenVK.xcframework/$slice', '-lMoltenVK', '-lc++'"
    local framework
    for framework in Metal IOSurface QuartzCore CoreGraphics Foundation UIKit; do
        link="$link, '-framework', '$framework'"
    done
    cat > "$TARGET_DIR/cross.ini.new" << EOF
[binaries]
c = '$(xcrun --sdk "$SDK" -f clang)'
cpp = '$(xcrun --sdk "$SDK" -f clang++)'
objc = '$(xcrun --sdk "$SDK" -f clang)'
ar = '$(xcrun --sdk "$SDK" -f ar)'
strip = '$(xcrun --sdk "$SDK" -f strip)'

[built-in options]
c_args = [$flags, $defines]
cpp_args = [$flags, $defines]
objc_args = [$flags, $defines]
c_link_args = [$link]
cpp_link_args = [$link]
objc_link_args = [$link]

[host_machine]
system = 'darwin'
subsystem = '$subsystem'
kernel = 'xnu'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
EOF
    local options=(
        --cross-file "$TARGET_DIR/cross.ini" --prefix "$TARGET_DIR/install" --buildtype=release -Db_ndebug=true
        -Dplatforms= -Dglx=disabled -Degl=enabled -Degl-native-platform=surfaceless
        -Dgallium-drivers=zink -Dvulkan-drivers= -Dmoltenvk-dir="$TARGET_DIR/moltenvk"
        -Dopengl=true -Dgles1=disabled -Dgles2=disabled -Dgbm=disabled -Dglvnd=disabled
        -Dllvm=disabled -Dshader-cache=disabled -Dxmlconfig=disabled -Dzstd=disabled
        -Dlibunwind=disabled -Dvalgrind=disabled -Dbuild-tests=false -Dgallium-va=disabled
        -Dgallium-rusticl=false
    )
    # re-configure from scratch when the cross file or the options change
    printf '%s\n' "${options[@]}" >> "$TARGET_DIR/cross.ini.new"
    if ! cmp -s "$TARGET_DIR/cross.ini.new" "$TARGET_DIR/setup.stamp" || [ ! -f "$build/build.ninja" ]; then
        rm -rf "$build"
        sed '/^--cross-file$/,$d' "$TARGET_DIR/cross.ini.new" > "$TARGET_DIR/cross.ini"
        PATH="$path" meson setup "$build" "$BUILD_DIR/mesa/src" "${options[@]}"
        mv "$TARGET_DIR/cross.ini.new" "$TARGET_DIR/setup.stamp"
    fi
    rm -f "$TARGET_DIR/cross.ini.new"
    local bridge
    bridge=$(ninja -C "$build" -t targets all | awk -F: '/\/libglapi_bridge\.a:/ && !found {print $1; found = 1}')
    [ -n "$bridge" ] || die "no libglapi_bridge target"
    PATH="$path" ninja -C "$build"
    PATH="$path" ninja -C "$build" "$bridge"
    PATH="$path" meson install -C "$build" --no-rebuild --quiet

    # static library from the link inputs of the shared libraries
    local dylib inputs=()
    for dylib in $(ninja -C "$build" -t targets all | awk -F: '/(libEGL|libgallium)[^:]*\.dylib:/ {print $1}'); do
        # shellcheck disable=SC2207 # paths without spaces
        inputs+=($(ninja -C "$build" -t commands "$dylib" | tail -1 | tr ' ,' '\n\n' | grep -E '\.(o|a)$'))
    done
    [ ${#inputs[@]} -gt 0 ] || die "no libEGL/libgallium link inputs found"
    # libEGL links the dlopen() pipe loader, libgallium the static one (with zink); merged, only the static
    # one may stay, or its symbols would resolve to the dynamic variant and zink would never be linked
    # shellcheck disable=SC2207
    inputs=($(printf '%s\n' "${inputs[@]}" | grep -v '/libpipe_loader_dynamic\.a$'))
    inputs+=("$bridge")
    mkdir -p "$TARGET_DIR/lib"
    # shellcheck disable=SC2046
    (cd "$build" && libtool -static -no_warning_for_no_symbols -o "$TARGET_DIR/lib/libMesa.a" \
        $(printf '%s\n' "${inputs[@]}" | awk '!seen[$0]++'))

    # The generated vk_dispatch_table.c is built into both libzink and libvulkan_util: drop the second copy
    # (harmless for on-demand linking, fatal with -all_load). Any other duplicate means diverging code.
    local lib="$TARGET_DIR/lib/libMesa.a" member
    for member in $(strong_duplicates "$lib" drop); do
        [[ "$member" == *vk_dispatch_table.c.o ]] || die "libMesa.a: unexpected duplicate member $member"
        ar -d "$lib" "$member"
    done
    ranlib "$lib" 2> /dev/null
    [ -z "$(strong_duplicates "$lib" symbols)" ] || die "libMesa.a: duplicate strong symbols remain"
}

mesa_xcframework() {
    xcframework Mesa lib/libMesa.a install/include
}
