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
  install [target] [--no-build]     build + install app
  run     [target] [--seconds <1-45>] [--label <name>] [--no-build] [--no-install] [-- <app args>]
          build + install + run non-interactively (default: 45 s), logs + screenshot -> log/
          --no-build: use last build. --no-install: launch installed app (implies --no-build)
  ipa     [--unsigned]              device build -> IPA in DerivedData/ipa
  upload  [--notes <text>|--notes-file <path>]
          signed IPA of current tree + release notes ("What's New") -> archive/ -> repo server
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

build() {  # <simulator|device|both>
    case "$1" in
        simulator) xcbuild iphonesimulator -destination "generic/platform=iOS Simulator" ;;
        device) xcbuild iphoneos -destination "generic/platform=iOS" ;;
        both) build simulator; build device ;;
    esac
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
    [ -d "$app" ] || die "no $KIND build found, run '$SCRIPT build $KIND'"
    echo "==> install $KIND $TARGET"
    if [ "$KIND" = simulator ]; then
        xcrun simctl install "$TARGET" "$app"
    else
        xcrun devicectl device install app --quiet --device "$TARGET" "$app"
    fi
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

make_ipa() {  # [--unsigned]
    local out="$DERIVED/ipa"
    mkdir -p "$out"
    if [ "${1:-}" = --unsigned ]; then
        build_unsigned
        rm -rf "$out/Payload" && mkdir -p "$out/Payload"
        cp -R "$(app_path device)" "$out/Payload/"
        (cd "$out" && rm -f Morrowind-unsigned.ipa && zip -qry Morrowind-unsigned.ipa Payload && rm -rf Payload)
        IPA="$out/Morrowind-unsigned.ipa"
    else
        xcbuild iphoneos -destination "generic/platform=iOS" -archivePath "$out/Morrowind.xcarchive" archive
        cat > "$out/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>debugging</string>
<key>teamID</key><string></string>
<key>signingStyle</key><string>automatic</string>
</dict></plist>
EOF
        rm -f "$out/Morrowind.ipa"
        xcodebuild -exportArchive -archivePath "$out/Morrowind.xcarchive" -exportPath "$out" \
            -exportOptionsPlist "$out/ExportOptions.plist" -allowProvisioningUpdates -quiet
        IPA="$out/Morrowind.ipa"
    fi
    [ -f "$IPA" ] || die "IPA not created"
    echo "==> $IPA"
}

build_unsigned() {
    xcbuild iphoneos -destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO
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

[ $# -eq 0 ] && { usage; exit 0; }
command=$1; shift
case "$command" in
    -h|--help) usage; exit 0 ;;
    build|install|run|ipa|upload|clean) ;;
    *) usage >&2; exit 1 ;;
esac

# Common option parsing.
POSITIONAL=() APP_ARGS=() NO_BUILD= NO_INSTALL= UNSIGNED= SECONDS_ARG=45 LABEL=screenshot NOTES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --simulator) [ $# -ge 2 ] || die "--simulator needs <name|UDID>"; KIND=simulator; TARGET=$2; shift ;;
        --device) [ $# -ge 2 ] || die "--device needs <name|UDID>"; KIND=device; TARGET=$2; shift ;;
        --no-build) NO_BUILD=1 ;;
        --no-install) NO_INSTALL=1; NO_BUILD=1 ;;
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
    [ -n "$NO_BUILD" ] && [ -z "$NO_INSTALL" ] && given+=(--no-build)
    [ -n "$NO_INSTALL" ] && given+=(--no-install)
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
        allow target --no-build
        [ ${#POSITIONAL[@]} -eq 0 ] || die "unexpected argument '${POSITIONAL[0]}'"
        resolve_target
        [ -n "$NO_BUILD" ] || build "$KIND"
        install_app ;;
    run)
        allow target --no-build --no-install --seconds --label --
        [ ${#POSITIONAL[@]} -eq 0 ] || die "unexpected argument '${POSITIONAL[0]}'"
        [[ "$SECONDS_ARG" =~ ^[0-9]+$ ]] && [ "$SECONDS_ARG" -ge 1 ] && [ "$SECONDS_ARG" -le 45 ] \
            || die "--seconds must be 1-45"
        [[ "$LABEL" =~ ^[A-Za-z0-9._-]+$ ]] || die "--label must match [A-Za-z0-9._-]+"
        resolve_target
        [ -n "$NO_BUILD" ] || build "$KIND"
        [ -n "$NO_INSTALL" ] || install_app
        run_app "$SECONDS_ARG" "$LABEL" "${APP_ARGS[@]+"${APP_ARGS[@]}"}" ;;
    ipa)
        allow --unsigned
        [ ${#POSITIONAL[@]} -eq 0 ] || die "unexpected argument '${POSITIONAL[0]}'"
        make_ipa $UNSIGNED ;;
    upload)
        allow --notes
        [ ${#POSITIONAL[@]} -eq 0 ] || die "unexpected argument '${POSITIONAL[0]}'"
        upload "${NOTES[@]+"${NOTES[@]}"}" ;;
    clean)
        allow
        [ ${#POSITIONAL[@]} -eq 0 ] || die "unexpected argument '${POSITIONAL[0]}'"
        echo "==> clean"
        rm -rf "${DERIVED:?}" "$PROJECT" ;;
esac
