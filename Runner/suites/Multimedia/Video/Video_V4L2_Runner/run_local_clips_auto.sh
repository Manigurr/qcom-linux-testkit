#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
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
# NOTE: We intentionally **do not export** any new vars. They stay local to this shell.
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
if [ -z "${TIMEOUT:-}" ];        then TIMEOUT="60";       fi
if [ -z "${STRICT:-}" ];         then STRICT="0";          fi
if [ -z "${DMESG_SCAN:-}" ];     then DMESG_SCAN="1";      fi
PATTERN=""
if [ -z "${MAX:-}" ];            then MAX="0";              fi
if [ -z "${STOP_ON_FAIL:-}" ];   then STOP_ON_FAIL="0";    fi
DRY="0"
if [ -z "${EXTRACT_INPUT_CLIPS:-}" ]; then EXTRACT_INPUT_CLIPS="true"; fi
if [ -z "${SUCCESS_RE:-}" ];     then SUCCESS_RE="SUCCESS"; fi
if [ -z "${LOGLEVEL:-}" ];       then LOGLEVEL="15";        fi
if [ -z "${REPEAT:-}" ];         then REPEAT="1";           fi
if [ -z "${REPEAT_DELAY:-}" ];   then REPEAT_DELAY="0";    fi
if [ -z "${REPEAT_POLICY:-}" ];  then REPEAT_POLICY="all"; fi
JUNIT_OUT=""
VERBOSE="0"

# --- Stabilizers (opt-in) ---
RETRY_ON_FAIL="0"     # extra attempts after a FAIL
POST_TEST_SLEEP="0"   # settle time after each case

# --- Custom module source (opt-in; default is untouched) ---
KO_DIRS=""           # colon-separated list of dirs that contain .ko files
KO_TREE=""           # alt root that has lib/modules/$KVER
KO_TARBALL=""        # optional tarball that we unpack once
KO_PREFER_CUSTOM="0" # 1 = try custom first; default 0 = system first

# --- Opt-in: custom media bundle tar (always honored even with --dir/--config) ---
CLIPS_TAR=""         # /path/to/clips.tar[.gz|.xz|.zst|.bz2|.tgz|.tbz2|.zip]
CLIPS_DEST=""        # optional extraction destination; defaults to cfg/dir root or testcase dir

if [ -z "${VIDEO_STACK:-}" ];          then VIDEO_STACK="auto";                      fi
if [ -z "${VIDEO_PLATFORM:-}" ];       then VIDEO_PLATFORM="";                       fi
if [ -z "${VIDEO_FW_DS:-}" ];          then VIDEO_FW_DS="";                          fi
if [ -z "${VIDEO_FW_BACKUP_DIR:-}" ];  then VIDEO_FW_BACKUP_DIR="";                  fi
if [ -z "${VIDEO_NO_REBOOT:-}" ];      then VIDEO_NO_REBOOT="0";                     fi
if [ -z "${VIDEO_FORCE:-}" ];          then VIDEO_FORCE="0";                          fi
if [ -z "${VIDEO_APP:-}" ];            then VIDEO_APP="/usr/bin/iris_v4l2_test";      fi

# --- Net/DL tunables (no-op if helpers ignore them) ---
if [ -z "${NET_STABILIZE_SLEEP:-}" ];  then NET_STABILIZE_SLEEP="5";   fi
if [ -z "${WGET_TIMEOUT_SECS:-}" ];    then WGET_TIMEOUT_SECS="120";   fi
if [ -z "${WGET_TRIES:-}" ];           then WGET_TRIES="2";             fi

# --- Stability sleeps ---
if [ -z "${APP_LAUNCH_SLEEP:-}" ];     then APP_LAUNCH_SLEEP="1";      fi
if [ -z "${INTER_TEST_SLEEP:-}" ];     then INTER_TEST_SLEEP="2";      fi

# --- log flavor for --stack both sub-runs ---
LOG_FLAVOR=""

usage() {
    cat <<EOF
Usage: $0 [--config path.json|/path/dir] [--dir DIR] [--pattern GLOB]
          [--timeout S] [--strict] [--no-dmesg] [--max N] [--stop-on-fail]
          [--loglevel N] [--extract-input-clips true|false]
          [--repeat N] [--repeat-delay S] [--repeat-policy all|any]
          [--junit FILE] [--dry-run] [--verbose]
          [--stack auto|upstream|downstream|base|overlay|up|down|both]
          [--platform lemans|monaco|kodiak|pakala]
          [--downstream-fw PATH] [--force]
          [--app /path/to/iris_v4l2_test]
          [--ssid SSID] [--password PASS]
          [--ko-dir DIR[:DIR2:...]] # opt-in: search these dirs for .ko on failure
          [--ko-tree ROOT]          # opt-in: modprobe -d ROOT (expects lib/modules/\$(uname -r))
          [--ko-tar FILE.tar[.gz|.xz]] # opt-in: unpack once under /run/iris_mods/\$KVER
          [--ko-prefer-custom]      # opt-in: try custom sources before system
          [--app-launch-sleep S] [--inter-test-sleep S]
          [--log-flavor NAME]       # internal: e.g. upstream or downstream (used by --stack both)
          # --- Stabilizers ---
          [--retry-on-fail N]       # retry up to N times if a case ends FAIL
          [--post-test-sleep S]     # sleep S seconds after each case
          # --- Media bundle (opt-in, local tar) ---
          [--clips-tar /path/to/clips.tar.gz]
          [--clips-dest DIR]
EOF
}

CFG=""
DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --config)           shift; CFG="$1"             ;;
        --dir)              shift; DIR="$1"             ;;
        --pattern)          shift; PATTERN="$1"         ;;
        --timeout)          shift; TIMEOUT="$1"         ;;
        --strict)           STRICT=1                    ;;
        --no-dmesg)         DMESG_SCAN=0                ;;
        --max)              shift; MAX="$1"             ;;
        --stop-on-fail)     STOP_ON_FAIL=1              ;;
        --loglevel)         shift; LOGLEVEL="$1"        ;;
        --repeat)           shift; REPEAT="$1"          ;;
        --repeat-delay)     shift; REPEAT_DELAY="$1"    ;;
        --repeat-policy)    shift; REPEAT_POLICY="$1"   ;;
        --junit)            shift; JUNIT_OUT="$1"       ;;
        --dry-run)          DRY=1                       ;;
        --extract-input-clips) shift; EXTRACT_INPUT_CLIPS="$1" ;;
        --verbose)          VERBOSE=1                   ;;
        --stack)            shift; VIDEO_STACK="$1"     ;;
        --platform)         shift; VIDEO_PLATFORM="$1"  ;;
        --downstream-fw)    shift; VIDEO_FW_DS="$1"     ;;
        --force)            VIDEO_FORCE=1               ;;
        --app)              shift; VIDEO_APP="$1"       ;;
        --ssid)             shift; SSID="$1"            ;;
        --password)         shift; PASSWORD="$1"        ;;
        --ko-dir)           shift; KO_DIRS="$1"         ;;
        --ko-tree)          shift; KO_TREE="$1"         ;;
        --ko-tar)           shift; KO_TARBALL="$1"      ;;
        --ko-prefer-custom) KO_PREFER_CUSTOM="1"        ;;
        --app-launch-sleep) shift; APP_LAUNCH_SLEEP="$1" ;;
        --inter-test-sleep) shift; INTER_TEST_SLEEP="$1" ;;
        --log-flavor)       shift; LOG_FLAVOR="$1"      ;;
        --retry-on-fail)    shift; RETRY_ON_FAIL="$1"   ;;
        --post-test-sleep)  shift; POST_TEST_SLEEP="$1" ;;
        --clips-tar)        shift; CLIPS_TAR="$1"       ;;
        --clips-dest)       shift; CLIPS_DEST="$1"      ;;
        --help|-h)          usage; exit 0               ;;
        *)                  log_warn "Unknown arg: $1"  ;;
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

# --- Optional: unpack a custom module tarball once ---
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
            *) : ;;
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

if [ -n "$VIDEO_APP" ] && [ -f "$VIDEO_APP" ] && [ ! -x "$VIDEO_APP" ]; then
    chmod +x "$VIDEO_APP" 2>/dev/null || true
    if [ ! -x "$VIDEO_APP" ]; then
        log_warn "App $VIDEO_APP is not executable and chmod failed; attempting to run anyway."
    fi
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
    elif [ -x "/usr/bin/iris_v4l2_test" ]; then
        final_app="/usr/bin/iris_v4l2_test"
    elif [ -x "/data/vendor/iris_test_app/iris_v4l2_test" ]; then
        final_app="/data/vendor/iris_test_app/iris_v4l2_test"
    fi
fi

if [ -z "$final_app" ]; then
    log_skip "$TESTNAME SKIP - iris_v4l2_test not available (VIDEO_APP=$VIDEO_APP). Provide --app or install the binary."
    printf '%s\n' "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

VIDEO_APP="$final_app"
export VIDEO_APP

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

# --- Split logs by flavor, share bundle cache at root ---
LOG_ROOT="./logs_${TESTNAME}"
LOG_DIR="$LOG_ROOT"

if [ -n "$LOG_FLAVOR" ]; then
    LOG_DIR="$LOG_ROOT/$LOG_FLAVOR"
fi

mkdir -p "$LOG_DIR"
export LOG_DIR
export LOG_ROOT

# --- Detect top-level vs sub-run (when --stack both re-execs itself) ---
TOP_LEVEL_RUN="1"
if [ -n "$LOG_FLAVOR" ]; then
    TOP_LEVEL_RUN="0"
fi

# --- Opt-in local media bundle extraction (honored regardless of --config/--dir) ---
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
    log_info "Sub-run: skipping rootfs size check (already performed)."
fi

# If we're going to fetch, ensure network is online first — only once
if [ "$TOP_LEVEL_RUN" -eq 1 ]; then
    if [ "$EXTRACT_INPUT_CLIPS" = "true" ] && [ -z "$CFG" ] && [ -z "$DIR" ] && [ -z "$CLIPS_TAR" ]; then
        net_rc=1
        if command -v check_network_status_rc >/dev/null 2>&1; then
            check_network_status_rc
            net_rc=$?
        elif command -v check_network_status >/dev/null 2>&1; then
            check_network_status >/dev/null 2>&1
            net_rc=$?
        fi

        if [ "$net_rc" -ne 0 ]; then
            video_step "" "Bring network online (Wi-Fi credentials if provided)"
            ensure_network_online || true
            sleep "${NET_STABILIZE_SLEEP:-5}"
        else
            sleep "${NET_STABILIZE_SLEEP:-5}"
        fi
    fi
else
    log_info "Sub-run: skipping initial network bring-up."
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

# --- Pakala/SM8750: upstream-only; skip downstream entirely ---
if [ "$early_plat" = "pakala" ] && [ "$early_stack" = "downstream" ]; then
    log_skip "On Pakala/SM8750, downstream/overlay is not supported in this flow; skipping overlay run."
    printf '%s\n' "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

# --- Optional early fetch of bundle (best-effort, ALWAYS in LOG_ROOT) — only once ---
if [ "$TOP_LEVEL_RUN" -eq 1 ]; then
    if [ "$EXTRACT_INPUT_CLIPS" = "true" ] && [ -z "$CFG" ] && [ -z "$DIR" ]; then
        if [ -n "$CLIPS_TAR" ]; then
            log_info "Custom --clips-tar provided; skipping online early fetch."
        else
            video_step "" "Early bundle fetch (best-effort)"
            saved_log_dir="$LOG_DIR"
            LOG_DIR="$LOG_ROOT"
            export LOG_DIR

            if command -v check_network_status_rc >/dev/null 2>&1; then
                if ! check_network_status_rc; then
                    log_info "Network unreachable; skipping early media bundle fetch."
                else
                    extract_tar_from_url "$TAR_URL" || true
                fi
            else
                extract_tar_from_url "$TAR_URL" || true
            fi

            LOG_DIR="$saved_log_dir"
            export LOG_DIR
        fi
    else
        log_info "Skipping early bundle fetch (explicit --config/--dir provided or EXTRACT_INPUT_CLIPS=false)."
    fi
else
    log_info "Sub-run: skipping early bundle fetch."
fi

# --- If user asked for both stacks, re-invoke ourselves for base and overlay ---
if [ "${VIDEO_STACK}" = "both" ]; then
    build_reexec_args() {
        args=""

        if [ -n "${CFG:-}" ]; then
            esc_cfg="$(printf %s "$CFG" | sed "s/'/'\\\\''/g")"
            args="$args --config '$esc_cfg'"
        fi
        if [ -n "${DIR:-}" ]; then
            esc_dir="$(printf %s "$DIR" | sed "s/'/'\\\\''/g")"
            args="$args --dir '$esc_dir'"
        fi
        if [ -n "${PATTERN:-}" ]; then
            esc_pat="$(printf %s "$PATTERN" | sed "s/'/'\\\\''/g")"
            args="$args --pattern '$esc_pat'"
        fi
        if [ -n "${TIMEOUT:-}" ]; then
            args="$args --timeout $(printf %s "$TIMEOUT")"
        fi
        if [ "${STRICT:-0}" -eq 1 ]; then
            args="$args --strict"
        fi
        if [ "${DMESG_SCAN:-1}" -eq 0 ]; then
            args="$args --no-dmesg"
        fi
        if [ -n "${MAX:-}" ] && [ "$MAX" -gt 0 ] 2>/dev/null; then
            args="$args --max $MAX"
        fi
        if [ "${STOP_ON_FAIL:-0}" -eq 1 ]; then
            args="$args --stop-on-fail"
        fi
        if [ -n "${LOGLEVEL:-}" ]; then
            args="$args --loglevel $(printf %s "$LOGLEVEL")"
        fi
        if [ -n "${REPEAT:-}" ]; then
            args="$args --repeat $(printf %s "$REPEAT")"
        fi
        if [ -n "${REPEAT_DELAY:-}" ]; then
            args="$args --repeat-delay $(printf %s "$REPEAT_DELAY")"
        fi
        if [ -n "${REPEAT_POLICY:-}" ]; then
            esc_pol="$(printf %s "$REPEAT_POLICY" | sed "s/'/'\\\\''/g")"
            args="$args --repeat-policy '$esc_pol'"
        fi
        if [ -n "${JUNIT_OUT:-}" ]; then
            esc_junit="$(printf %s "$JUNIT_OUT" | sed "s/'/'\\\\''/g")"
            args="$args --junit '$esc_junit'"
        fi
        if [ "${DRY:-0}" -eq 1 ]; then
            args="$args --dry-run"
        fi
        if [ -n "${EXTRACT_INPUT_CLIPS:-}" ] && [ "$EXTRACT_INPUT_CLIPS" != "true" ]; then
            args="$args --extract-input-clips $(printf %s "$EXTRACT_INPUT_CLIPS")"
        fi
        if [ "${VERBOSE:-0}" -eq 1 ]; then
            args="$args --verbose"
        fi
        if [ -n "${VIDEO_PLATFORM:-}" ]; then
            esc_plat="$(printf %s "$VIDEO_PLATFORM" | sed "s/'/'\\\\''/g")"
            args="$args --platform '$esc_plat'"
        fi
        if [ -n "${VIDEO_FW_DS:-}" ]; then
            esc_fw="$(printf %s "$VIDEO_FW_DS" | sed "s/'/'\\\\''/g")"
            args="$args --downstream-fw '$esc_fw'"
        fi
        if [ "${VIDEO_FORCE:-0}" -eq 1 ]; then
            args="$args --force"
        fi
        if [ -n "${VIDEO_APP:-}" ]; then
            esc_app="$(printf %s "$VIDEO_APP" | sed "s/'/'\\\\''/g")"
            args="$args --app '$esc_app'"
        fi
        if [ -n "${SSID:-}" ]; then
            esc_ssid="$(printf %s "$SSID" | sed "s/'/'\\\\''/g")"
            args="$args --ssid '$esc_ssid'"
        fi
        if [ -n "${PASSWORD:-}" ]; then
            esc_pwd="$(printf %s "$PASSWORD" | sed "s/'/'\\\\''/g")"
            args="$args --password '$esc_pwd'"
        fi
        if [ -n "${APP_LAUNCH_SLEEP:-}" ]; then
            args="$args --app-launch-sleep $(printf %s "$APP_LAUNCH_SLEEP")"
        fi
        if [ -n "${INTER_TEST_SLEEP:-}" ]; then
            args="$args --inter-test-sleep $(printf %s "$INTER_TEST_SLEEP")"
        fi
        if [ -n "${RETRY_ON_FAIL:-}" ]; then
            args="$args --retry-on-fail $(printf %s "$RETRY_ON_FAIL")"
        fi
        if [ -n "${POST_TEST_SLEEP:-}" ]; then
            args="$args --post-test-sleep $(printf %s "$POST_TEST_SLEEP")"
        fi
        if [ -n "${CLIPS_TAR:-}" ]; then
            esc_tar="$(printf %s "$CLIPS_TAR" | sed "s/'/'\\\\''/g")"
            args="$args --clips-tar '$esc_tar'"
        fi
        if [ -n "${CLIPS_DEST:-}" ]; then
            esc_dst="$(printf %s "$CLIPS_DEST" | sed "s/'/'\\\\''/g")"
            args="$args --clips-dest '$esc_dst'"
        fi

        printf "%s" "$args"
    }

    reexec_args="$(build_reexec_args)"

    log_info "[both] starting BASE (upstream) pass"
    # shellcheck disable=SC2086
    sh -c "'$0' --stack base --log-flavor upstream $reexec_args"
    rc_base=$?

    base_res_line=""
    if [ -f "$RES_FILE" ]; then
        base_res_line="$(cat "$RES_FILE" 2>/dev/null || true)"
    fi

    # Determine current platform for the both-flow overlay skip check
    both_plat="$VIDEO_PLATFORM"
    if [ -z "$both_plat" ]; then
        both_plat="$(video_detect_platform)"
    fi

    if [ "$both_plat" = "pakala" ]; then
        log_info "[both] pakala/sm8750-mtp: skipping OVERLAY (downstream) pass (upstream-only platform)"
        rc_overlay=0
        overlay_res_line="$TESTNAME SKIP"
    else
        log_info "[both] starting OVERLAY (downstream) pass"
        # shellcheck disable=SC2086
        sh -c "'$0' --stack overlay --log-flavor downstream $reexec_args"
        rc_overlay=$?

        overlay_res_line=""
        if [ -f "$RES_FILE" ]; then
            overlay_res_line="$(cat "$RES_FILE" 2>/dev/null || true)"
        fi
    fi

    base_status="$(printf '%s\n' "$base_res_line" | awk '{print $2}')"
    overlay_status="$(printf '%s\n' "$overlay_res_line" | awk '{print $2}')"

    overlay_reason=""
    if [ "$overlay_status" = "SKIP" ] && [ "$both_plat" = "kodiak" ] && [ -z "${VIDEO_FW_DS:-}" ]; then
        overlay_reason="missing --downstream-fw"
    fi
    if [ "$overlay_status" = "SKIP" ] && [ "$both_plat" = "pakala" ]; then
        overlay_reason="upstream-only platform"
    fi

    if [ "$rc_base" -eq 0 ] && [ "$rc_overlay" -eq 0 ]; then
        if [ "$base_status" = "PASS" ] && [ "$overlay_status" = "SKIP" ]; then
            if [ -n "$overlay_reason" ]; then
                log_info "[both] upstream/base PASS; downstream/overlay SKIP ($overlay_reason). Overall PASS."
            else
                log_info "[both] upstream/base PASS; downstream/overlay SKIP. Overall PASS."
            fi
        elif [ "$base_status" = "SKIP" ] && [ "$overlay_status" = "PASS" ]; then
            log_info "[both] downstream/overlay PASS; upstream/base SKIP. Overall PASS."
        else
            log_pass "[both] both passes succeeded"
        fi
        printf '%s\n' "$TESTNAME PASS" >"$RES_FILE"
        exit 0
    else
        log_fail "[both] one or more passes failed (base rc=$rc_base, overlay rc=$rc_overlay; base=$base_status overlay=$overlay_status)"
        printf '%s\n' "$TESTNAME FAIL" >"$RES_FILE"
        exit 1
    fi
fi

log_info "----------------------------------------------------------------------"
log_info "---------------------- Starting $TESTNAME (modular) -------------------"
log_info "STACK=$VIDEO_STACK PLATFORM=${VIDEO_PLATFORM:-auto} STRICT=$STRICT DMESG_SCAN=$DMESG_SCAN"
log_info "TIMEOUT=${TIMEOUT}s LOGLEVEL=$LOGLEVEL REPEAT=$REPEAT REPEAT_POLICY=$REPEAT_POLICY"
log_info "APP=$VIDEO_APP"
if [ -n "$VIDEO_FW_DS" ]; then
    log_info "Downstream FW override: $VIDEO_FW_DS"
fi
if [ -n "$KO_TREE$KO_DIRS$KO_TARBALL" ]; then
    if [ -n "$KO_TREE" ]; then
        log_info "Custom module tree (modprobe -d): $KO_TREE"
    fi
    if [ -n "$KO_DIRS" ]; then
        log_info "Custom ko dir(s): $KO_DIRS (prefer_custom=$KO_PREFER_CUSTOM)"
    fi
fi
if [ -n "$VIDEO_FW_BACKUP_DIR" ]; then
    log_info "FW backup override: $VIDEO_FW_BACKUP_DIR"
fi
if [ "$VERBOSE" -eq 1 ]; then
    log_info "CWD=$(pwd) | SCRIPT_DIR=$SCRIPT_DIR | test_path=$test_path"
fi
log_info "SLEEPS: app-launch=${APP_LAUNCH_SLEEP}s, inter-test=${INTER_TEST_SLEEP}s"

# Warn if not root (module/blacklist ops may fail)
video_warn_if_not_root

# --- Ensure desired video stack (hot switch best-effort) ---
plat="$VIDEO_PLATFORM"
if [ -z "$plat" ]; then
    plat=$(video_detect_platform)
fi
log_info "Detected platform: $plat"

VIDEO_STACK="$(video_normalize_stack "$VIDEO_STACK")"
pre_stack="$(video_stack_status "$plat")"
log_info "Current video stack (pre): $pre_stack"

# Kodiak + upstream → install backup firmware to /lib/firmware before switching
if [ "$plat" = "kodiak" ]; then
    case "$VIDEO_STACK" in
        upstream|up|base)
            video_step "" "Kodiak upstream firmware install"
            video_kodiak_install_firmware || true
            ;;
    esac
fi

# ---- Enforce --downstream-fw on Kodiak when requesting downstream/overlay (SKIP if unmet) ----
if [ "$plat" = "kodiak" ]; then
    case "$VIDEO_STACK" in
        downstream|overlay|down)
            if [ -z "$VIDEO_FW_DS" ] || [ ! -f "$VIDEO_FW_DS" ]; then
                log_skip "On Kodiak, downstream/overlay requires --downstream-fw <file>; skipping run."
                printf '%s\n' "$TESTNAME SKIP" >"$RES_FILE"
                exit 0
            fi
            ;;
    esac
fi

# ---- Pakala/SM8750: downstream is not supported — skip gracefully ----
if [ "$plat" = "pakala" ]; then
    case "$VIDEO_STACK" in
        downstream|overlay|down)
            log_skip "On Pakala/SM8750, downstream/overlay is not supported in this flow; skipping run."
            printf '%s\n' "$TESTNAME SKIP" >"$RES_FILE"
            exit 0
            ;;
    esac
fi

video_dump_stack_state "pre"

# --- Custom .ko staging (only if user provided --ko-dir) ---
if [ -n "${KO_DIRS:-}" ]; then
    case "$(video_normalize_stack "$VIDEO_STACK")" in
        downstream|overlay|down)
            KVER="$(uname -r 2>/dev/null || printf '%s' unknown)"
            if command -v video_find_module_file >/dev/null 2>&1; then
                modpath="$(video_find_module_file iris_vpu "$KO_DIRS" 2>/dev/null | tail -n1 | tr -d '\r')"
            else
                modpath=""
            fi

            if [ -n "$modpath" ] && [ -f "$modpath" ]; then
                log_info "Using custom iris_vpu candidate: $modpath"
                if command -v video_ensure_moddir_install >/dev/null 2>&1; then
                    video_ensure_moddir_install "$modpath" "$KVER" >/dev/null 2>&1 || true
                fi
                if command -v depmod >/dev/null 2>&1; then
                    depmod -a "$KVER" >/dev/null 2>&1 || true
                fi
            else
                log_warn "KO_DIRS set, but iris_vpu.ko not found under: $KO_DIRS"
            fi
            ;;
    esac
fi

video_step "" "Apply desired stack = $VIDEO_STACK"

stack_tmp="$LOG_DIR/.ensure_stack.$$.out"
: > "$stack_tmp"

video_ensure_stack "$VIDEO_STACK" "$plat" >"$stack_tmp" 2>&1 || true

if [ -s "$stack_tmp" ]; then
    total_lines="$(wc -l < "$stack_tmp" 2>/dev/null | tr -d ' ')"
    if [ -n "$total_lines" ] && [ "$total_lines" -gt 1 ] 2>/dev/null; then
        head -n $((total_lines - 1)) "$stack_tmp"
    fi
    post_stack="$(tail -n 1 "$stack_tmp" | tr -d '\r')"
else
    post_stack=""
fi

rm -f "$stack_tmp" 2>/dev/null || true

if [ -z "$post_stack" ] || [ "$post_stack" = "unknown" ]; then
    log_warn "Could not fully switch to requested stack=$VIDEO_STACK (platform=$plat). Blacklist updated; reboot may be required."
    post_stack="$(video_stack_status "$plat")"
fi

log_info "Video stack (post): $post_stack"

video_dump_stack_state "post"

# --- Custom .ko load assist (only if user provided --ko-dir) ---
if [ -n "${KO_DIRS:-}" ]; then
    case "$(video_normalize_stack "$VIDEO_STACK")" in
        downstream|overlay|down)
            if ! video_has_module_loaded iris_vpu 2>/dev/null; then
                if command -v video_find_module_file >/dev/null 2>&1; then
                    modpath2="$(video_find_module_file iris_vpu "$KO_DIRS" 2>/dev/null | tail -n1 | tr -d '\r')"
                else
                    modpath2=""
                fi

                if [ "$KO_PREFER_CUSTOM" = "1" ] && [ -n "$modpath2" ] && [ -f "$modpath2" ]; then
                    if command -v video_insmod_with_deps >/dev/null 2>&1; then
                        log_info "Prefer custom: insmod with deps: $modpath2"
                        video_insmod_with_deps "$modpath2" >/dev/null 2>&1 || true
                    fi
                fi
            fi
            ;;
    esac
fi

# Always refresh/prune device nodes (even if no switch occurred)
video_step "" "Refresh V4L device nodes (udev trigger + prune stale)"
video_clean_and_refresh_v4l || true

# --- Hard gate: if requested stack not in effect, abort immediately (platform-aware) ---
case "$VIDEO_STACK" in
    upstream|up|base)
        if ! video_validate_upstream_loaded "$plat"; then
            case "$plat" in
                lemans|monaco)
                    msg="qcom_iris not present"
                    ;;
                kodiak)
                    msg="venus_core/dec/enc not all present"
                    ;;
                pakala)
                    msg="qcom_iris not present for platform pakala/sm8750"
                    ;;
                *)
                    msg="required upstream modules not present for platform $plat"
                    ;;
            esac
            log_fail "[STACK] Upstream requested but $msg; aborting."
            printf '%s\n' "$TESTNAME FAIL" >"$RES_FILE"
            exit 1
        fi
        ;;
    downstream|overlay|down)
        if ! video_validate_downstream_loaded "$plat"; then
            case "$plat" in
                lemans|monaco)
                    msg="iris_vpu missing or qcom_iris still loaded"
                    ;;
                kodiak)
                    msg="iris_vpu missing or venus_core still loaded"
                    ;;
                pakala)
                    msg="downstream not supported on pakala/sm8750"
                    ;;
                *)
                    msg="required downstream modules not present for platform $plat"
                    ;;
            esac
            log_fail "[STACK] Downstream requested but $msg; aborting."
            printf '%s\n' "$TESTNAME FAIL" >"$RES_FILE"
            exit 1
        fi
        ;;
esac

# Per-platform module validation (informational)
case "$plat" in
    lemans|monaco)
        if [ "$post_stack" = "upstream" ]; then
            if video_has_module_loaded qcom_iris && video_has_module_loaded iris_vpu; then
                log_pass "Upstream validated: qcom_iris + iris_vpu present"
            elif video_has_module_loaded qcom_iris && ! video_has_module_loaded iris_vpu; then
                log_pass "Upstream validated: qcom_iris present (pure upstream build)"
            else
                log_warn "Upstream expected but qcom_iris not present"
            fi
        elif [ "$post_stack" = "downstream" ]; then
            if video_has_module_loaded iris_vpu && ! video_has_module_loaded qcom_iris; then
                log_pass "Downstream validated: iris_vpu present, qcom_iris unloaded"
            else
                log_warn "Downstream expected but iris_vpu not present or qcom_iris still loaded"
            fi
        fi
        ;;
    kodiak)
        if [ "$post_stack" = "upstream" ]; then
            if video_has_module_loaded venus_core; then
                log_pass "Upstream validated: venus_core present"
            else
                log_warn "Upstream expected but venus_core not present"
            fi
        elif [ "$post_stack" = "downstream" ]; then
            if video_has_module_loaded iris_vpu && ! video_has_module_loaded venus_core; then
                log_pass "Downstream validated: iris_vpu present, venus_core unloaded"
            else
                log_warn "Downstream expected but iris_vpu not present or venus_core still loaded"
            fi
        fi
        ;;
    pakala)
        # Pakala uses qcom_iris for upstream (same as lemans/monaco).
        # Downstream is not supported in this flow.
        if [ "$post_stack" = "upstream" ]; then
            if video_has_module_loaded qcom_iris; then
                log_pass "Upstream validated (pakala/sm8750): qcom_iris present"
            else
                log_warn "Upstream expected (pakala/sm8750) but qcom_iris not present"
            fi
        fi
        ;;
    *)
        log_warn "Unknown platform '$plat': skipping per-platform module validation"
        ;;
esac

# -----------------------------------------------------------------------
# Locate test configs / clips
# -----------------------------------------------------------------------
# Resolve configuration: explicit --config > explicit --dir > auto-discovery
if [ -n "$CFG" ]; then
    if [ -f "$CFG" ]; then
        cfg_dir="$(cd "$(dirname "$CFG")" && pwd)"
        cfg_files="$CFG"
        log_info "Config: $CFG"
    elif [ -d "$CFG" ]; then
        cfg_dir="$(cd "$CFG" && pwd)"
        cfg_files="$(find "$cfg_dir" -maxdepth 2 -name '*.json' | sort)"
        log_info "Config dir: $cfg_dir ($(printf '%s\n' "$cfg_files" | wc -l) JSON files)"
    else
        log_error "Specified --config path not found: $CFG"
        printf '%s\n' "$TESTNAME FAIL" >"$RES_FILE"
        exit 1
    fi
elif [ -n "$DIR" ]; then
    cfg_dir="$(cd "$DIR" && pwd)"
    cfg_files="$(find "$cfg_dir" -maxdepth 2 -name '*.json' | sort)"
    log_info "Config dir (--dir): $cfg_dir ($(printf '%s\n' "$cfg_files" | wc -l) JSON files)"
else
    # Auto-discover: look under platform-specific sub-dirs first, then generic
    cfg_dir=""
    for candidate in \
        "$test_path/cfg/$plat" \
        "$test_path/cfg/common" \
        "$test_path/cfg" \
        "$test_path"; do
        if [ -d "$candidate" ] && find "$candidate" -maxdepth 2 -name '*.json' -print -quit 2>/dev/null | grep -q .; then
            cfg_dir="$candidate"
            break
        fi
    done

    if [ -z "$cfg_dir" ]; then
        log_skip "$TESTNAME SKIP - no JSON configs found under $test_path"
        printf '%s\n' "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
    fi

    cfg_files="$(find "$cfg_dir" -maxdepth 2 -name '*.json' | sort)"
    log_info "Auto-discovered config dir: $cfg_dir ($(printf '%s\n' "$cfg_files" | wc -l) JSON files)"
fi

# Apply --pattern filter
if [ -n "$PATTERN" ]; then
    cfg_files="$(printf '%s\n' "$cfg_files" | grep -E "$PATTERN" || true)"
    log_info "After pattern filter '$PATTERN': $(printf '%s\n' "$cfg_files" | grep -c .) configs"
fi

# Apply --max cap
if [ -n "$MAX" ] && [ "$MAX" -gt 0 ] 2>/dev/null; then
    cfg_files="$(printf '%s\n' "$cfg_files" | head -n "$MAX")"
    log_info "Capped at MAX=$MAX configs"
fi

if [ -z "$cfg_files" ]; then
    log_skip "$TESTNAME SKIP - no configs remaining after filters"
    printf '%s\n' "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

# -----------------------------------------------------------------------
# Test execution loop
# -----------------------------------------------------------------------
overall_pass=0
overall_fail=0
overall_skip=0

run_single_config() {
    _cfg="$1"
    _run_idx="$2"

    _cfg_name="$(basename "$_cfg" .json)"
    _cfg_root="$(cd "$(dirname "$_cfg")" && pwd)"

    log_info "--- Test: $_cfg_name [run $_run_idx] ---"

    if [ "$DRY" -eq 1 ]; then
        log_info "[dry-run] Would run: $_cfg_name"
        return 0
    fi

    # Resolve clip path expected by this config (best-effort; config may override)
    clip_dir="$_cfg_root"

    # Launch test
    rc=0
    app_out="$LOG_DIR/${_cfg_name}_run${_run_idx}.log"

    # Build app invocation
    app_cmd="$VIDEO_APP --config '$_cfg' --loglevel $LOGLEVEL"

    timeout_bin=""
    if command -v timeout >/dev/null 2>&1; then
        timeout_bin="timeout ${TIMEOUT}s"
    fi

    log_info "Launch: $app_cmd"
    sleep "${APP_LAUNCH_SLEEP}"

    if [ -n "$timeout_bin" ]; then
        # shellcheck disable=SC2086
        eval "$timeout_bin $app_cmd" >"$app_out" 2>&1 || rc=$?
    else
        # shellcheck disable=SC2086
        eval "$app_cmd" >"$app_out" 2>&1 || rc=$?
    fi

    # Parse result from output
    if grep -qE "$SUCCESS_RE" "$app_out" 2>/dev/null; then
        result="PASS"
    elif [ "$rc" -eq 0 ]; then
        result="PASS"
    else
        result="FAIL"
    fi

    # Retry logic
    retry_attempt=0
    while [ "$result" = "FAIL" ] && [ "$retry_attempt" -lt "$RETRY_ON_FAIL" ]; do
        retry_attempt=$((retry_attempt + 1))
        log_warn "Retry $retry_attempt/$RETRY_ON_FAIL for $_cfg_name"
        sleep "${APP_LAUNCH_SLEEP}"
        app_out_retry="$LOG_DIR/${_cfg_name}_run${_run_idx}_retry${retry_attempt}.log"
        rc=0
        if [ -n "$timeout_bin" ]; then
            # shellcheck disable=SC2086
            eval "$timeout_bin $app_cmd" >"$app_out_retry" 2>&1 || rc=$?
        else
            # shellcheck disable=SC2086
            eval "$app_cmd" >"$app_out_retry" 2>&1 || rc=$?
        fi
        if grep -qE "$SUCCESS_RE" "$app_out_retry" 2>/dev/null; then
            result="PASS"
        elif [ "$rc" -eq 0 ]; then
            result="PASS"
        fi
    done

    # DMESG scan
    if [ "$DMESG_SCAN" -eq 1 ]; then
        dmesg_out="$LOG_DIR/${_cfg_name}_run${_run_idx}_dmesg.log"
        dmesg 2>/dev/null | tail -n 50 >"$dmesg_out" || true
        if grep -qiE "kernel BUG|oops|panic|use-after-free|NULL pointer" "$dmesg_out" 2>/dev/null; then
            log_warn "dmesg contains kernel errors for $_cfg_name"
        fi
    fi

    case "$result" in
        PASS)
            log_pass "$_cfg_name [run $_run_idx]: PASS"
            overall_pass=$((overall_pass + 1))
            ;;
        FAIL)
            log_fail "$_cfg_name [run $_run_idx]: FAIL (rc=$rc)"
            overall_fail=$((overall_fail + 1))
            if [ "$STOP_ON_FAIL" -eq 1 ]; then
                log_warn "STOP_ON_FAIL set; aborting test loop."
                printf '%s\n' "$TESTNAME FAIL" >"$RES_FILE"
                exit 1
            fi
            ;;
    esac

    if [ -n "$POST_TEST_SLEEP" ] && [ "$POST_TEST_SLEEP" -gt 0 ] 2>/dev/null; then
        sleep "$POST_TEST_SLEEP"
    else
        sleep "${INTER_TEST_SLEEP}"
    fi

    return 0
}

# Main loop over configs x repeats
for cfg_entry in $cfg_files; do
    [ -f "$cfg_entry" ] || continue

    r=1
    while [ "$r" -le "$REPEAT" ]; do
        run_single_config "$cfg_entry" "$r"

        # REPEAT_POLICY=any: stop repeating this config as soon as one pass
        if [ "$REPEAT_POLICY" = "any" ] && [ "$overall_pass" -gt 0 ]; then
            break
        fi

        r=$((r + 1))
        if [ "$r" -le "$REPEAT" ] && [ -n "$REPEAT_DELAY" ] && [ "$REPEAT_DELAY" -gt 0 ] 2>/dev/null; then
            sleep "$REPEAT_DELAY"
        fi
    done
done

# -----------------------------------------------------------------------
# Summary + result
# -----------------------------------------------------------------------
log_info "======================================================================"
log_info "SUMMARY  PASS=$overall_pass  FAIL=$overall_fail  SKIP=$overall_skip"
log_info "======================================================================"

if [ "$overall_fail" -gt 0 ]; then
    if [ "$STRICT" -eq 1 ]; then
        log_fail "$TESTNAME FAIL ($overall_fail failures)"
        printf '%s\n' "$TESTNAME FAIL" >"$RES_FILE"
        exit 1
    else
        log_fail "$TESTNAME FAIL ($overall_fail failures; STRICT=0)"
        printf '%s\n' "$TESTNAME FAIL" >"$RES_FILE"
        exit 1
    fi
elif [ "$overall_pass" -eq 0 ] && [ "$overall_skip" -gt 0 ]; then
    log_skip "$TESTNAME SKIP (all cases skipped)"
    printf '%s\n' "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
elif [ "$overall_pass" -eq 0 ]; then
    log_skip "$TESTNAME SKIP (no cases ran)"
    printf '%s\n' "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
else
    log_pass "$TESTNAME PASS ($overall_pass passed)"
    printf '%s\n' "$TESTNAME PASS" >"$RES_FILE"
    exit 0
fi
