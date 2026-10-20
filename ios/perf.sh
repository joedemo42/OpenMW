#!/bin/bash
# Profiles the current release device build of the OpenMW iOS app: OpenMW's frame stats, optional Instruments trace
# and screenshots for a measured window -> log/perf-<label>/ + summary.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${0#"$PWD/"}"
DERIVED="$REPO/DerivedData"
LOG_DIR="$REPO/log"
BUNDLE_ID=org.openmw.openmw
APP="$DERIVED/Build/Products/Release-iphoneos/OpenMW.app"
STATS_FILE=Library/Caches/openmw-stats.txt  # in the app's data container, not visible in the Files app

usage() {
    cat <<EOF
Usage: $SCRIPT <command> [args] [options]
Profiles the current release device build ('ios/build.sh build device --release', then 'install --release').

  run --device <name|UDID> [--seconds <1-3600>] [--warmup <0-600>] [--label <name>] [--stats <list>]
      [--trace <template>] [--shots <interval>] [--env <NAME=value>]... [-- <app args>]
          measure the installed build after the warmup -> log/perf-<label>/ + summary. --stats: OPENMW_OSG_STATS_LIST,
          --trace: Instruments template, --shots: screenshot every <interval> s, --env: app environment variable
          {container} in app args/--env = the data container path. default: --seconds 60 --warmup 20 --stats frame_rate
  summary <dir>   frame times of the measured window, phases, memory + thermal log lines of a run dir
EOF
}

die() { echo "error: $*" >&2; exit 1; }

# waits up to <seconds> while the process <pid> runs; returns 1 if it ended
wait_alive() {  # <pid> <seconds>
    local waited=0
    while [ $waited -lt "$2" ]; do
        kill -0 "$1" 2>/dev/null || return 1
        sleep 1
        waited=$((waited + 1))
    done
}

# stops the app launched by 'devicectl device process launch --console' (process <pid>)
stop_app() {  # <pid>
    kill -INT "$1" 2>/dev/null || true  # devicectl forwards the signal to the app
    # devicectl --console does not always exit after the app has terminated
    local waited=0
    while kill -0 "$1" 2>/dev/null && [ $waited -lt 10 ]; do sleep 1; waited=$((waited + 1)); done
    kill -KILL "$1" 2>/dev/null || true
    wait "$1" 2>/dev/null || true
}

summary() {  # <dir>
    [ -f "$1/run.txt" ] || die "not a perf run dir: $1"
    python3 - "$1" <<'EOF'
import pathlib, re, statistics, sys

d = pathlib.Path(sys.argv[1])
run = dict(line.split("=", 1) for line in (d / "run.txt").read_text().splitlines() if "=" in line)
print("".join(f"{k}: {v}\n" for k, v in run.items()), end="")
window = float(run["seconds"])

def pct(values, p):
    s = sorted(values)
    return s[min(len(s) - 1, int(p / 100 * len(s)))]

frames = {}
frame = None
stats = d / "stats.txt"
for line in (stats.open(errors="replace") if stats.exists() else []):
    m = re.match(r"\s*Stats .* FrameNumber (\d+)", line)
    if m:
        frame = frames.setdefault(int(m[1]), {})
        continue
    m = re.match(r"\s*(.*?)\s+(\S+)$", line)
    try:
        key, value = m[1], float(m[2])
    except (TypeError, ValueError):
        continue
    if frame is not None:
        # several cameras: their times add up
        frame[key] = frame.get(key, 0) + value if "taken" in key else value

# measured window = the last <seconds> of frames
window_frames, total = [], 0.0
for number in sorted(frames, reverse=True):
    duration = frames[number].get("Frame duration")
    if duration is None:
        continue
    if total >= window:
        break
    window_frames.append(frames[number])
    total += duration
if window_frames:
    durations = [f["Frame duration"] * 1000 for f in window_frames]
    median = pct(durations, 50)
    print(f"frames: {len(window_frames)} in {total:.1f} s (of {len(frames)} reported), {len(window_frames) / total:.1f} fps")
    print("frame ms: mean %.2f  p50 %.2f  p90 %.2f  p99 %.2f  max %.2f" % (statistics.mean(durations), median,
          pct(durations, 90), pct(durations, 99), max(durations)))
    print(f"hitches: {sum(x > 2 * median for x in durations)} frames > 2x p50, {sum(x > 50 for x in durations)} > 50 ms")
    keys = sorted({k for f in window_frames for k in f if k.endswith("time taken") or k.endswith("_time_taken")})
    if keys:
        print("phase ms (frames that report it): mean / p50 / p95 / max")
    for key in keys:
        values = [f[key] * 1000 for f in window_frames if key in f]
        print("  %-36s %7.2f %7.2f %7.2f %7.2f" % (key, statistics.mean(values), pct(values, 50), pct(values, 95),
              max(values)))
else:
    print("frames: no frame durations in stats.txt" + ("" if stats.exists() else " (missing)"))

console = d / "console.log"
for line in (console.open(errors="replace") if console.exists() else []):
    if re.search(r"Memory \(|Terminating app|uncaught exception", line):
        print(line.rstrip())
EOF
    [ -d "$1/trace.trace" ] || return 0
    python3 - "$1" "$APP.dSYM" <<'EOF'
import collections, pathlib, re, subprocess, sys, xml.etree.ElementTree as ET

d, dsym = pathlib.Path(sys.argv[1]), sys.argv[2]
xml = d / "trace-profile.xml"
if not xml.exists():
    with xml.open("w") as f:
        subprocess.run(["xcrun", "xctrace", "export", "--input", str(d / "trace.trace"), "--xpath",
                        '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'], stdout=f, check=True)

ids, samples = {}, []
def resolve(e):
    return ids[e.get("ref")] if e.get("ref") else e
for _, row in ET.iterparse(xml):
    if row.get("id"):
        ids[row.get("id")] = row
    if row.tag != "row":
        continue
    thread = resolve(row.find("thread")).get("fmt", "?")
    weight = int(resolve(row.find("weight")).text) / 1e6
    bt = row.find("tagged-backtrace")
    frames = []
    if bt is not None:
        for fr in resolve(bt).findall("frame"):
            fr = resolve(fr)
            binary = fr.find("binary")
            binary = resolve(binary) if binary is not None else None
            frames.append((fr.get("name"), int(fr.get("addr"), 16), binary.get("name") if binary is not None else "?",
                           binary.get("UUID") if binary is not None else None,
                           int(binary.get("load-addr"), 16) if binary is not None else 0))
    samples.append((re.sub(r" \(0x[0-9a-f]+\).*", "", thread), weight, frames))

# the app's frames: symbolicate with the dSYM (same UUID only)
uuid = subprocess.run(["dwarfdump", "--uuid", dsym], capture_output=True, text=True).stdout.split()
app = {(a, load) for _, _, fs in samples for n, a, b, u, load in fs if b == "OpenMW" and n.startswith("0x")}
names = {}
if app:
    trace_uuid = next(u for _, _, fs in samples for n, a, b, u, l in fs if b == "OpenMW")
    if len(uuid) > 1 and uuid[1] == trace_uuid:
        load = next(iter(app))[1]
        addrs = sorted(a for a, _ in app)
        out = subprocess.run(["xcrun", "atos", "-o", dsym, "-arch", "arm64", "-l", hex(load)] + [hex(a) for a in addrs],
                             capture_output=True, text=True).stdout.splitlines()
        names = {a: re.sub(r" \(in OpenMW\)| \(.*\.\w+:\d+\)$|\(.*", "", n).strip() for a, n in zip(addrs, out)}
    else:
        print("trace: dSYM UUID differs from the traced binary, app frames unsymbolicated")
def name(frame):
    n, a, b, _, _ = frame
    return names.get(a, n) if b == "OpenMW" else n

def component(frame):
    n, b = name(frame), frame[2]
    if b != "OpenMW":
        return "Metal driver" if re.match(r"AGX|IOGPU|Metal|IOKit", b) else "system (" + b + ")"
    for pattern, comp in ((r"^(zink|nir|spirv|vk_|tc_|_tc|st_|_mesa|util_|u_|glsl|blitter|pipe|ralloc)", "Mesa/zink"),
                          (r"MVK|mvk|SPIRV|spirv_cross|MoltenVK", "MoltenVK"),
                          (r"^(osg|OpenThreads)", "OSG"), (r"^(lua|lj_|LuaUtil)", "Lua"),
                          (r"^(bt|btDbvt)", "Bullet"), (r"^(MyGUI)", "MyGUI"), (r"^(SDL|UIKit_)", "SDL"),
                          (r"^(MW|OMW|Resource::|SceneUtil|NifOsg|Shader::|Terrain|ESM|Misc::|DetourNavigator|Debug)", "OpenMW")):
        if re.search(pattern, n):
            return comp
    return "other app code"

total = sum(w for _, w, _ in samples)
print(f"trace: {len(samples)} samples, {total / 1000:.1f} s CPU (Time Profiler, running threads)")
by_thread = collections.Counter()
for t, w, _ in samples:
    by_thread[t] += w
for t, w in by_thread.most_common(8):
    leaf = collections.Counter()
    comps = collections.Counter()
    incl = collections.Counter()
    for t2, w2, fs in samples:
        if t2 != t or not fs:
            continue
        leaf[name(fs[0])] += w2
        comps[component(fs[0])] += w2
        for n in {name(f) for f in fs}:
            incl[n] += w2
    print(f"  thread {t}: {w / 1000:.1f} s ({100 * w / total:.0f}%)")
    print("    components: " + ", ".join(f"{c} {100 * x / w:.0f}%" for c, x in comps.most_common(6)))
    print("    self: " + "; ".join(f"{n[:60]} {100 * x / w:.1f}%" for n, x in leaf.most_common(8)))
    print("    inclusive: " + "; ".join(f"{n[:50]} {100 * x / w:.0f}%" for n, x in incl.most_common(16)
                                     if not re.match(r"^(start|_pthread|thread_start|0x)", n))[:900])
EOF
}

run_perf() {
    local expected found installed out env pid trace_pid= shots_pid= start i
    # same rules as 'ios/build.sh run --release': current release device build, installed on the target
    expected=$(cat "$DERIVED/current-device-Release" 2>/dev/null || true)
    found=$(plutil -extract CFBundleVersion raw "$APP/Info.plist" 2>/dev/null || true)
    [ -n "$expected" ] && [ "$found" = "$expected" ] \
        || die "no current release device build. run 'ios/build.sh build device --release'"
    installed=$(xcrun devicectl device info apps --quiet --device "$TARGET" --bundle-id "$BUNDLE_ID" -j - 2>/dev/null \
        | python3 -c 'import json, sys; print(json.load(sys.stdin)["result"]["apps"][0]["bundleVersion"])' 2>/dev/null) \
        || die "app not installed on device $TARGET. run 'ios/build.sh install --release --device \"$TARGET\"'"
    [ "$installed" = "$expected" ] || die "installed build $installed on $TARGET is not the current release build" \
        "$expected. run 'ios/build.sh install --release --device \"$TARGET\"'"

    out="$LOG_DIR/perf-$LABEL"
    rm -rf "$out"
    mkdir -p "$out"
    # OpenMW needs absolute paths, and every install moves the data container: a short launch logs its path
    local container= waited=0
    xcrun devicectl device process launch --console --terminate-existing --device "$TARGET" "$BUNDLE_ID" --no-sound \
        > "$out/probe.log" 2>&1 &
    pid=$!
    until container=$(grep -o -m1 '/private/var/mobile/Containers/Data/Application/[0-9A-F-]*' "$out/probe.log"); do
        kill -0 $pid 2>/dev/null && [ $waited -lt 30 ] || break
        sleep 1
        waited=$((waited + 1))
    done
    stop_app $pid
    [ -n "$container" ] || die "no data container path in the app's log (log/perf-$LABEL/probe.log)"
    # {container} in app args (e.g. --load-savegame {container}/Documents/Saves/...) and env values = that path
    for i in "${!APP_ARGS[@]}"; do APP_ARGS[i]=${APP_ARGS[i]//\{container\}/$container}; done
    for i in "${!ENVS[@]}"; do ENVS[i]=${ENVS[i]//\{container\}/$container}; done
    env=$(python3 -c 'import json, sys
env = dict(e.split("=", 1) for e in sys.argv[3:])
env.update(OPENMW_OSG_STATS_FILE=sys.argv[1], OPENMW_OSG_STATS_LIST=sys.argv[2])
print(json.dumps(env))' "$container/$STATS_FILE" "$STATS" "${ENVS[@]+"${ENVS[@]}"}")
    {
        echo "build=$expected"
        echo "device=$TARGET"
        echo "date=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "warmup=$WARMUP"
        echo "seconds=$SECONDS_ARG"
        echo "stats=$STATS"
        echo "trace=${TRACE:-none}"
        echo "shots=${SHOTS:-none}"
        echo "env=${ENVS[*]+"${ENVS[*]}"}"
        echo "args=${APP_ARGS[*]+"${APP_ARGS[*]}"}"
    } > "$out/run.txt"

    echo "==> perf run on $TARGET (release build $expected): warmup ${WARMUP}s + ${SECONDS_ARG}s -> log/perf-$LABEL/"
    start=$(date +%s)
    xcrun devicectl device process launch --console --terminate-existing --device "$TARGET" \
        --environment-variables "$env" "$BUNDLE_ID" "${APP_ARGS[@]+"${APP_ARGS[@]}"}" > "$out/console.log" 2>&1 &
    pid=$!
    if wait_alive $pid "$WARMUP"; then
        if [ -n "$TRACE" ]; then
            xcrun xctrace record --quiet --device "$TARGET" --template "$TRACE" --attach OpenMW \
                --time-limit "${SECONDS_ARG}s" --output "$out/trace.trace" > "$out/xctrace.log" 2>&1 &
            trace_pid=$!
        fi
        if [ -n "$SHOTS" ]; then
            mkdir -p "$out/shots"
            (
                n=0
                end=$(( $(date +%s) + SECONDS_ARG ))
                while [ "$(date +%s)" -lt $end ]; do
                    n=$((n + 1))
                    xcrun devicectl device capture screenshot --quiet --device "$TARGET" \
                        --destination "$out/shots/$(printf %04d $n).png" > /dev/null 2>&1 || true
                    echo "$(printf %04d $n) $(( $(date +%s) - start ))" >> "$out/shots/times.txt"
                    sleep "$SHOTS"
                done
            ) &
            shots_pid=$!
        fi
        wait_alive $pid "$SECONDS_ARG" || echo "warning: app exited during the measured window" >&2
    else
        echo "warning: app exited during the warmup" >&2
    fi
    [ -n "$shots_pid" ] && wait $shots_pid 2>/dev/null || true
    [ -n "$trace_pid" ] && wait $trace_pid 2>/dev/null || true
    if kill -0 $pid 2>/dev/null; then
        xcrun devicectl device capture screenshot --quiet --device "$TARGET" --destination "$out/final.png" \
            > /dev/null 2>&1 || echo "warning: screenshot failed" >&2
    fi
    stop_app $pid

    # a stats file OpenMW could not open would be the previous run's
    if grep -q "Failed to open file to write OSG stats" "$out/console.log"; then
        echo "warning: OpenMW could not write the stats file (log/perf-$LABEL/console.log)" >&2
    else
        # the copy right after the app has ended fails now and then
        local tries=0
        until xcrun devicectl device copy from --quiet --device "$TARGET" --domain-type appDataContainer \
            --domain-identifier "$BUNDLE_ID" --source "$STATS_FILE" --destination "$out/stats.txt" > /dev/null 2>&1; do
            tries=$((tries + 1))
            [ $tries -lt 3 ] || { rm -f "$out/stats.txt"; echo "warning: no stats file ($STATS_FILE) on the device" >&2; break; }
            sleep 2
        done
    fi
    if [ -d "$out/trace.trace" ]; then
        xcrun xctrace symbolicate --input "$out/trace.trace" --dsym "$APP.dSYM" >> "$out/xctrace.log" 2>&1 \
            || echo "warning: trace symbolication failed (log/perf-$LABEL/xctrace.log)" >&2
    elif [ -n "$TRACE" ]; then
        echo "warning: no trace recorded (log/perf-$LABEL/xctrace.log)" >&2
    fi
    echo "==> log/perf-$LABEL/"
    summary "$out" | tee "$out/summary.txt"
}

[ $# -eq 0 ] && { usage; exit 0; }
command=$1; shift
case "$command" in
    -h|--help) usage; exit 0 ;;
    run|summary) ;;
    *) usage >&2; exit 1 ;;
esac

POSITIONAL=() APP_ARGS=() ENVS=() TARGET= SECONDS_ARG=60 WARMUP=20 LABEL=perf STATS=frame_rate TRACE= SHOTS= OPTIONS=0
while [ $# -gt 0 ]; do
    case "$1" in
        --device|--seconds|--warmup|--label|--stats|--trace|--shots|--env)
            [ $# -ge 2 ] || die "$1 needs a value"
            case "$1" in
                --device) TARGET=$2 ;;
                --seconds) SECONDS_ARG=$2 ;;
                --warmup) WARMUP=$2 ;;
                --label) LABEL=$2 ;;
                --stats) STATS=$2 ;;
                --trace) TRACE=$2 ;;
                --shots) SHOTS=$2 ;;
                --env) [[ "$2" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || die "--env needs <NAME=value>"; ENVS+=("$2") ;;
            esac
            OPTIONS=1
            shift ;;
        --) shift; APP_ARGS=("$@"); OPTIONS=1; break ;;
        -*) die "unknown option '$1'" ;;
        *) POSITIONAL+=("$1") ;;
    esac
    shift
done

case "$command" in
    run)
        [ ${#POSITIONAL[@]} -eq 0 ] || die "unexpected argument '${POSITIONAL[0]}'"
        [ -n "$TARGET" ] || die "run needs --device <name|UDID>"
        [[ "$SECONDS_ARG" =~ ^[0-9]+$ ]] && [ "$SECONDS_ARG" -ge 1 ] && [ "$SECONDS_ARG" -le 3600 ] \
            || die "--seconds must be 1-3600"
        [[ "$WARMUP" =~ ^[0-9]+$ ]] && [ "$WARMUP" -le 600 ] || die "--warmup must be 0-600"
        [[ "$LABEL" =~ ^[A-Za-z0-9._-]+$ ]] || die "--label must match [A-Za-z0-9._-]+"
        [ -z "$SHOTS" ] || [[ "$SHOTS" =~ ^[0-9]+$ ]] || die "--shots must be whole seconds (0: back to back)"
        run_perf ;;
    summary)
        [ ${#POSITIONAL[@]} -eq 1 ] || die "usage: $SCRIPT summary <dir>"
        [ $OPTIONS -eq 0 ] || die "summary takes no options"
        summary "${POSITIONAL[0]}" ;;
esac
