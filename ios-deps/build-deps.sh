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
DEPS=()

usage() {
    cat <<EOF
Usage: $SCRIPT <command> [args]

  download   <all|dep>                          (re-)download source -> ios-deps/source
  build      <all|dep> [simulator|device|both]  build xcframework -> ios-deps/artifacts
             fetches/extracts/patches what is missing, builds prerequisites first
             default: both
  clean      <all|dep>                          remove ios-deps/build/<dep> + its xcframeworks
  dist-clean <all|dep>                          clean + remove ios-deps/source/<dep>

Dependencies (build order): ${DEPS[*]:-(none yet)}
EOF
}

die() { echo "error: $*" >&2; exit 1; }

load_recipe() {
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

BUILT=()
build_dep() {
    local dep=$1 req target
    [[ " ${BUILT[*]-} " == *" $dep "* ]] && return 0
    load_recipe "$dep"
    local requires=("${DEP_REQUIRES[@]+"${DEP_REQUIRES[@]}"}")
    for req in "${requires[@]+"${requires[@]}"}"; do build_dep "$req"; done
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
