# GLM (OpenGL Mathematics): vector/matrix types of OpenMW's Lua bindings and math helpers (OpenMW 0.53+). The release
# vcpkg builds for OpenMW's macOS/Windows CI (OpenMW's extern/CMakeLists.txt fetches 1.0.1), built like vcpkg: static
# library (explicit template instantiations) + headers + CMake config for find_package(glm). With OpenMW's global
# GLM_FORCE_CTOR_INIT, as upstream's bundled build: one glm for every translation unit (ODR).
DEP_ARTIFACTS=(GLM)
DEP_LICENSES=(copying.txt)  # MIT (or the Happy Bunny License)
GLM_VERSION=1.0.3

glm_download() {
    fetch "https://github.com/g-truc/glm/archive/refs/tags/$GLM_VERSION.tar.gz" \
        6775e47231a446fd086d660ecc18bcd076531cfedd912fbd66e576b118607001
}

glm_build() {  # <simulator|device>
    prepare_source "$GLM_VERSION.tar.gz"
    target_env "$1"
    cmake_build "$BUILD_DIR/glm/src" -DGLM_BUILD_LIBRARY=ON -DGLM_BUILD_TESTS=OFF -DGLM_BUILD_INSTALL=ON \
        -DCMAKE_CXX_FLAGS=-DGLM_FORCE_CTOR_INIT
}

glm_xcframework() {
    xcframework GLM install/lib/libglm.a install/include
}
