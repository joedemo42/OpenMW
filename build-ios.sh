#!/bin/bash
# User-facing dispatcher for the iOS port. No build logic here.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${0#"$PWD/"}"

usage() {
    cat <<EOF
Usage: $SCRIPT <command> [args] [options]

  deps <command> [args]      native dependencies (ios-deps/build-deps.sh):
    download   <all|dep>                          (re-)download source
    build      <all|dep> [simulator|device|both]  build xcframework, default: both
    clean      <all|dep>                          remove build dir + xcframeworks
    dist-clean <all|dep>                          clean + remove source

  app (ios/build.sh), target: --simulator <name|UDID> | --device <name|UDID>
    build   [simulator|device|both]               default: simulator
    install [target] [--no-build]
    run     [target] [--seconds <1-45>] [--label <name>] [--no-build] [--no-install] [-- <app args>]
    ipa     [--unsigned]
    upload  [--notes <text>|--notes-file <path>]  signed IPA + release notes -> repo server

  clean [app|deps|all]       default: app

Details: $SCRIPT deps --help, ios/build.sh --help
EOF
}

[ $# -eq 0 ] && { usage; exit 0; }
command=$1; shift
case "$command" in
    -h|--help) usage ;;
    deps) exec "$ROOT/ios-deps/build-deps.sh" "$@" ;;
    build|install|run|ipa|upload) exec "$ROOT/ios/build.sh" "$command" "$@" ;;
    clean)
        [ $# -le 1 ] || { usage >&2; exit 1; }
        case "${1:-app}" in
            app) exec "$ROOT/ios/build.sh" clean ;;
            deps) exec "$ROOT/ios-deps/build-deps.sh" clean all ;;
            all) "$ROOT/ios/build.sh" clean && exec "$ROOT/ios-deps/build-deps.sh" clean all ;;
            *) usage >&2; exit 1 ;;
        esac ;;
    *) usage >&2; exit 1 ;;
esac
