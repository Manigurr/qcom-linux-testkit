#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
# IRIS Video V4L2 runner with stack selection via utils/lib_video.sh

# ---------- Repo env + helpers ----------
SCRIPT_DIR="$(
  cd "$(dirname "$0")" || exit 1
  pwd
)"
INIT_ENV=""
SEARCH="$SCRIPT_DIR"

while [ "$SEARCH" != "/" ]; do
    if [ -f "$SEARCH/init_env" ]; then
        INIT_ENV="$SEARCH/init_env"
        break
    fi
    SEARCH=$(dirname "$SEARCH")
done

if [ -z "$INIT_ENV" ]; then
    echo "[ERROR] Could not find init_env (starting at $SCRIPT_DIR)" >&2
    exit 1
fi

# Only source once (idempotent)
if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1090
. "$INIT_ENV"
# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"
# shellcheck disable=SC1091
. "$TOOLS/lib_video.sh"

TESTNAME="Video_V4L2_Runner"
RES_FILE="./${TESTNAME}.res"

if [ -z "${TAR_URL:-}" ]; then
    TAR_URL="https://github.com/qualcomm-linux/qcom-linux-testkit/releases/download/IRIS-Video-Files-v1.0/video_clips_iris.tar.gz"
fi

# --- Defaults / knobs ---
if [ -z "${TIMEOUT:-}" ]; then TIMEOUT="60"; fi
if [ -z "${STRICT:-}" ]; then STRICT="0"; fi
if [ -z "${DMESG_SCAN:-}" ]; then DMESG_SCAN="1"; fi
PATTERN=""
if [ -z "${MAX:-}" ]; then MAX="0"; fi
if [ -z "${STOP_ON_FAIL:-}" ]; then STOP_ON_FAIL="0"; fi
DRY="0"
if [ -z "${EXTRACT_INPUT_CLIPS:-}" ]; then EXTRACT_INPUT_CLIPS="true"; fi
if [ -z "${SUCCESS_RE:-}" ]; then SUCCESS_RE="SUCCESS"; fi
if [ -z "${LOGLEVEL:-}" ]; then LOGLEVEL="15"; fi
if [ -z "${REPEAT:-}" ]; then REPEAT="1"; fi
if [ -z "${REPEAT_DELAY:-}" ]; then REPEAT_DELAY="0"; fi
if [ -z "${REPEAT_POLICY:-}" ]; then REPEAT_POLICY="all"; fi
JUNIT_OUT=""
VERBOSE="0"
COMPLIANCE_H264="0"
RUN_V4L2_COMPLIANCE="0"
V4L2_COMPLIANCE_BIN_PATH=""

# --- Stabilizers (opt-in) ---
RETRY_ON_FAIL="0" # extra attempts after a FAIL
POST_TEST_SLEEP="0" # settle time after each case

# --- Custom module source (opt-in; default is untouched) ---
KO_DIRS="" # colon-separated list of dirs that contain .ko files
KO_TREE="" # alt root that has lib/modules/$KVER
KO_TARBALL="" # optional tarball that we unpack once
KO_PREFER_CUSTOM="0" # 1 = try custom first; default 0 = system first

# --- Opt-in: custom media bundle tar (always honored even with --dir/--config) ---
CLIPS_TAR="" # /path/to/clips.tar[.gz|.xz|.zst|.bz2|.tgz|.tbz2|.zip]
CLIPS_DEST="" # optional extraction destination; defaults to cfg/dir root or testcase dir

if [ -z "${VIDEO_STACK:-}" ]; then VIDEO_STACK="auto"; fi
if [ -z "${VIDEO_PLATFORM:-}" ]; then VIDEO_PLATFORM=""; fi
if [ -z "${VIDEO_FW_DS:-}" ]; then VIDEO_FW_DS=""; fi
if [ -z "${VIDEO_FW_BACKUP_DIR:-}" ]; then VIDEO_FW_BACKUP_DIR=""; fi
if [ -z "${VIDEO_NO_REBOOT:-}" ]; then VIDEO_NO_REBOOT="0"; fi
if [ -z "${VIDEO_FORCE:-}" ]; then VIDEO_FORCE="0"; fi
if [ -z "${VIDEO_APP:-}" ]; then VIDEO_APP="/usr/bin/iris_v4l2_test"; fi

# --- Net/DL tunables (no-op if helpers ignore them) ---
if [ -z "${NET_STABILIZE_SLEEP:-}" ]; then NET_STABILIZE_SLEEP="5"; fi
if [ -z "${WGET_TIMEOUT_SECS:-}" ]; then WGET_TIMEOUT_SECS="120"; fi
if [ -z "${WGET_TRIES:-}" ]; then WGET_TRIES="2"; fi

# --- Stability sleeps ---
if [ -z "${APP_LAUNCH_SLEEP:-}" ]; then APP_LAUNCH_SLEEP="1"; fi
if [ -z "${INTER_TEST_SLEEP:-}" ]; then INTER_TEST_SLEEP="2"; fi

# --- New: log flavor for --stack both sub-runs ---
LOG_FLAVOR=""

usage() {
    cat <<EOF
Usage: $0 [--config path.json|/path/dir] [--dir DIR] [--pattern GLOB]
          [--timeout S] [--strict] [--no-dmesg] [--max N] [--stop-on-fail]
          [--loglevel N] [--extract-input-clips true|false]
          [--repeat N] [--repeat-delay S] [--repeat-policy all|any]
          [--junit FILE] [--dry-run] [--verbose]
          [--stack auto|upstream|downstream|base|overlay|up|down|both]
          [--platform lemans|monaco|kodiak]
          [--downstream-fw PATH] [--force]
          [--app /path/to/iris_v4l2_test]
          [--ssid SSID] [--password PASS]
          [--ko-dir DIR[:DIR2:...]] # opt-in: search these dirs for .ko on failure
          [--ko-tree ROOT] # opt-in: modprobe -d ROOT (expects lib/modules/\$(uname -r))
          [--ko-tar FILE.tar[.gz|.xz]] # opt-in: unpack once under /run/iris_mods/\$KVER, set --ko-tree/--ko-dir accordingly
          [--ko-prefer-custom] # opt-in: try custom sources before system
          [--app-launch-sleep S] [--inter-test-sleep S]
          [--log-flavor NAME] # internal: e.g. upstream or downstream (used by --stack both)
          [--compliance-h264] # run only 1 H264 Decode + 1 H264 Encode (standard app)
          [--v4l2-compliance] # Run v4l2-compliance tool on /dev/video0 (dec) and /dev/video1 (enc) H264 ONLY
          [--v4l2-compliance-bin PATH] # Explicit path to v4l2-compliance binary
          # --- Stabilizers ---
          [--retry-on-fail N] # retry up to N times if a case ends FAIL
          [--post-test-sleep S] # sleep S seconds after each case
          # --- Media bundle (opt-in, local tar) ---
          [--clips-tar /path/to/clips.tar.gz] # extract locally even if --dir/--config is used
          [--clips-dest DIR] # extraction destination (defaults to cfg/dir root or testcase dir)
EOF
}

CFG=""
DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --config)
            shift
            CFG="$1"
            ;;
        --dir)
            shift
            DIR="$1"
            ;;
        --pattern)
            shift
            PATTERN="$1"
            ;;
        --timeout)
            shift
            TIMEOUT="$1"
            ;;
        --strict)
            STRICT=1
            ;;
        --no-dmesg)
            DMESG_SCAN=0
            ;;
        --max)
            shift
            MAX="$1"
            ;;
        --stop-on-fail)
            STOP_ON_FAIL=1
            ;;
        --loglevel)
            shift
            LOGLEVEL="$1"
            ;;
        --repeat)
            shift
            REPEAT="$1"
            ;;
        --repeat-delay)
            shift
            REPEAT_DELAY="$1"
            ;;
        --repeat-policy)
            shift
            REPEAT_POLICY="$1"
            ;;
        --junit)
            shift
            JUNIT_OUT="$1"
            ;;
        --dry-run)
            DRY=1
            ;;
        --extract-input-clips)
            shift
            EXTRACT_INPUT_CLIPS="$1"
            ;;
        --verbose)
            VERBOSE=1
            ;;
        --stack)
            shift
            VIDEO_STACK="$1"
            ;;
        --platform)
            shift
            VIDEO_PLATFORM="$1"
            ;;
        --downstream-fw)
            shift
            VIDEO_FW_DS="$1"
            ;;
        --force)
            VIDEO_FORCE=1
            ;;
        --app)
            shift
            VIDEO_APP="$1"
            ;;
        --ssid)
            shift
            SSID="$1"
            ;;
        --password)
            shift
            PASSWORD="$1"
            ;;
        --ko-dir)
            shift
            KO_DIRS="$1"
            ;;
        --ko-tree)
            shift
            KO_TREE="$1"
            ;;
        --ko-tar)
            shift
            KO_TARBALL="$1"
            ;;
        --ko-prefer-custom)
            KO_PREFER_CUSTOM="1"
            ;;
        --app-launch-sleep)
            shift
            APP_LAUNCH_SLEEP="$1"
            ;;
        --inter-test-sleep)
            shift
            INTER_TEST_SLEEP="$1"
            ;;
        --log-flavor)
            shift
            LOG_FLAVOR="$1"
            ;;
        --compliance-h264)
            COMPLIANCE_H264="1"
            ;;
        --v4l2-compliance)
            RUN_V4L2_COMPLIANCE="1"
            ;;
        --v4l2-compliance-bin)
            shift
            V4L2_COMPLIANCE_BIN_PATH="$1"
            ;;
        --retry-on-fail)
            shift
            RETRY_ON_FAIL="$1"
            ;;
        --post-test-sleep)
            shift
            POST_TEST_SLEEP="$1"
            ;;
        --clips-tar)
            shift
            CLIPS_TAR="$1"
            ;;
        --clips-dest)
            shift
            CLIPS_DEST="$1"
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            log_warn "Unknown arg: $1"
            ;;
    esac
    shift
done

# Export envs used by lib
export VIDEO_APP
export VIDEO_FW_DS
export VIDEO_FW_BACKUP_DIR
export VIDEO_NO_REBOOT
export VIDEO_FORCE
export LOG_DIR
export TAR_URL
export SSID
export PASSWORD

export NET_STABILIZE_SLEEP
export WGET_TIMEOUT_SECS
export WGET_TRIES

export APP_LAUNCH_SLEEP
export INTER_TEST_SLEEP

# --- EARLY dependency check (bail out fast) ---

# Ensure the app is executable if a path was provided but lacks +x
if [ -n "$VIDEO_APP" ] && [ -f "$VIDEO_APP" ] && [ ! -x "$VIDEO_APP" ]; then
    chmod +x "$VIDEO_APP" 2>/dev/null || true
    if [ ! -x "$VIDEO_APP" ]; then
        log_warn "App $VIDEO_APP is not executable and chmod failed; attempting to run anyway."
    fi
fi

# --- Optional: unpack a custom module tarball **once** (no env exports) ---
KVER="$(uname -r 2>/dev/null || printf '%s' unknown)"
if [ -n "$KO_TARBALL" ] && [ -f "$KO_TARBALL" ]; then
    DEST="/run/iris_mods/$KVER"
    if [ ! -d "$DEST" ]; then
        mkdir -p "$DEST" 2>/dev/null || true
        case "$KO_TARBALL" in
            *.tar|*.tar.gz|*.tgz|*.tar.xz|*.txz|*.tar.zst)
                if command -v tar >/dev/null 2>&1; then
                    tar -xf "$KO_TARBALL" -C "$DEST" 2>/dev/null || true
                fi
                ;;
            *)
                :
                ;;
        esac
    fi
    if [ -d "$DEST/lib/modules/$KVER" ]; then
        KO_TREE="$DEST"
    else
        first_ko_dir="$(find "$DEST" -type f -name '*.ko*' -maxdepth 3 2>/dev/null | head -n1 | xargs -r dirname)"
        if [ -n "$first_ko_dir" ]; then
            if [ -n "$KO_DIRS" ]; then
                KO_DIRS="$first_ko_dir:$KO_DIRS"
            else
                KO_DIRS="$first_ko_dir"
            fi
        fi
    fi
    log_info "Custom module source prepared (tree='${KO_TREE:-none}', dirs='${KO_DIRS:-none}', prefer_custom=$KO_PREFER_CUSTOM)"
fi

# ---- Default firmware path for Kodiak downstream if CLI not given ----
if [ -z "${VIDEO_FW_DS:-}" ]; then
    default_fw="/data/vendor/iris_test_app/firmware/vpu20_1v.mbn"
    if [ -f "$default_fw" ]; then
        VIDEO_FW_DS="$default_fw"
        export VIDEO_FW_DS
        log_info "Using default downstream firmware path: $VIDEO_FW_DS"
    fi
fi

# Decide final app path
final_app=""
if [ -n "$VIDEO_APP" ] && [ -x "$VIDEO_APP" ]; then
    final_app="$VIDEO_APP"
else
    if command -v iris_v4l2_test >/dev/null 2>&1; then
        final_app="$(command -v iris_v4l2_test)"
    else
        if [ -x "/usr/bin/iris_v4l2_test" ]; then
            final_app="/usr/bin/iris_v4l2_test"
        else
            if [ -x "/data/vendor/iris_test_app/iris_v4l2_test" ]; then
                final_app="/data/vendor/iris_test_app/iris_v4l2_test"
            fi
        fi
    fi
fi

# If iris_v4l2_test is missing but we are running compliance, that's fine.
if [ -z "$final_app" ] && [ "$RUN_V4L2_COMPLIANCE" -ne 1 ]; then
    log_skip "$TESTNAME SKIP - iris_v4l2_test not available (VIDEO_APP=$VIDEO_APP). Provide --app or install the binary."
    printf '%s\n' "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

if [ -n "$final_app" ]; then
    VIDEO_APP="$final_app"
    export VIDEO_APP
fi

# --- Resolve testcase path and cd so outputs land here ---
if ! check_dependencies grep sed awk find sort; then
    log_skip "$TESTNAME SKIP - required tools missing"
    printf '%s\n' "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

test_path="$(find_test_case_by_name "$TESTNAME" 2>/dev/null || echo "$SCRIPT_DIR")"

if ! cd "$test_path"; then
    log_error "cd failed: $test_path"
    printf '%s\n' "$TESTNAME FAIL" >"$RES_FILE"
    exit 1
fi

# --- New: split logs by flavor, share bundle cache at root ---
LOG_ROOT="./logs_${TESTNAME}"
LOG_DIR="$LOG_ROOT"

if [ -n "$LOG_FLAVOR" ]; then
    LOG_DIR="$LOG_ROOT/$LOG_FLAVOR"
fi

mkdir -p "$LOG_DIR"
export LOG_DIR
export LOG_ROOT

# --- Detect top-level vs sub-run ---
TOP_LEVEL_RUN="1"
if [ -n "$LOG_FLAVOR" ]; then
    TOP_LEVEL_RUN="0"
fi

# --- Opt-in local media bundle extraction ---
if [ -n "$CLIPS_TAR" ]; then
    clips_dest_resolved="$CLIPS_DEST"
    if [ -z "$clips_dest_resolved" ]; then
        if [ -n "$CFG" ] && [ -f "$CFG" ]; then
            clips_dest_resolved="$(cd "$(dirname "$CFG")" 2>/dev/null && pwd)"
        elif [ -n "$DIR" ] && [ -d "$DIR" ]; then
            clips_dest_resolved="$DIR"
        else
            clips_dest_resolved="$test_path"
        fi
    fi
    mkdir -p "$clips_dest_resolved" 2>/dev/null || true
    video_step "" "Extract custom clips tar → $clips_dest_resolved"
    case "$CLIPS_TAR" in
        *.tar|*.tar.gz|*.tgz|*.tar.xz|*.txz|*.tar.zst|*.tar.bz2|*.tbz2)
            if command -v tar >/dev/null 2>&1; then
                tar -xf "$CLIPS_TAR" -C "$clips_dest_resolved" 2>/dev/null || true
            else
                log_warn "tar not available; cannot extract --clips-tar"
            fi
            ;;
        *.zip)
            if command -v unzip >/dev/null 2>&1; then
                unzip -o "$CLIPS_TAR" -d "$clips_dest_resolved" >/dev/null 2>&1 || true
            else
                log_warn "unzip not available; cannot extract --clips-tar"
            fi
            ;;
        *)
            log_warn "Unrecognized archive type for --clips-tar: $CLIPS_TAR"
            ;;
    esac
fi

# Ensure rootfs meets minimum size (2GiB) BEFORE any downloads — only once
if [ "$TOP_LEVEL_RUN" -eq 1 ]; then
    ensure_rootfs_min_size 2
else
    log_info "Sub-run: skipping rootfs size check."
fi

# If we're going to fetch, ensure network is online first — only once
if [ "$TOP_LEVEL_RUN" -eq 1 ]; then
    if { [ "$EXTRACT_INPUT_CLIPS" = "true" ] && [ -z "$CFG" ] && [ -z "$DIR" ] && [ -z "$CLIPS_TAR" ]; } || [ "$RUN_V4L2_COMPLIANCE" -eq 1 ]; then
        # Skip net check if we have a local tar
        if [ -n "$CLIPS_TAR" ]; then
             log_info "Custom --clips-tar provided; skipping network check."
        else
            net_rc=1
            if command -v check_network_status_rc >/dev/null 2>&1; then
                check_network_status_rc
                net_rc=$?
            elif command -v check_network_status >/dev/null 2>&1; then
                check_network_status >/dev/null 2>&1
                net_rc=$?
            fi

            if [ "$net_rc" -ne 0 ]; then
                video_step "" "Bring network online"
                ensure_network_online || true
                sleep "${NET_STABILIZE_SLEEP:-5}"
            else
                sleep "${NET_STABILIZE_SLEEP:-5}"
            fi
        fi
    fi
fi

# --- Early guard: bail out BEFORE any download if Kodiak-downstream lacks --downstream-fw ---
early_plat="$VIDEO_PLATFORM"
if [ -z "$early_plat" ]; then
    early_plat="$(video_detect_platform)"
fi

early_stack="$(video_normalize_stack "$VIDEO_STACK")"

if [ "$early_plat" = "kodiak" ] && [ "$early_stack" = "downstream" ] && [ -z "${VIDEO_FW_DS:-}" ]; then
    log_skip "On Kodiak, downstream/overlay requires --downstream-fw <file>; skipping run."
    printf '%s\n' "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

# --- Optional early fetch of bundle ---
if [ "$TOP_LEVEL_RUN" -eq 1 ]; then
    if { [ "$EXTRACT_INPUT_CLIPS" = "true" ] && [ -z "$CFG" ] && [ -z "$DIR" ]; } || [ "$RUN_V4L2_COMPLIANCE" -eq 1 ]; then
        if [ -n "$CLIPS_TAR" ]; then
            log_info "Custom --clips-tar provided; skipping online early fetch."
        else
            video_step "" "Early bundle fetch (best-effort)"
            saved_log_dir="$LOG_DIR"
            LOG_DIR="$LOG_ROOT"
            export LOG_DIR

            extract_tar_from_url "$TAR_URL" || true

            LOG_DIR="$saved_log_dir"
            export LOG_DIR
        fi
    fi
fi

# --- If user asked for both stacks, re-invoke ourselves ---
if [ "${VIDEO_STACK}" = "both" ]; then
    build_reexec_args() {
        args=""
        if [ -n "${CFG:-}" ]; then args="$args --config '$CFG'"; fi
        if [ -n "${DIR:-}" ]; then args="$args --dir '$DIR'"; fi
        if [ -n "${PATTERN:-}" ]; then args="$args --pattern '$PATTERN'"; fi
        if [ -n "${TIMEOUT:-}" ]; then args="$args --timeout $TIMEOUT"; fi
        if [ "${STRICT:-0}" -eq 1 ]; then args="$args --strict"; fi
        if [ "${DMESG_SCAN:-1}" -eq 0 ]; then args="$args --no-dmesg"; fi
        if [ -n "${MAX:-}" ]; then args="$args --max $MAX"; fi
        if [ "${STOP_ON_FAIL:-0}" -eq 1 ]; then args="$args --stop-on-fail"; fi
        if [ -n "${LOGLEVEL:-}" ]; then args="$args --loglevel $LOGLEVEL"; fi
        if [ -n "${REPEAT:-}" ]; then args="$args --repeat $REPEAT"; fi
        if [ -n "${REPEAT_DELAY:-}" ]; then args="$args --repeat-delay $REPEAT_DELAY"; fi
        if [ -n "${REPEAT_POLICY:-}" ]; then args="$args --repeat-policy '$REPEAT_POLICY'"; fi
        if [ -n "${JUNIT_OUT:-}" ]; then args="$args --junit '$JUNIT_OUT'"; fi
        if [ "${DRY:-0}" -eq 1 ]; then args="$args --dry-run"; fi
        if [ -n "${EXTRACT_INPUT_CLIPS:-}" ]; then args="$args --extract-input-clips $EXTRACT_INPUT_CLIPS"; fi
        if [ "${VERBOSE:-0}" -eq 1 ]; then args="$args --verbose"; fi
        if [ -n "${VIDEO_PLATFORM:-}" ]; then args="$args --platform '$VIDEO_PLATFORM'"; fi
        if [ -n "${VIDEO_FW_DS:-}" ]; then args="$args --downstream-fw '$VIDEO_FW_DS'"; fi
        if [ "${VIDEO_FORCE:-0}" -eq 1 ]; then args="$args --force"; fi
        if [ -n "${VIDEO_APP:-}" ]; then args="$args --app '$VIDEO_APP'"; fi
        if [ -n "${SSID:-}" ]; then args="$args --ssid '$SSID'"; fi
        if [ -n "${PASSWORD:-}" ]; then args="$args --password '$PASSWORD'"; fi
        if [ -n "${APP_LAUNCH_SLEEP:-}" ]; then args="$args --app-launch-sleep $APP_LAUNCH_SLEEP"; fi
        if [ -n "${INTER_TEST_SLEEP:-}" ]; then args="$args --inter-test-sleep $INTER_TEST_SLEEP"; fi
        if [ "${COMPLIANCE_H264:-0}" -eq 1 ]; then args="$args --compliance-h264"; fi
        if [ "${RUN_V4L2_COMPLIANCE:-0}" -eq 1 ]; then args="$args --v4l2-compliance"; fi
        if [ -n "${V4L2_COMPLIANCE_BIN_PATH:-}" ]; then args="$args --v4l2-compliance-bin '$V4L2_COMPLIANCE_BIN_PATH'"; fi
        if [ -n "${RETRY_ON_FAIL:-}" ]; then args="$args --retry-on-fail $RETRY_ON_FAIL"; fi
        if [ -n "${POST_TEST_SLEEP:-}" ]; then args="$args --post-test-sleep $POST_TEST_SLEEP"; fi
        if [ -n "${CLIPS_TAR:-}" ]; then args="$args --clips-tar '$CLIPS_TAR'"; fi
        if [ -n "${CLIPS_DEST:-}" ]; then args="$args --clips-dest '$CLIPS_DEST'"; fi
        printf "%s" "$args"
    }

    reexec_args="$(build_reexec_args)"

    log_info "[both] starting BASE (upstream) pass"
    sh -c "'$0' --stack base --log-flavor upstream $reexec_args"
    rc_base=$?

    log_info "[both] starting OVERLAY (downstream) pass"
    sh -c "'$0' --stack overlay --log-flavor downstream $reexec_args"
    rc_overlay=$?

    if [ "$rc_base" -eq 0 ] && [ "$rc_overlay" -eq 0 ] ; then
        log_pass "[both] both passes succeeded"
        printf '%s\n' "$TESTNAME PASS" > "$RES_FILE"
        exit 0
    else
        log_fail "[both] one or more passes failed"
        printf '%s\n' "$TESTNAME FAIL" >"$RES_FILE"
        exit 1
    fi
fi

log_info "----------------------------------------------------------------------"
log_info "---------------------- Starting $TESTNAME (modular) -------------------"
log_info "STACK=$VIDEO_STACK PLATFORM=${VIDEO_PLATFORM:-auto} STRICT=$STRICT DMESG_SCAN=$DMESG_SCAN"
log_info "TIMEOUT=${TIMEOUT}s LOGLEVEL=$LOGLEVEL"
log_info "APP=$VIDEO_APP"
if [ "$COMPLIANCE_H264" -eq 1 ]; then
    log_info "MODE=COMPLIANCE_H264 (Selecting 1 Decode + 1 Encode H.264)"
fi
if [ "$RUN_V4L2_COMPLIANCE" -eq 1 ]; then
    log_info "MODE=V4L2_COMPLIANCE (Running v4l2-compliance tool)"
fi

if [ -n "$VIDEO_FW_DS" ]; then log_info "Downstream FW override: $VIDEO_FW_DS"; fi
if [ -n "$KO_TREE$KO_DIRS" ]; then log_info "Custom module source active"; fi
log_info "SLEEPS: app-launch=${APP_LAUNCH_SLEEP}s, inter-test=${INTER_TEST_SLEEP}s"

video_warn_if_not_root

# --- Ensure desired video stack ---
plat="$VIDEO_PLATFORM"
if [ -z "$plat" ]; then
    plat=$(video_detect_platform)
fi
log_info "Detected platform: $plat"

VIDEO_STACK="$(video_normalize_stack "$VIDEO_STACK")"
pre_stack="$(video_stack_status "$plat")"
log_info "Current video stack (pre): $pre_stack"

if [ "$plat" = "kodiak" ]; then
    case "$VIDEO_STACK" in
        upstream|up|base)
            video_step "" "Kodiak upstream firmware install"
            video_kodiak_install_firmware || true
            ;;
        downstream|overlay|down)
            if [ -z "$VIDEO_FW_DS" ] || [ ! -f "$VIDEO_FW_DS" ]; then
                log_skip "On Kodiak, downstream requires --downstream-fw <file>; skipping."
                printf '%s\n' "$TESTNAME SKIP" >"$RES_FILE"
                exit 0
            fi
            ;;
    esac
fi

# --- Custom .ko staging ---
if [ -n "${KO_DIRS:-}" ]; then
    case "$(video_normalize_stack "$VIDEO_STACK")" in
        downstream|overlay|down)
            KVER="$(uname -r 2>/dev/null || printf '%s' unknown)"
            if command -v video_find_module_file >/dev/null 2>&1; then
                modpath="$(video_find_module_file iris_vpu "$KO_DIRS" 2>/dev/null | tail -n1 | tr -d '\r')"
            fi
            if [ -n "$modpath" ] && [ -f "$modpath" ]; then
                log_info "Using custom iris_vpu candidate: $modpath"
                if command -v video_ensure_moddir_install >/dev/null 2>&1; then
                    video_ensure_moddir_install "$modpath" "$KVER" >/dev/null 2>&1 || true
                fi
                if command -v depmod >/dev/null 2>&1; then
                    depmod -a "$KVER" >/dev/null 2>&1 || true
                fi
            fi
            ;;
    esac
fi

video_step "" "Apply desired stack = $VIDEO_STACK"
video_ensure_stack "$VIDEO_STACK" "$plat" >/dev/null 2>&1 || true
post_stack="$(video_stack_status "$plat")"
log_info "Video stack (post): $post_stack"

# --- Custom .ko load assist ---
if [ -n "${KO_DIRS:-}" ]; then
    case "$(video_normalize_stack "$VIDEO_STACK")" in
        downstream|overlay|down)
            if ! video_has_module_loaded iris_vpu 2>/dev/null; then
                if command -v video_find_module_file >/dev/null 2>&1; then
                    modpath2="$(video_find_module_file iris_vpu "$KO_DIRS" 2>/dev/null | tail -n1 | tr -d '\r')"
                fi
                if [ "$KO_PREFER_CUSTOM" = "1" ] && [ -n "$modpath2" ] && [ -f "$modpath2" ]; then
                    log_info "Prefer custom: insmod with deps: $modpath2"
                    if command -v video_insmod_with_deps >/dev/null 2>&1; then
                        video_insmod_with_deps "$modpath2" >/dev/null 2>&1 || true
                    fi
                fi
            fi
            ;;
    esac
fi

video_step "" "Refresh V4L device nodes"
video_clean_and_refresh_v4l || true

# --- Stack Validation ---
case "$VIDEO_STACK" in
  upstream|up|base)
    if ! video_validate_upstream_loaded "$plat"; then
        log_fail "[STACK] Upstream requested but verification failed; aborting."
        printf '%s\n' "$TESTNAME FAIL" >"$RES_FILE"
        exit 1
    fi
    ;;
  downstream|overlay|down)
    if ! video_validate_downstream_loaded "$plat"; then
        log_fail "[STACK] Downstream requested but verification failed; aborting."
        printf '%s\n' "$TESTNAME FAIL" >"$RES_FILE"
        exit 1
    fi
    ;;
esac

# ==============================================================================
#  OPT-IN: Run v4l2-compliance instead of iris_v4l2_test
#  NOTE: This block handles ONLY H.264 Compliance as requested
# ==============================================================================
if [ "$RUN_V4L2_COMPLIANCE" -eq 1 ]; then
    log_info "----------------------------------------------------------------------"
    log_info "Running v4l2-compliance mode (H.264 ONLY)"

    # 1. Determine binary path
    v4l2_bin=""
    if [ -n "$V4L2_COMPLIANCE_BIN_PATH" ]; then
        if [ -x "$V4L2_COMPLIANCE_BIN_PATH" ]; then
            v4l2_bin="$V4L2_COMPLIANCE_BIN_PATH"
        else
            log_warn "Provided binary $V4L2_COMPLIANCE_BIN_PATH not executable or missing."
        fi
    fi

    # Fallback to PATH or common locations if user arg failed or wasn't provided
    if [ -z "$v4l2_bin" ]; then
        if command -v v4l2-compliance >/dev/null 2>&1; then
            v4l2_bin="$(command -v v4l2-compliance)"
        elif [ -x "/usr/bin/v4l2-compliance" ]; then
            v4l2_bin="/usr/bin/v4l2-compliance"
        elif [ -x "/usr/local/bin/v4l2-compliance" ]; then
            v4l2_bin="/usr/local/bin/v4l2-compliance"
        fi
    fi

    if [ -z "$v4l2_bin" ]; then
        echo "[ERROR] v4l2-compliance tool not found in PATH or standard locations."
        log_fail "v4l2-compliance tool not found in PATH"
        printf '%s\n' "$TESTNAME FAIL" >"$RES_FILE"
        exit 1
    fi
    
    log_info "Found compliance tool: $v4l2_bin"

    # 2. Locate ONE H.264 media file (*.264 or *.h264)
    # Priority: CLIPS_DEST -> . -> test_path -> /data/vendor/iris_test_app
    search_dirs="${CLIPS_DEST:-} . $test_path $LOG_ROOT /data/vendor/iris_test_app"
    media_file=""

    # Helper function to find first file matching pattern in search dirs
    find_first_match() {
        pattern="$1"
        for d in $search_dirs; do
            if [ -d "$d" ]; then
                # Find first match, ignore stderr
                found=$(find "$d" -maxdepth 2 -name "$pattern" 2>/dev/null | head -n 1)
                if [ -n "$found" ]; then
                    echo "$found"
                    return 0
                fi
            fi
        done
        return 1
    }

    # Try .264 first, then .h264
    media_file=$(find_first_match "*.264")
    if [ -z "$media_file" ]; then
        media_file=$(find_first_match "*.h264")
    fi

    if [ -z "$media_file" ]; then
        echo "[ERROR] No H.264 media file found (*.264 or *.h264)."
        log_fail "No H.264 media file found. Ensure clips are fetched."
        printf '%s\n' "$TESTNAME FAIL" >"$RES_FILE"
        exit 1
    fi

    log_info "Using H.264 media file: $media_file"
    
    # 3. Execute Decoder (H.264)
    log_info ">>> Running Decoder Compliance (H.264): /dev/video0"
    log_info "CMD: $v4l2_bin -d /dev/video0 -s5 --stream-from=\"$media_file\""
    
    "$v4l2_bin" -d /dev/video0 -s5 --stream-from="$media_file"
    rc_dec=$?
    log_info "Decoder exited with rc=$rc_dec"

    # 4. Execute Encoder (Generic)
    log_info ">>> Running Encoder Compliance: /dev/video1"
    log_info "CMD: $v4l2_bin -d /dev/video1 -s"
    
    "$v4l2_bin" -d /dev/video1 -s
    rc_enc=$?
    log_info "Encoder exited with rc=$rc_enc"

    # Final Result for Compliance Mode
    if [ "$rc_dec" -eq 0 ] && [ "$rc_enc" -eq 0 ]; then
        log_pass "v4l2-compliance (H.264): PASS"
        printf '%s\n' "$TESTNAME PASS" > "$RES_FILE"
        exit 0
    else
        log_fail "v4l2-compliance (H.264): FAIL (dec=$rc_dec enc=$rc_enc)"
        printf '%s\n' "$TESTNAME FAIL" > "$RES_FILE"
        exit 1
    fi
fi
# ==============================================================================

# --- Discover config list (Standard App Mode) ---
CFG_LIST="$LOG_DIR/.cfgs"
: > "$CFG_LIST"

if [ -n "$CFG" ] && [ -d "$CFG" ]; then
    DIR="$CFG"
    CFG=""
fi

if [ -z "$CFG" ]; then
    if [ -n "$DIR" ]; then
        base_dir="$DIR"
        if [ -n "$PATTERN" ]; then
            find "$base_dir" -type f -name "$PATTERN" 2>/dev/null | sort > "$CFG_LIST"
        else
            find "$base_dir" -type f -name "*.json" 2>/dev/null | sort > "$CFG_LIST"
        fi
        log_info "Using custom config directory: $base_dir"
    else
        log_info "No --config passed, searching for JSON under testcase dir: $test_path"
        find "$test_path" -type f -name "*.json" 2>/dev/null | sort > "$CFG_LIST"
    fi
else
    printf '%s\n' "$CFG" > "$CFG_LIST"
fi

if [ ! -s "$CFG_LIST" ]; then
    log_skip "$TESTNAME SKIP - no JSON configs found"
    printf '%s\n' "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

# ==============================================================================
#  Compliance H.264 Filtering (1 Decode + 1 Encode for iris_v4l2_test)
# ==============================================================================
if [ "$COMPLIANCE_H264" -eq 1 ]; then
    log_info "Applying Compliance H264 Filter: selecting 1 Decode + 1 Encode (H264)..."
    found_dec=0
    found_enc=0
    temp_list="$LOG_DIR/.cfgs.compliance"
    : > "$temp_list"

    while IFS= read -r cfg; do
        if [ "$found_dec" -eq 1 ] && [ "$found_enc" -eq 1 ]; then break; fi
        if [ -z "$cfg" ]; then continue; fi

        raw_codec="$(video_guess_codec_from_cfg "$cfg")"
        canon_codec="$(video_canon_codec "$raw_codec")"
        
        if echo "$canon_codec" | grep -q "h264"; then
            if video_is_decode_cfg "$cfg"; then
                if [ "$found_dec" -eq 0 ]; then
                    echo "$cfg" >> "$temp_list"
                    found_dec=1
                    log_info "  [Compliance] Selected Decoder: $(basename "$cfg")"
                fi
            else
                if [ "$found_enc" -eq 0 ]; then
                    echo "$cfg" >> "$temp_list"
                    found_enc=1
                    log_info "  [Compliance] Selected Encoder: $(basename "$cfg")"
                fi
            fi
        fi
    done < "$CFG_LIST"
    mv "$temp_list" "$CFG_LIST"
    if [ ! -s "$CFG_LIST" ]; then
        log_warn "[Compliance] No H264 configs found! List is empty."
    fi
fi
# ==============================================================================

cfg_count="$(wc -l < "$CFG_LIST" 2>/dev/null | tr -d ' ')"
log_info "Discovered $cfg_count JSON config(s) to run"

# --- JUnit prep / results files ---
JUNIT_TMP="$LOG_DIR/.junit_cases.xml"
: > "$JUNIT_TMP"

printf '%s\n' "mode,id,result,name,elapsed,pass_runs,fail_runs" > "$LOG_DIR/results.csv"
: > "$LOG_DIR/summary.txt"

# --- Suite loop ---
total="0"
pass="0"
fail="0"
skip="0"
suite_rc="0"
first_case="1"

while IFS= read -r cfg; do
    if [ -z "$cfg" ]; then continue; fi
    if [ "$first_case" -eq 0 ] 2>/dev/null; then
        if [ "$INTER_TEST_SLEEP" -gt 0 ] 2>/dev/null; then
            log_info "Inter-test sleep ${INTER_TEST_SLEEP}s"
            sleep "$INTER_TEST_SLEEP"
        fi
    fi
    first_case="0"
    total=$((total + 1))

    if video_is_decode_cfg "$cfg"; then mode="decode"; else mode="encode"; fi

    name_and_id="$(video_pretty_name_from_cfg "$cfg")"
    pretty="$(printf '%s' "$name_and_id" | cut -d'|' -f1)"
    raw_codec="$(video_guess_codec_from_cfg "$cfg")"
    codec="$(video_canon_codec "$raw_codec")"
    safe_codec="$(printf '%s' "$codec" | tr ' /' '__')"
    base_noext="$(basename "$cfg" .json)"
    id="${mode}-${safe_codec}-${base_noext}"

    log_info "----------------------------------------------------------------------"
    log_info "[$id] START — mode=$mode codec=$codec name=\"$pretty\" cfg=\"$cfg\""

    video_step "$id" "Check /dev/video* presence"
    if ! video_devices_present; then
        log_skip "[$id] SKIP - no /dev/video* nodes"
        printf '%s\n' "$id SKIP $pretty" >> "$LOG_DIR/summary.txt"
        printf '%s\n' "$mode,$id,SKIP,$pretty,0,0,0" >> "$LOG_DIR/results.csv"
        skip=$((skip + 1))
        continue
    fi

    if [ "$EXTRACT_INPUT_CLIPS" = "true" ] && [ -z "$CFG" ] && [ -z "$DIR" ]; then
        if [ -n "$CLIPS_TAR" ]; then
            log_info "[$id] Custom --clips-tar provided; skipping online per-test fetch."
        else
            video_step "$id" "Ensure clips present or fetch"
            saved_log_dir_case="$LOG_DIR"
            LOG_DIR="$LOG_ROOT"
            export LOG_DIR
            video_ensure_clips_present_or_fetch "$cfg" "$TAR_URL"
            ce=$?
            LOG_DIR="$saved_log_dir_case"
            export LOG_DIR
            if [ "$ce" -ne 0 ]; then
               log_fail "[$id] fetch failed"
               fail=$((fail + 1))
               suite_rc=1
               continue
            fi
        fi
    fi

    video_step "$id" "Verify required clips exist"
    missing_case="0"
    clips_file="$LOG_DIR/.clips.$$"
    video_extract_input_clips "$cfg" > "$clips_file"
    if [ -s "$clips_file" ]; then
        while IFS= read -r pth; do
            if [ -z "$pth" ]; then continue; fi
            case "$pth" in
                /*) abs="$pth" ;;
                *) abs="$(cd "$(dirname "$cfg")" 2>/dev/null && pwd)/$pth" ;;
            esac
            if [ ! -f "$abs" ]; then missing_case=1; fi
        done < "$clips_file"
    fi
    rm -f "$clips_file" 2>/dev/null || true

    if [ "$missing_case" -eq 1 ] 2>/dev/null; then
        log_fail "[$id] Required input clip(s) not present — $pretty"
        printf '%s\n' "$id FAIL $pretty" >> "$LOG_DIR/summary.txt"
        printf '%s\n' "$mode,$id,FAIL,$pretty,0,0,0" >> "$LOG_DIR/results.csv"
        fail=$((fail + 1))
        suite_rc=1
        continue
    fi

    if [ "$DRY" -eq 1 ]; then
        log_info "[dry] [$id] $VIDEO_APP --config \"$cfg\" --loglevel $LOGLEVEL"
        continue
    fi

    pass_runs="0"
    fail_runs="0"
    rep="1"
    start_case="$(date +%s 2>/dev/null || printf '%s' 0)"
    logf="$LOG_DIR/${id}.log"

    while [ "$rep" -le "$REPEAT" ]; do
        if [ "$REPEAT" -gt 1 ]; then log_info "[$id] repeat $rep/$REPEAT"; fi
        video_step "$id" "Execute app"
        log_info "[$id] CMD: $VIDEO_APP --config \"$cfg\" --loglevel $LOGLEVEL"

        if [ "$APP_LAUNCH_SLEEP" -gt 0 ] 2>/dev/null; then sleep "$APP_LAUNCH_SLEEP"; fi

        if video_run_once "$cfg" "$logf" "$TIMEOUT" "$SUCCESS_RE" "$LOGLEVEL"; then
            pass_runs=$((pass_runs + 1))
        else
            fail_runs=$((fail_runs + 1))
        fi
        if [ "$rep" -lt "$REPEAT" ] && [ "$REPEAT_DELAY" -gt 0 ]; then sleep "$REPEAT_DELAY"; fi
        rep=$((rep + 1))
    done

    end_case="$(date +%s 2>/dev/null || printf '%s' 0)"
    elapsed=$((end_case - start_case))

    final="FAIL"
    case "$REPEAT_POLICY" in
        any) if [ "$pass_runs" -ge 1 ]; then final="PASS"; fi ;;
        all|*) if [ "$fail_runs" -eq 0 ]; then final="PASS"; fi ;;
    esac

    video_step "$id" "DMESG triage"
    video_scan_dmesg_if_enabled "$DMESG_SCAN" "$LOG_DIR"
    if [ "$?" -eq 0 ] && [ "$STRICT" -eq 1 ]; then final="FAIL"; fi

    # Retry logic
    if [ "$final" = "FAIL" ] && [ "$RETRY_ON_FAIL" -gt 0 ] 2>/dev/null; then
        r=1
        log_info "[$id] RETRY_ON_FAIL: up to $RETRY_ON_FAIL additional attempt(s)"
        while [ "$r" -le "$RETRY_ON_FAIL" ]; do
            log_info "[$id] retry attempt $r/$RETRY_ON_FAIL"
            if video_run_once "$cfg" "$logf" "$TIMEOUT" "$SUCCESS_RE" "$LOGLEVEL"; then
                pass_runs=$((pass_runs + 1))
                final="PASS"
                log_pass "[$id] RETRY succeeded — marking PASS"
                break
            fi
            r=$((r + 1))
        done
    fi

    video_junit_append_case "$JUNIT_TMP" "Video.$mode" "$pretty" "$elapsed" "$final" "$logf"

    case "$final" in
        PASS) log_pass "[$id] PASS ($pass_runs/$REPEAT ok) — $pretty" ;;
        FAIL) log_fail "[$id] FAIL (pass=$pass_runs fail=$fail_runs) — $pretty" ;;
        SKIP) log_skip "[$id] SKIP — $pretty" ;;
    esac

    printf '%s\n' "$id $final $pretty" >> "$LOG_DIR/summary.txt"
    printf '%s\n' "$mode,$id,$final,$pretty,$elapsed,$pass_runs,$fail_runs" >> "$LOG_DIR/results.csv"

    if [ "$final" = "PASS" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        suite_rc=1
        if [ "$STOP_ON_FAIL" -eq 1 ]; then break; fi
    fi

    if [ "$POST_TEST_SLEEP" -gt 0 ] 2>/dev/null; then sleep "$POST_TEST_SLEEP"; fi

    if [ "$MAX" -gt 0 ] && [ "$total" -ge "$MAX" ]; then break; fi
done < "$CFG_LIST"

log_info "Summary: total=$total pass=$pass fail=$fail skip=$skip"

# --- JUnit finalize ---
if [ -n "$JUNIT_OUT" ]; then
    tests=$((pass + fail + skip))
    {
        printf '<testsuite name="%s" tests="%s" failures="%s" skipped="%s">\n' "$TESTNAME" "$tests" "$fail" "$skip"
        cat "$JUNIT_TMP"
        printf '</testsuite>\n'
    } > "$JUNIT_OUT"
fi

if [ "$pass" -eq 0 ] && [ "$fail" -eq 0 ] && [ "$skip" -gt 0 ]; then
    log_skip "$TESTNAME: SKIP (all $skip test(s) skipped)"
    printf '%s\n' "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

if [ "$suite_rc" -eq 0 ]; then
    log_pass "$TESTNAME: PASS"
    printf '%s\n' "$TESTNAME PASS" >"$RES_FILE"
    exit 0
else
    log_fail "$TESTNAME: FAIL"
    printf '%s\n' "$TESTNAME FAIL" >"$RES_FILE"
    exit 1
fi