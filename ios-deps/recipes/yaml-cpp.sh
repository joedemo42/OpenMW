# yaml-cpp: OpenMW's settings, shader and Lua config files. The commit OpenMW's extern/CMakeLists.txt pins (0.8.0 +
# CMake 4 fix). Static, no tools/tests/contrib (OpenMW uses none of them).
DEP_ARTIFACTS=(yaml-cpp)
DEP_LICENSES=(LICENSE)
YAML_CPP_COMMIT=c2680200486572baf8221ba052ef50b58ecd816e

yaml-cpp_download() {
    fetch "https://github.com/jbeder/yaml-cpp/archive/$YAML_CPP_COMMIT.zip" \
        9cbd53685951e13eaa3257dd33b9f2cdcdda144488ce93c7f438c72533faf303
}

yaml-cpp_build() {  # <simulator|device>
    prepare_source "$YAML_CPP_COMMIT.zip"
    target_env "$1"
    cmake_build "$BUILD_DIR/yaml-cpp/src" -DYAML_BUILD_SHARED_LIBS=OFF -DYAML_CPP_BUILD_TOOLS=OFF \
        -DYAML_CPP_BUILD_TESTS=OFF -DYAML_CPP_BUILD_CONTRIB=OFF -DYAML_CPP_FORMAT_SOURCE=OFF
}

yaml-cpp_xcframework() {
    xcframework yaml-cpp install/lib/libyaml-cpp.a install/include
}
