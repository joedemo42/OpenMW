# Bullet: OpenMW's collision/physics library. The version OpenMW's extern/CMakeLists.txt pins, with its settings
# (double precision, Bullet 2 multithreading, no Bullet 3/extras/demos/tests). OpenMW links BulletCollision and
# LinearMath, merged into libBullet.a; headers in include/bullet (as a desktop install).
DEP_ARTIFACTS=(Bullet)
# Gimpact (in BulletCollision) is LGPL, BSD or zlib: used under zlib
DEP_LICENSES=(LICENSE.txt)
BULLET_VERSION=3.17

bullet_download() {
    fetch "https://github.com/bulletphysics/bullet3/archive/refs/tags/$BULLET_VERSION.tar.gz" \
        baa642c906576d4d98d041d0acb80d85dd6eff6e3c16a009b1abf1ccd2bc0a61
}

bullet_build() {  # <simulator|device>
    prepare_source "$BULLET_VERSION.tar.gz"
    target_env "$1"
    cmake_build "$BUILD_DIR/bullet/src" \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5  `# Bullet declares CMake 2.4.3, which CMake 4 refuses` \
        -DUSE_DOUBLE_PRECISION=ON -DBULLET2_MULTITHREADING=ON -DBUILD_BULLET3=OFF -DBUILD_EXTRAS=OFF \
        -DBUILD_OPENGL3_DEMOS=OFF -DBUILD_BULLET2_DEMOS=OFF -DBUILD_CPU_DEMOS=OFF -DBUILD_UNIT_TESTS=OFF \
        -DBUILD_CLSOCKET=OFF -DBUILD_ENET=OFF \
        -DINSTALL_LIBS=ON  `# off by default for generators other than Makefiles` \
        -DCMAKE_DISABLE_FIND_PACKAGE_OpenGL=ON  # only for the demos

    local lib libs=()
    for lib in BulletCollision LinearMath; do libs+=("$TARGET_DIR/install/lib/lib$lib.a"); done
    mkdir -p "$TARGET_DIR/lib"
    libtool -static -no_warning_for_no_symbols -o "$TARGET_DIR/lib/libBullet.a" "${libs[@]}"
    [ -z "$(strong_duplicates "$TARGET_DIR/lib/libBullet.a" symbols)" ] \
        || die "libBullet.a: strong symbols defined more than once"
}

bullet_xcframework() {
    xcframework Bullet lib/libBullet.a install/include
}
