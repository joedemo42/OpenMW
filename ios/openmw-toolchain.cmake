# CMake toolchain for building OpenMW's own libraries for iOS (used by ios/build.sh).
# The target follows CMAKE_OSX_SYSROOT (iphoneos | iphonesimulator), which CMake also passes to try_compile.
# Dependencies are found in the install trees of ios-deps/build-deps.sh; the app links their xcframeworks.

set(CMAKE_SYSTEM_NAME iOS)
# cache entries: CMake's Darwin platform creates them on the first run, which drops normal variables of the same name
# under OpenMW's policy level (CMP0126 OLD) -> no -arch in a fresh build dir, full rebuild on the next configure
set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING "" FORCE)
set(CMAKE_OSX_DEPLOYMENT_TARGET 18.0 CACHE STRING "" FORCE)

if(CMAKE_OSX_SYSROOT MATCHES "[Ss]imulator")
    set(_ios_target simulator)
elseif(CMAKE_OSX_SYSROOT MATCHES "iphoneos|iPhoneOS")
    set(_ios_target device)
else()
    message(FATAL_ERROR "CMAKE_OSX_SYSROOT must be iphoneos or iphonesimulator, got '${CMAKE_OSX_SYSROOT}'")
endif()

set(_ios_deps "${CMAKE_CURRENT_LIST_DIR}/../ios-deps/build")
set(CMAKE_FIND_ROOT_PATH)
foreach(_dep sdl2 mesa osg libpng libjpeg-turbo freetype lz4 boost yaml-cpp bullet mygui recastnavigation icu ffmpeg
        openal-soft)
    list(APPEND CMAKE_FIND_ROOT_PATH "${_ios_deps}/${_dep}/${_ios_target}/install")
endforeach()
list(APPEND CMAKE_FIND_ROOT_PATH "${_ios_deps}/luajit/${_ios_target}")  # include/luajit-2.1, lib (no install tree)

# pkg-config (FFmpeg's versions come only from it) sees the dependencies' .pc files only, never the host's
set(_ios_pc_dirs)
foreach(_root ${CMAKE_FIND_ROOT_PATH})
    if(EXISTS "${_root}/lib/pkgconfig")
        list(APPEND _ios_pc_dirs "${_root}/lib/pkgconfig")
    endif()
endforeach()
string(REPLACE ";" ":" _ios_pc_dirs "${_ios_pc_dirs}")
set(ENV{PKG_CONFIG_LIBDIR} "${_ios_pc_dirs}")
set(ENV{PKG_CONFIG_PATH} "")

# OSG's headers include <GL/gl.h>: Mesa's, also for try_compile checks (CheckOsgMultiview)
set(CMAKE_C_FLAGS_INIT "-isystem ${_ios_deps}/mesa/${_ios_target}/install/include")
set(CMAKE_CXX_FLAGS_INIT "-isystem ${_ios_deps}/mesa/${_ios_target}/install/include")
