# SDL2: window, input, events. Patched for the UIScene life cycle (required with the iOS 27 SDK).
DEP_ARTIFACTS=(SDL2 SDL2main)

sdl2_download() {
    fetch https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.tar.gz \
        5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165
}

sdl2_build() {  # <simulator|device>
    prepare_source SDL2-2.32.10.tar.gz
    target_env "$1"
    # no OpenGL/GLES backends: GL comes from Mesa (EGL), and OpenGLES.framework would export a second set of gl*
    cmake_build "$BUILD_DIR/sdl2/src" -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST=OFF -DSDL_OPENGL=OFF -DSDL_OPENGLES=OFF
}

sdl2_xcframework() {
    xcframework SDL2 install/lib/libSDL2.a install/include
    xcframework SDL2main install/lib/libSDL2main.a
}
