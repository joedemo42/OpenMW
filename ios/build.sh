#!/bin/bash
# Builds, installs and runs the Morrowind iOS app host.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${0#"$PWD/"}"
DERIVED="$REPO/DerivedData"
LOG_DIR="$REPO/log"
PROJECT="$REPO/ios/Morrowind-iOS.xcodeproj"
BUNDLE_ID=org.openmw.openmw
DEFAULT_SIMULATOR="iPad Air 11-inch (M4)"
REPO_SERVER=http://repo-server.invalid/upload/

usage() {
    cat <<EOF
Usage: $SCRIPT <command> [args] [options]
Target options: --simulator <name|UDID> | --device <name|UDID>  (default: $DEFAULT_SIMULATOR simulator)

  build   [simulator|device|both]   build app, increments build number once. default: simulator
  install [target]                  install current build on target (current: DerivedData/current-<slice>
                                    = CFBundleVersion of the slice's app). no current build -> exit 1
  run     [target] [--seconds <1-45>] [--label <name>] [-- <app args>]
          run installed app non-interactively (default: 45 s), logs + screenshot -> log/
          app not installed or installed build != current build -> exit 1
  ipa     [--unsigned]              current device build -> IPA in DerivedData/ipa. no current build -> exit 1
  upload  [--notes <text>|--notes-file <path>]
          ipa + release notes ("What's New") -> archive/ -> repo server. no current device build -> exit 1
  documents zip                     game data payload (./Data -> Data/) -> DerivedData/ipa/Documents.zip
  documents install [target]        copy the payload into the installed app's Documents, no reinstall
                                    (app not installed -> abort; overwrites, deletes nothing)
  clean                             remove app build output (DerivedData)
EOF
}

die() { echo "error: $*" >&2; exit 1; }

version() {
    local part v=()
    for part in MAJOR MINOR RELEASE; do
        v+=("$(sed -n "s/^set(OPENMW_VERSION_$part \([0-9]*\))$/\1/p" "$REPO/CMakeLists.txt")")
    done
    [ -n "${v[0]}" ] && [ -n "${v[1]}" ] && [ -n "${v[2]}" ] || die "cannot read OpenMW version from CMakeLists.txt"
    echo "${v[0]}.${v[1]}.${v[2]}"
}

# Once per invocation: increment ios/BUILD_NUMBER.
BUILD_NUMBER=
next_build_number() {
    [ -n "$BUILD_NUMBER" ] && return
    local file="$REPO/ios/BUILD_NUMBER"
    BUILD_NUMBER=$(( $(cat "$file" 2>/dev/null || echo 0) + 1 ))
    echo "$BUILD_NUMBER" > "$file"
}

# Builds the dependency xcframeworks if a slice for <target> is missing (incremental).
ensure_deps() {  # <simulator|device>
    local slice=ios-arm64 name
    [ "$1" = simulator ] && slice=ios-arm64-simulator
    # the xcframeworks the app links (ios/project.yml)
    for name in $(sed -n 's|.*ios-deps/artifacts/\(.*\)\.xcframework$|\1|p' "$REPO/ios/project.yml"); do
        if [ ! -d "$REPO/ios-deps/artifacts/$name.xcframework/$slice" ]; then
            "$REPO/ios-deps/build-deps.sh" build all "$1"
            return
        fi
    done
}

generate_project() {
    xcodegen generate --quiet --spec "$REPO/ios/project.yml" --project "$REPO/ios"
}

# Builds OpenMW's static libraries (DerivedData/openmw/<sdk>/lib) and stages its resources with OpenMW's own CMake;
# configures when the build dir is new or the arguments changed. The app links and bundles the result.
build_openmw() {  # <iphoneos|iphonesimulator>
    local sdk=$1 target=simulator dir="$DERIVED/openmw/$1" deps="$REPO/ios-deps/build" args stamp
    [ "$sdk" = iphoneos ] && target=device
    args=(-G Ninja --toolchain "$REPO/ios/openmw-toolchain.cmake" -DCMAKE_OSX_SYSROOT="$sdk"
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_ARCHIVE_OUTPUT_DIRECTORY="$dir/lib"
        # the game only: no launcher, editor, wizard, tools
        -DBUILD_LAUNCHER=OFF -DBUILD_WIZARD=OFF -DBUILD_MWINIIMPORTER=OFF -DBUILD_OPENCS=OFF -DBUILD_ESSIMPORTER=OFF
        -DBUILD_BSATOOL=OFF -DBUILD_ESMTOOL=OFF -DBUILD_NIFTEST=OFF -DBUILD_NAVMESHTOOL=OFF -DBUILD_BULLETOBJECTTOOL=OFF
        -DOSG_STATIC=ON -DMYGUI_STATIC=ON -DOPENMW_USE_SYSTEM_RECASTNAVIGATION=ON
        # iOS has no OpenGL.framework (Mesa instead); OpenAL Soft, not the SDK's OpenAL.framework
        -DOPENGL_INCLUDE_DIR="$deps/mesa/$target/install/include" -DOPENGL_gl_LIBRARY="$deps/mesa/$target/lib/libMesa.a"
        -DOPENAL_INCLUDE_DIR="$deps/openal-soft/$target/install/include/AL"
        -DOPENAL_LIBRARY="$deps/openal-soft/$target/install/lib/libopenal.a"
        # Lua custom allocator check: try_run cannot run when cross-compiling; LuaJIT with GC64 supports it
        -DRUN_RESULT_VAR=0)
    stamp=$(printf '%s\n' "${args[@]}")
    if [ ! -f "$dir/build.ninja" ] || [ "$(cat "$dir/.configured" 2>/dev/null)" != "$stamp" ]; then
        echo "==> configure OpenMW ($sdk)"
        cmake -S "$REPO" -B "$dir" "${args[@]}"
        echo "$stamp" > "$dir/.configured"
    fi
    echo "==> build OpenMW ($sdk)"
    cmake --build "$dir" --target openmw -- --quiet
}

# xcodebuild <sdk> [extra args]
xcbuild() {
    local sdk=$1; shift
    ensure_deps "$([ "$sdk" = iphoneos ] && echo device || echo simulator)"
    build_openmw "$sdk"
    next_build_number
    generate_project
    echo "==> build $sdk (version $(version), build $BUILD_NUMBER)"
    xcodebuild -project "$PROJECT" -scheme Morrowind -configuration Release -sdk "$sdk" \
        -derivedDataPath "$DERIVED" -allowProvisioningUpdates -quiet \
        MARKETING_VERSION="$(version)" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
        OPENMW_BUILD_DIR="$DERIVED/openmw/$sdk" "$@"
}

app_path() {  # <simulator|device>
    local sdk=iphonesimulator
    [ "$1" = device ] && sdk=iphoneos
    echo "$DERIVED/Build/Products/Release-$sdk/Morrowind.app"
}

# Current build = the slice's stamp (written by a successful 'build') exists and its app in DerivedData has that
# CFBundleVersion; sets BUILD_NUMBER.
require_build() {  # <simulator|device>
    local expected found
    expected=$(cat "$DERIVED/current-$1" 2>/dev/null || true)
    found=$(plutil -extract CFBundleVersion raw "$(app_path "$1")/Info.plist" 2>/dev/null || true)
    [ -n "$expected" ] && [ "$found" = "$expected" ] || die "no current $1 build: stamp ${expected:-none}" \
        "(DerivedData/current-$1), app ${found:-none}. run '$SCRIPT build $1'"
    BUILD_NUMBER=$expected
}

build() {  # <simulator|device|both>
    [ "$1" = both ] && { build simulator; build device; return; }
    rm -f "$DERIVED/current-$1"
    case "$1" in
        simulator) xcbuild iphonesimulator -destination "generic/platform=iOS Simulator" ;;
        device) xcbuild iphoneos -destination "generic/platform=iOS" ;;
    esac
    echo "$BUILD_NUMBER" > "$DERIVED/current-$1"
}

# Target selection (--simulator / --device) -> KIND + TARGET (simulator UDID or device name/UDID).
KIND=simulator
TARGET=$DEFAULT_SIMULATOR
resolve_target() {
    [ "$KIND" = device ] && return
    local udid
    udid=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
want = sys.argv[1]
for runtime, devices in json.load(sys.stdin)["devices"].items():
    if "iOS" not in runtime:
        continue
    for d in devices:
        if want in (d["name"], d["udid"]):
            print(d["udid"]); sys.exit(0)
sys.exit(1)
' "$TARGET") || die "simulator '$TARGET' not found"
    TARGET=$udid
    xcrun simctl bootstatus "$TARGET" -b > /dev/null
}

install_app() {
    local app
    app=$(app_path "$KIND")
    echo "==> install $KIND $TARGET (build $BUILD_NUMBER)"
    if [ "$KIND" = simulator ]; then
        xcrun simctl install "$TARGET" "$app"
    else
        xcrun devicectl device install app --quiet --device "$TARGET" "$app"
    fi
}

# Sets INSTALLED = CFBundleVersion of the app installed on the target.
require_installed() {
    if [ "$KIND" = simulator ]; then
        INSTALLED=$(plutil -extract CFBundleVersion raw \
            "$(xcrun simctl get_app_container "$TARGET" "$BUNDLE_ID" 2>/dev/null)/Info.plist" 2>/dev/null)
    else
        INSTALLED=$(xcrun devicectl device info apps --quiet --device "$TARGET" --bundle-id "$BUNDLE_ID" -j - 2>/dev/null \
            | python3 -c 'import json, sys; print(json.load(sys.stdin)["result"]["apps"][0]["bundleVersion"])' 2>/dev/null)
    fi || die "app not installed on $KIND $TARGET. run '$SCRIPT install'"
}

screenshot() {  # <file>
    if [ "$KIND" = simulator ]; then
        xcrun simctl io "$TARGET" screenshot "$1" > /dev/null 2>&1
    else
        xcrun devicectl device capture screenshot --quiet --device "$TARGET" --destination "$1"
    fi || { echo "warning: screenshot failed" >&2; return 0; }
    local w h
    w=$(sips -g pixelWidth "$1" | awk '/pixelWidth/ {print $2}')
    h=$(sips -g pixelHeight "$1" | awk '/pixelHeight/ {print $2}')
    # portrait framebuffer -> rotate 90 degrees left
    [ "$h" -gt "$w" ] && sips -r 270 "$1" > /dev/null
    return 0
}

run_app() {  # <seconds> <label> [app args]
    local seconds=$1 label=$2; shift 2
    mkdir -p "$LOG_DIR"
    local console="$LOG_DIR/debugger.log" shot="$LOG_DIR/$label.png" marker="$LOG_DIR/.run-start" pid start
    start=$(date +%s)
    touch "$marker"
    rm -f "$shot"
    echo "==> run $KIND $TARGET for ${seconds}s"
    if [ "$KIND" = simulator ]; then
        xcrun simctl launch --console --terminate-running-process "$TARGET" "$BUNDLE_ID" "$@" > "$console" 2>&1 &
    else
        xcrun devicectl device process launch --console --terminate-existing --device "$TARGET" "$BUNDLE_ID" "$@" > "$console" 2>&1 &
    fi
    pid=$!
    local waited=0
    while [ $waited -lt "$seconds" ] && kill -0 $pid 2>/dev/null; do sleep 1; waited=$((waited + 1)); done
    if kill -0 $pid 2>/dev/null; then
        screenshot "$shot"
        if [ "$KIND" = simulator ]; then
            xcrun simctl terminate "$TARGET" "$BUNDLE_ID" 2>/dev/null || true
        else
            kill -INT $pid 2>/dev/null || true  # devicectl forwards the signal to the app
        fi
    else
        echo "warning: app exited after ${waited}s" >&2
    fi
    # devicectl --console does not always exit after the app has terminated
    waited=0
    while kill -0 $pid 2>/dev/null && [ $waited -lt 10 ]; do sleep 1; waited=$((waited + 1)); done
    kill -KILL $pid 2>/dev/null || true
    wait $pid 2>/dev/null || true
    if [ "$KIND" = simulator ]; then
        xcrun simctl spawn "$TARGET" log show --style compact --start "$(date -r "$start" '+%Y-%m-%d %H:%M:%S')" \
            --predicate 'process == "Morrowind"' > "$LOG_DIR/system.log" 2>&1 || true
    fi
    local report
    for report in $(find "$HOME/Library/Logs/DiagnosticReports" -name 'Morrowind*.ips' -newer "$marker" 2>/dev/null); do
        cp "$report" "$LOG_DIR/"
        echo "warning: crash report $(basename "$report") -> log/" >&2
    done
    echo "==> logs in log/ (debugger.log$([ -f "$shot" ] && echo ", $label.png"))"
}

# Packages the current device build as is (signed by 'build': Apple Development, team profile).
make_ipa() {  # [--unsigned]
    require_build device
    local out="$DERIVED/ipa" name=Morrowind.ipa
    [ "${1:-}" = --unsigned ] && name=Morrowind-unsigned.ipa
    rm -rf "$out/Payload" && mkdir -p "$out/Payload"
    cp -R "$(app_path device)" "$out/Payload/"
    if [ "${1:-}" = --unsigned ]; then
        codesign --remove-signature "$out/Payload/Morrowind.app"
        rm -rf "$out/Payload/Morrowind.app/_CodeSignature" "$out/Payload/Morrowind.app/embedded.mobileprovision"
    fi
    (cd "$out" && rm -f "$name" && zip -qry "$name" Payload && rm -rf Payload)
    IPA="$out/$name"
    [ -f "$IPA" ] || die "IPA not created"
    echo "==> $IPA (build $BUILD_NUMBER)"
}

upload() {  # [curl args for the notes field]
    make_ipa
    mkdir -p "$REPO/archive"
    local name="Morrowind-$(version)-$BUILD_NUMBER.ipa" code
    cp "$IPA" "$REPO/archive/$name"
    echo "==> upload archive/$name"
    code=$(cd "$REPO" && curl -sS -o /dev/null -w '%{http_code}' -F "file=@archive/$name" "$@" "$REPO_SERVER") \
        || die "upload failed"
    [ "$code" -lt 400 ] || die "upload failed (HTTP $code)"
    echo "==> uploaded (HTTP $code)"
}

# Game data payload: ./Data -> Documents/Data (Morrowind.ini is not part of it: the user copies it to Config/).
documents() {  # <zip|install>
    [ -d "$REPO/Data" ] || die "no payload: $REPO/Data missing"
    if [ "$1" = zip ]; then
        mkdir -p "$DERIVED/ipa"
        echo "==> DerivedData/ipa/Documents.zip"
        # -FS: incremental, the zip mirrors Data/
        (cd "$REPO" && zip -qr -FS "$DERIVED/ipa/Documents.zip" Data -x '*.DS_Store')
        return
    fi
    require_installed
    echo "==> copy Data -> Documents/Data ($KIND $TARGET)"
    if [ "$KIND" = simulator ]; then
        local container
        container=$(xcrun simctl get_app_container "$TARGET" "$BUNDLE_ID" data)
        mkdir -p "$container/Documents/Data"
        rsync -a --exclude .DS_Store "$REPO/Data/" "$container/Documents/Data/"
    else
        # copies only modified files
        xcrun devicectl device copy to --quiet --device "$TARGET" --domain-type appDataContainer \
            --domain-identifier "$BUNDLE_ID" --source "$REPO/Data" --destination Documents/Data
    fi
}

[ $# -eq 0 ] && { usage; exit 0; }
command=$1; shift
case "$command" in
    -h|--help) usage; exit 0 ;;
    build|install|run|ipa|upload|documents|clean) ;;
    *) usage >&2; exit 1 ;;
esac

# Common option parsing.
POSITIONAL=() APP_ARGS=() UNSIGNED= SECONDS_ARG=45 LABEL=screenshot NOTES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --simulator) [ $# -ge 2 ] || die "--simulator needs <name|UDID>"; KIND=simulator; TARGET=$2; shift ;;
        --device) [ $# -ge 2 ] || die "--device needs <name|UDID>"; KIND=device; TARGET=$2; shift ;;
        --unsigned) UNSIGNED=--unsigned ;;
        --seconds) [ $# -ge 2 ] || die "--seconds needs a value"; SECONDS_ARG=$2; shift ;;
        --label) [ $# -ge 2 ] || die "--label needs a name"; LABEL=$2; shift ;;
        --notes|--notes-file)
            [ $# -ge 2 ] || die "$1 needs a value"
            [ ${#NOTES[@]} -eq 0 ] || die "--notes and --notes-file are mutually exclusive"
            if [ "$1" = --notes ]; then
                NOTES=(--form-string "notes=$2")  # literal, no @/< parsing
            else
                [ -f "$2" ] || die "notes file '$2' not found"
                NOTES=(-F "notes=<$(cd "$(dirname "$2")" && pwd)/$(basename "$2")")
            fi
            shift ;;
        --) shift; APP_ARGS=("$@"); break ;;
        -*) die "unknown option '$1'" ;;
        *) POSITIONAL+=("$1") ;;
    esac
    shift
done

allow() {  # <allowed options...>: reject options not valid for this command
    local given=() opt
    [ "$KIND$TARGET" != "simulator$DEFAULT_SIMULATOR" ] && given+=(target)
    [ -n "$UNSIGNED" ] && given+=(--unsigned)
    [ "$SECONDS_ARG" != 45 ] && given+=(--seconds)
    [ "$LABEL" != screenshot ] && given+=(--label)
    [ ${#APP_ARGS[@]} -gt 0 ] && given+=(--)
    [ ${#NOTES[@]} -gt 0 ] && given+=(--notes)
    for opt in "${given[@]+"${given[@]}"}"; do
        [[ " $* " == *" $opt "* ]] || die "'$opt' is not valid for '$command'"
    done
}

case "$command" in
    build)
        allow
        [ ${#POSITIONAL[@]} -le 1 ] || die "usage: $SCRIPT build [simulator|device|both]"
        target=${POSITIONAL[0]:-simulator}
        case "$target" in simulator|device|both) build "$target" ;; *) die "unknown target '$target'" ;; esac ;;
    install)
        allow target
        [ ${#POSITIONAL[@]} -eq 0 ] || die "unexpected argument '${POSITIONAL[0]}'"
        require_build "$KIND"
        resolve_target
        install_app ;;
    run)
        allow target --seconds --label --
        [ ${#POSITIONAL[@]} -eq 0 ] || die "unexpected argument '${POSITIONAL[0]}'"
        [[ "$SECONDS_ARG" =~ ^[0-9]+$ ]] && [ "$SECONDS_ARG" -ge 1 ] && [ "$SECONDS_ARG" -le 45 ] \
            || die "--seconds must be 1-45"
        [[ "$LABEL" =~ ^[A-Za-z0-9._-]+$ ]] || die "--label must match [A-Za-z0-9._-]+"
        require_build "$KIND"
        resolve_target
        require_installed
        [ "$INSTALLED" = "$BUILD_NUMBER" ] || die "installed build $INSTALLED on $KIND $TARGET is not the current" \
            "build $BUILD_NUMBER. run '$SCRIPT install'"
        run_app "$SECONDS_ARG" "$LABEL" "${APP_ARGS[@]+"${APP_ARGS[@]}"}" ;;
    ipa)
        allow --unsigned
        [ ${#POSITIONAL[@]} -eq 0 ] || die "unexpected argument '${POSITIONAL[0]}'"
        make_ipa $UNSIGNED ;;
    upload)
        allow --notes
        [ ${#POSITIONAL[@]} -eq 0 ] || die "unexpected argument '${POSITIONAL[0]}'"
        upload "${NOTES[@]+"${NOTES[@]}"}" ;;
    documents)
        [ ${#POSITIONAL[@]} -eq 1 ] || die "usage: $SCRIPT documents zip | documents install [target]"
        case "${POSITIONAL[0]}" in
            zip) allow; documents zip ;;
            install) allow target; resolve_target; documents install ;;
            *) die "usage: $SCRIPT documents zip | documents install [target]" ;;
        esac ;;
    clean)
        allow
        [ ${#POSITIONAL[@]} -eq 0 ] || die "unexpected argument '${POSITIONAL[0]}'"
        echo "==> clean"
        rm -rf "${DERIVED:?}" "$PROJECT" ;;
esac
