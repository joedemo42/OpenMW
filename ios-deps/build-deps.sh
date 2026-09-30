#!/bin/bash
# Builds the native iOS dependencies of the OpenMW iOS port as xcframeworks.
# One recipe per dependency in recipes/<dep>.sh, providing:
#   DEP_REQUIRES=(<deps>)   prerequisites (must appear earlier in DEPS)
#   DEP_ARTIFACTS=(<names>) xcframeworks it produces ($ARTIFACTS_DIR/<name>.xcframework)
#   <dep>_download          fetch pinned source into $SOURCE_DIR/<dep>
#   <dep>_build <target>    build one target (simulator|device) from $BUILD_DIR/<dep>
#   <dep>_xcframework       create $ARTIFACTS_DIR/<name>.xcframework(s) from the built targets
set -euo pipefail

DEPS_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="$DEPS_DIR/source"
BUILD_DIR="$DEPS_DIR/build"
ARTIFACTS_DIR="$DEPS_DIR/artifacts"
SCRIPT="${0#"$PWD/"}"

# Build order: every dependency after its prerequisites.
DEPS=(moltenvk mesa sdl2 libpng libjpeg-turbo freetype osg lz4)

usage() {
    cat <<EOF
Usage: $SCRIPT <command> [args]

  download   <all|dep>                          (re-)download source -> ios-deps/source
  build      <all|dep> [simulator|device|both]  build xcframework -> ios-deps/artifacts
             fetches/extracts/patches what is missing, builds missing prerequisites first
             default: both
  clean      <all|dep>                          remove ios-deps/build/<dep> + its xcframeworks
  dist-clean <all|dep>                          clean + remove ios-deps/source/<dep>

Dependencies (build order): ${DEPS[*]:-(none yet)}
EOF
}

die() { echo "error: $*" >&2; exit 1; }

# ---- helpers for recipes ($DEP is the dependency being processed) ----

MIN_IOS=26.0
JOBS=$(sysctl -n hw.ncpu)

# Toolchain values for one target: SDK, SDK_PATH, TRIPLE, TARGET_DIR (build/<dep>/<target>).
target_env() {  # <simulator|device>
    case "$1" in
        simulator) SDK=iphonesimulator; TRIPLE="arm64-apple-ios$MIN_IOS-simulator" ;;
        device) SDK=iphoneos; TRIPLE="arm64-apple-ios$MIN_IOS" ;;
    esac
    SDK_PATH=$(xcrun --sdk "$SDK" --show-sdk-path)
    TARGET_DIR="$BUILD_DIR/$DEP/$1"
}

# Downloads <url> into source/<dep>/ and checks its sha256.
fetch() {  # <url> <sha256>
    local file
    file="$SOURCE_DIR/$DEP/$(basename "$1")"
    mkdir -p "$SOURCE_DIR/$DEP"
    curl -fsSL --retry 3 -o "$file.part" "$1" || die "download failed: $1"
    echo "$2  $file.part" | shasum -a 256 -c - > /dev/null || die "sha256 mismatch: $1"
    mv "$file.part" "$file"
}

# Clones <repo> at <tag> into source/<dep> and checks the tag resolves to <commit>.
fetch_git() {  # <repo> <tag> <commit>
    git clone -q --depth 1 --branch "$2" "$1" "$SOURCE_DIR/$DEP"
    [ "$(git -C "$SOURCE_DIR/$DEP" rev-parse HEAD)" = "$3" ] || die "$1 $2 is not commit $3"
}

# Fills build/<dep>/src from source/<dep> (tarball or tree) and applies patches/<dep>/*.patch.
# Re-prepares (and drops old build output) when the source version or the patch set changes.
prepare_source() {  # <tarball name | ->  ('-' copies the source tree)
    local dir="$BUILD_DIR/$DEP" stamp p
    [ "$1" = - ] || [ -f "$SOURCE_DIR/$DEP/$1" ] || { echo "==> download $DEP"; "${DEP}_download"; }
    stamp="$1 $( (cat "$DEPS_DIR/patches/$DEP"/*.patch 2>/dev/null || true) | shasum -a 256 | cut -d' ' -f1)"
    [ "$(cat "$dir/.prepared" 2>/dev/null)" = "$stamp" ] && return
    rm -rf "$dir" && mkdir -p "$dir/src"
    if [ "$1" = - ]; then
        rsync -a --exclude .git "$SOURCE_DIR/$DEP/" "$dir/src/"
    else
        tar -xf "$SOURCE_DIR/$DEP/$1" -C "$dir/src" --strip-components 1
    fi
    for p in "$DEPS_DIR/patches/$DEP"/*.patch; do
        [ -e "$p" ] || continue
        echo "==> patch $DEP: $(basename "$p")"
        patch -d "$dir/src" -p1 --forward --batch < "$p" > /dev/null || die "patch $(basename "$p") failed"
    done
    echo "$stamp" > "$dir/.prepared"
}

# Configures, builds and installs a CMake project for the current target (after target_env)
# into build/<dep>/<target>/install (static, Release).
cmake_build() {  # <source dir> [cmake args...]
    local src=$1; shift
    cmake -S "$src" -B "$TARGET_DIR/build" -G Ninja -Wno-dev \
        -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$SDK" -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_IOS" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_INSTALL_PREFIX="$TARGET_DIR/install" "$@"
    cmake --build "$TARGET_DIR/build" -j "$JOBS"
    cmake --install "$TARGET_DIR/build" > /dev/null
}

# Creates artifacts/<name>.xcframework from build/<dep>/<target>/<lib> (+ <headers> dir)
# for every built target, then checks each requested target's slice (arm64, platform).
xcframework() {  # <name> <lib path> [<headers path>]   (paths relative to build/<dep>/<target>)
    local name=$1 out="$ARTIFACTS_DIR/$1.xcframework" args=() t
    for t in simulator device; do
        [ -f "$BUILD_DIR/$DEP/$t/$2" ] || continue
        args+=(-library "$BUILD_DIR/$DEP/$t/$2")
        [ -z "${3:-}" ] || args+=(-headers "$BUILD_DIR/$DEP/$t/$3")
    done
    rm -rf "$out" && mkdir -p "$ARTIFACTS_DIR"
    xcodebuild -create-xcframework "${args[@]}" -output "$out" > /dev/null
    for t in "${TARGETS[@]}"; do
        # LC_BUILD_VERSION platform: 2 = iOS, 7 = iOS simulator
        local slice=ios-arm64 platform=2 lib platforms
        [ "$t" = simulator ] && { slice=ios-arm64-simulator; platform=7; }
        lib="$out/$slice/$(basename "$2")"
        [ -f "$lib" ] || die "$name.xcframework: missing $t slice"
        [ "$(lipo -archs "$lib")" = arm64 ] || die "$name.xcframework: $t slice is not arm64-only"
        platforms=$(otool -l "$lib" | awk '/cmd LC_BUILD_VERSION/ {f = 1} f && $1 == "platform" {print $2; f = 0}' | sort -u)
        [ "$platforms" = "$platform" ] || die "$name.xcframework: $t slice platforms '${platforms//$'\n'/ }', expected $platform"
    done
    echo "==> $name.xcframework ok (${TARGETS[*]})"
}

# Merged static archives must not define a strong symbol twice: OpenMW links with -all_load on Apple.
# strong_duplicates <lib> <drop|symbols>: removable duplicate members, or symbols defined more than once
strong_duplicates() {
    nm -A -m "$1" 2> /dev/null | awk -v mode="$2" '
        /\(undefined\)/ || / weak / || !/ external / {next}
        { split($1, p, ":"); member = p[2]; sym = $NF
          count[sym]++; defs[sym] = defs[sym] " " member; msyms[member] = msyms[member] " " sym }
        END {
            for (s in count) if (count[s] > 1) {
                if (mode == "symbols") print s
                n = split(defs[s], ms, " "); for (i = 2; i <= n; i++) drop[ms[i]] = 1
            }
            if (mode != "drop") exit
            for (m in drop) {
                ok = 1; n = split(msyms[m], ss, " ")
                for (j = 1; j <= n; j++) if (count[ss[j]] < 2) ok = 0
                if (ok) print m
            }
        }'
}

load_recipe() {
    DEP=$1
    DEP_REQUIRES=()
    DEP_ARTIFACTS=()
    # shellcheck source=/dev/null
    source "$DEPS_DIR/recipes/$1.sh"
}

# Expands <all|dep> into a dependency list.
resolve() {
    [ $# -eq 1 ] || die "expected exactly one of: all ${DEPS[*]-}"
    if [ "$1" = all ]; then
        SELECTED=(${DEPS[@]+"${DEPS[@]}"})
        return
    fi
    local dep
    for dep in ${DEPS[@]+"${DEPS[@]}"}; do
        [ "$dep" = "$1" ] && { SELECTED=("$1"); return; }
    done
    die "unknown dependency '$1' (supported: ${DEPS[*]:-none})"
}

cmd_download() {
    local dep
    for dep in ${SELECTED[@]+"${SELECTED[@]}"}; do
        load_recipe "$dep"
        rm -rf "${SOURCE_DIR:?}/$dep"
        mkdir -p "$SOURCE_DIR"
        echo "==> download $dep"
        "${dep}_download"
    done
}

# True if every xcframework of <dep> has a slice for each requested target.
artifacts_present() {  # <dep>
    local name t slice
    load_recipe "$1"
    for name in "${DEP_ARTIFACTS[@]+"${DEP_ARTIFACTS[@]}"}"; do
        for t in "${TARGETS[@]}"; do
            slice=ios-arm64
            [ "$t" = simulator ] && slice=ios-arm64-simulator
            [ -d "$ARTIFACTS_DIR/$name.xcframework/$slice" ] || return 1
        done
    done
}

BUILT=()
build_dep() {
    local dep=$1 req target
    [[ " ${BUILT[*]-} " == *" $dep "* ]] && return 0
    load_recipe "$dep"
    local requires=("${DEP_REQUIRES[@]+"${DEP_REQUIRES[@]}"}")
    # prerequisites are only built when missing; 'build <prerequisite>' or 'build all' rebuilds them
    for req in "${requires[@]+"${requires[@]}"}"; do artifacts_present "$req" || build_dep "$req"; done
    load_recipe "$dep"
    [ -d "$SOURCE_DIR/$dep" ] || { mkdir -p "$SOURCE_DIR"; echo "==> download $dep"; "${dep}_download"; }
    for target in "${TARGETS[@]}"; do
        echo "==> build $dep ($target)"
        "${dep}_build" "$target"
    done
    echo "==> xcframework $dep"
    "${dep}_xcframework"
    BUILT+=("$dep")
}

cmd_build() {
    local dep
    for dep in ${SELECTED[@]+"${SELECTED[@]}"}; do build_dep "$dep"; done
}

cmd_clean() {
    local dep name
    for dep in ${SELECTED[@]+"${SELECTED[@]}"}; do
        load_recipe "$dep"
        echo "==> clean $dep"
        rm -rf "${BUILD_DIR:?}/$dep"
        for name in "${DEP_ARTIFACTS[@]+"${DEP_ARTIFACTS[@]}"}"; do
            rm -rf "${ARTIFACTS_DIR:?}/$name.xcframework"
        done
    done
}

cmd_dist_clean() {
    cmd_clean
    local dep
    for dep in ${SELECTED[@]+"${SELECTED[@]}"}; do rm -rf "${SOURCE_DIR:?}/$dep"; done
}

[ $# -eq 0 ] && { usage; exit 0; }
command=$1; shift
case "$command" in
    -h|--help) usage; exit 0 ;;
    download) resolve "$@"; cmd_download ;;
    build)
        [ $# -ge 1 ] && [ $# -le 2 ] || die "usage: $SCRIPT build <all|dep> [simulator|device|both]"
        case "${2:-both}" in
            simulator) TARGETS=(simulator) ;;
            device) TARGETS=(device) ;;
            both) TARGETS=(simulator device) ;;
            *) die "unknown target '$2' (simulator|device|both)" ;;
        esac
        resolve "$1"; cmd_build ;;
    clean) resolve "$@"; cmd_clean ;;
    dist-clean) resolve "$@"; cmd_dist_clean ;;
    *) usage >&2; exit 1 ;;
esac
