# OpenSceneGraph from the OpenMW fork (the commit OpenMW's extern/CMakeLists.txt pins): static, desktop GL2 profile
# on Mesa's GL headers, no windowing system (OpenMW brings its own SDL window, as on Android). The libraries and
# plugins OpenMW uses are merged into libOpenSceneGraph.a, shipped with the headers of all OSG libraries.
DEP_REQUIRES=(mesa libpng libjpeg-turbo freetype)
DEP_ARTIFACTS=(OpenSceneGraph)
# OSGPL (LGPL 2.1 with exceptions, both in LICENSE.txt); GLU tessellator (SGI-B), MIT and plain LGPL-2.1+ files
DEP_LICENSES=(LICENSE.txt)
DEP_NOTICES=(src/osg/glu/libtess/tess.cpp src/osgUtil/PerlinNoise.cpp src/osgViewer/Keystone.cpp
    src/osgPlugins/bmp/ReaderWriterBMP.cpp include/osgAnimation/Vec3Packed)
OSG_COMMIT=01cc2b585c8456a4ff843066b7e1a8715558289f
# OpenMW's USED_OSG_COMPONENTS (+ OpenThreads) and USED_OSG_PLUGINS (+ serializers_osg), without dae (Collada)
OSG_LIBRARIES=(OpenThreads osg osgDB osgUtil osgGA osgText osgViewer osgAnimation osgFX osgParticle osgShadow osgSim)
OSG_PLUGINS=(bmp dds freetype jpeg osg png tga)

osg_download() {
    fetch "https://github.com/OpenMW/osg/archive/$OSG_COMMIT.zip" \
        3fe02f29906cf371ffc9e49d979c1b517669960f67a57269238bc40d58b651b7
}

osg_build() {  # <simulator|device>
    prepare_source "$OSG_COMMIT.zip"
    target_env "$1"
    local slice=ios-arm64 plugin lib libs=()
    [ "$1" = simulator ] && slice=ios-arm64-simulator
    local mesa="$ARTIFACTS_DIR/Mesa.xcframework/$slice/Headers" png="$ARTIFACTS_DIR/libpng.xcframework/$slice"
    local jpeg="$ARTIFACTS_DIR/libjpeg.xcframework/$slice" freetype="$ARTIFACTS_DIR/freetype.xcframework/$slice"
    local options=(
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5  # OSG declares CMake 2.8, which CMake 4 refuses
        -DCMAKE_CXX_STANDARD=17             # as OpenMW's own OSG build
        # settings of OpenMW's extern/CMakeLists.txt
        -DDYNAMIC_OPENTHREADS=OFF -DDYNAMIC_OPENSCENEGRAPH=OFF -DOPENGL_PROFILE=GL2
        -DBUILD_OSG_APPLICATIONS=OFF -DBUILD_OSG_DEPRECATED_SERIALIZERS=OFF -DOSG_FIND_3RD_PARTY_DEPS=OFF
        -DBUILD_OSG_PLUGINS_BY_DEFAULT=OFF
        # OSG treats a CMake iOS build as macOS: desktop GL from Mesa's headers (<GL/gl.h>, not <OpenGL/gl.h>;
        # _INIT because OSG appends to the cached flags on the first run), no windowing system (Cocoa/EAGL),
        # no macOS framework lookups (not in the iOS SDK; NOTFOUND results fail the configure step)
        -DOSG_WINDOWING_SYSTEM=None -DOPENGL_HEADER1="#include <GL/gl.h>"
        -DCMAKE_C_FLAGS_INIT="-isystem $mesa" -DCMAKE_CXX_FLAGS_INIT="-isystem $mesa"
        -DCMAKE_DISABLE_FIND_PACKAGE_OpenGL=ON -DCARBON_LIBRARY= -DCOCOA_LIBRARY= -DOSG_TEXT_USE_FONTCONFIG=OFF
        # the host's pkg-config only knows host (Homebrew) packages
        -DPKG_CONFIG_EXECUTABLE=
        # OpenThreads' atomics checks run test programs (impossible when cross-compiling): GCC builtins,
        # not the deprecated OSAtomic functions
        -D_OPENTHREADS_ATOMIC_USE_GCC_BUILTINS_EXITCODE=0 -D_OPENTHREADS_ATOMIC_USE_BSD_ATOMIC_EXITCODE=1
        # image and font libraries from this directory
        -DPNG_PNG_INCLUDE_DIR="$png/Headers" -DPNG_LIBRARY="$png/libpng16.a"
        -DJPEG_INCLUDE_DIR="$jpeg/Headers" -DJPEG_LIBRARY="$jpeg/libjpeg.a"
        -DFREETYPE_INCLUDE_DIR_ft2build="$freetype/Headers/freetype2"
        -DFREETYPE_INCLUDE_DIR_freetype2="$freetype/Headers/freetype2" -DFREETYPE_LIBRARY="$freetype/libfreetype.a"
    )
    for plugin in "${OSG_PLUGINS[@]}"; do
        options+=("-DBUILD_OSG_PLUGIN_$(echo "$plugin" | tr '[:lower:]' '[:upper:]')=ON")
    done
    cmake_build "$BUILD_DIR/osg/src" "${options[@]}"

    # one archive with everything OpenMW links
    for lib in "${OSG_LIBRARIES[@]}"; do libs+=("$TARGET_DIR/install/lib/lib$lib.a"); done
    for plugin in "${OSG_PLUGINS[@]}" serializers_osg; do
        libs+=("$(echo "$TARGET_DIR"/install/lib/osgPlugins-*/libosgdb_"$plugin".a)")
    done
    for lib in "${libs[@]}"; do [ -f "$lib" ] || die "osg: $lib was not built"; done
    mkdir -p "$TARGET_DIR/lib"
    libtool -static -no_warning_for_no_symbols -o "$TARGET_DIR/lib/libOpenSceneGraph.a" "${libs[@]}" 2>&1 \
        | { grep -v 'same member name' || true; }
    [ -z "$(strong_duplicates "$TARGET_DIR/lib/libOpenSceneGraph.a" symbols)" ] \
        || die "libOpenSceneGraph.a: strong symbols defined more than once"
}

osg_xcframework() {
    xcframework OpenSceneGraph lib/libOpenSceneGraph.a install/include
}
