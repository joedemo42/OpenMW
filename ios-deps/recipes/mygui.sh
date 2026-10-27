# MyGUI: OpenMW's GUI toolkit. The version OpenMW's extern/CMakeLists.txt pins, with its settings; render system
# Dummy as in OpenMW's macOS deps (OpenMW draws MyGUI through its own OSG render manager). Static, FreeType from
# this directory; OpenMW links libMyGUIEngine.a only.
DEP_REQUIRES=(freetype)
DEP_ARTIFACTS=(MyGUI)
DEP_LICENSES=(COPYING.MIT)
MYGUI_VERSION=3.4.3

mygui_download() {
    fetch "https://github.com/MyGUI/mygui/archive/refs/tags/MyGUI$MYGUI_VERSION.zip" \
        5dd90e8d2c069377f1690db075c9838086e540572e4d8ebdcddb6d76a25309c3
}

mygui_build() {  # <simulator|device>
    prepare_source "MyGUI$MYGUI_VERSION.zip"
    target_env "$1"
    local slice=ios-arm64
    [ "$1" = simulator ] && slice=ios-arm64-simulator
    local freetype="$ARTIFACTS_DIR/freetype.xcframework/$slice"
    cmake_build "$BUILD_DIR/mygui/src" -DMYGUI_STATIC=ON -DMYGUI_RENDERSYSTEM=1 -DMYGUI_DISABLE_PLUGINS=ON \
        -DMYGUI_BUILD_DEMOS=OFF -DMYGUI_BUILD_PLUGINS=OFF -DMYGUI_BUILD_TOOLS=OFF -DMYGUI_DONT_USE_OBSOLETE=ON \
        -DFREETYPE_INCLUDE_DIR_ft2build="$freetype/Headers/freetype2" \
        -DFREETYPE_INCLUDE_DIR_freetype2="$freetype/Headers/freetype2" -DFREETYPE_LIBRARY="$freetype/libfreetype.a" \
        -DCMAKE_DISABLE_FIND_PACKAGE_SDL2=ON  # only for demos and tools
}

mygui_xcframework() {
    xcframework MyGUI install/lib/libMyGUIEngineStatic.a install/include
}
