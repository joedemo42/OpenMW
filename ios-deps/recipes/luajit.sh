# LuaJIT: OpenMW's Lua scripting. v2.1 is a rolling release: pinned commit. Interpreter only (LuaJIT disables its
# JIT on iOS itself), static, default options (Lua 5.1 semantics, as distribution packages). LuaJIT builds in its
# source tree and runs host tools (minilua, buildvm) during the build: one source copy per target.
DEP_ARTIFACTS=(LuaJIT)
LUAJIT_COMMIT=c6ffc141a8762b41703f9287d63d93622a13dd8f

luajit_download() {
    fetch "https://github.com/LuaJIT/LuaJIT/archive/$LUAJIT_COMMIT.tar.gz" \
        6e5fec07750add912e7c3eae0c194d24cd6d023714e1f04a0298a5b4819e4457
}

luajit_build() {  # <simulator|device>
    prepare_source "$LUAJIT_COMMIT.tar.gz"
    target_env "$1"
    local src="$TARGET_DIR/src/src" header
    mkdir -p "$TARGET_DIR/src"
    rsync -a "$BUILD_DIR/luajit/src/" "$TARGET_DIR/src/"
    make -C "$src" -j "$JOBS" libluajit.a BUILDMODE=static TARGET_SYS=iOS CC=clang \
        HOST_CC="$(xcrun --sdk macosx -f clang) -isysroot $(xcrun --sdk macosx --show-sdk-path)" \
        CROSS="$(dirname "$(xcrun --sdk "$SDK" -f clang)")/" TARGET_FLAGS="-target $TRIPLE -isysroot $SDK_PATH"

    # what LuaJIT's make install installs: libluajit-5.1.a, include/luajit-2.1
    mkdir -p "$TARGET_DIR/lib" "$TARGET_DIR/include/luajit-2.1"
    cp "$src/libluajit.a" "$TARGET_DIR/lib/libluajit-5.1.a"
    for header in lua.h lualib.h lauxlib.h luaconf.h lua.hpp luajit.h; do
        cp "$src/$header" "$TARGET_DIR/include/luajit-2.1/"
    done
}

luajit_xcframework() {
    xcframework LuaJIT lib/libluajit-5.1.a include
}
