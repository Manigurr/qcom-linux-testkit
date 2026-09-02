#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

# Wrapper for Video_V4L2_Runner/run.sh.
#
# Purpose:
#   - Keep existing run.sh untouched.
#   - Use local IRIS clips/app from /data/vendor/iris_test_app.
#   - Auto-detect platform from TARGET, LAVA device-type env, or hostname.
#   - Run base/upstream for all platforms.
#   - Run overlay/downstream only for kodiak/lemans/monaco.
#   - Skip overlay/downstream for pakala/sm8750-mtp because this flow is upstream-only there.

set -u

SCRIPT_DIR="$(
  cd "$(dirname "$0")" || exit 1
  pwd
)"

# Find repo root.
# In LAVA this should normally be exported by the YAML as REPO_ROOT=$PWD from Runner.
if [ -n "${REPO_ROOT:-}" ] && [ -d "$REPO_ROOT" ]; then
  :
else
  SEARCH="$SCRIPT_DIR"
  REPO_ROOT=""
  while [ "$SEARCH" != "/" ]; do
    if [ -d "$SEARCH/suites" ] && [ -d "$SEARCH/utils" ]; then
      REPO_ROOT="$SEARCH"
      break
    fi
    SEARCH="$(dirname "$SEARCH")"
  done

  if [ -z "$REPO_ROOT" ]; then
    echo "[ERROR] Could not determine REPO_ROOT. Please export REPO_ROOT before running." >&2
    exit 1
  fi

  export REPO_ROOT
fi

RPATH="$REPO_ROOT/suites/Multimedia/Video/Video_V4L2_Runner/run.sh"
RESFILE="$REPO_ROOT/suites/Multimedia/Video/Video_V4L2_Runner/Video_V4L2_Runner.res"
SEND_TO_LAVA="$REPO_ROOT/utils/send-to-lava.sh"
RESULT_PARSE="$REPO_ROOT/utils/result_parse.sh"

# Local media bundle path.
CLIPS_TAR="${CLIPS_TAR:-/data/vendor/iris_test_app/video_clips_iris.tar.gz}"

# Local IRIS V4L2 test app path.
IRIS_APP="${IRIS_APP:-/data/vendor/iris_test_app/iris_v4l2_test}"

# Optional downstream module location.
KO_DIR="${KO_DIR:-/data/vendor/iris_test_app}"

# Optional downstream firmware needed on Kodiak overlay.
DS_FW="${DS_FW:-/data/vendor/iris_test_app/vpu20_1v.mbn}"

# Generic knobs.
RETRY_ON_FAIL="${RETRY_ON_FAIL:-2}"
LOGLEVEL="${LOGLEVEL:-15}"

# Validate required files/scripts.
if [ ! -f "$RPATH" ]; then
  echo "[ERROR] Runner script not found: $RPATH" >&2
  exit 1
fi

if [ ! -f "$CLIPS_TAR" ]; then
  echo "[WARN] Local clips tar not found: $CLIPS_TAR" >&2
  echo "[WARN] Existing run.sh may still continue depending on its own handling." >&2
fi

if [ ! -f "$IRIS_APP" ]; then
  echo "[WARN] IRIS app not found: $IRIS_APP" >&2
  echo "[WARN] Existing run.sh may search fallback locations depending on its own handling." >&2
fi

if [ -f "$IRIS_APP" ] && [ ! -x "$IRIS_APP" ]; then
  chmod +x "$IRIS_APP" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------

TARGET_RAW="${TARGET:-}"
TARGET_LC="$(printf '%s' "$TARGET_RAW" | tr '[:upper:]' '[:lower:]')"

DEVTYPE_RAW="${DEVICE_TYPE:-${LAVA_DEVICE_TYPE:-${LAVA_DEVICE_TYPE_NAME:-${DEVICE_TYPE_NAME:-}}}}"

if [ -z "$DEVTYPE_RAW" ]; then
  DEVTYPE_RAW="$(hostname 2>/dev/null || true)"
fi

DEVTYPE="$(printf '%s' "$DEVTYPE_RAW" | tr '[:upper:]' '[:lower:]')"

TL=""

if [ -n "$TARGET_LC" ]; then
  case "$TARGET_LC" in
    kodiak|lemans|monaco|pakala)
      TL="$TARGET_LC"
      ;;
    rb3gen2|qcs6490-rb3gen2|qcs6490-rb3gen2-core-kit)
      TL="kodiak"
      ;;
    qcs9100*|sa8775p*|qcs9075*|iq-9075*)
      TL="lemans"
      ;;
    qcs8300*|iq-8275*)
      TL="monaco"
      ;;
    sm8750*|pakala*)
      TL="pakala"
      ;;
    *)
      TL=""
      ;;
  esac
else
  case "$DEVTYPE" in
    # Monaco
    qcs8300-ride|qcs8300-ride-sx|iq-8275-evk|qcs8300*)
      TL="monaco"
      ;;

    # Lemans
    qcs9100-ride-r3|sa8775p-ride|iq-9075-evk|qcs9075-rb8|qcs9100-ride-sx|qcs9100*|sa8775p*|qcs9075*)
      TL="lemans"
      ;;

    # Kodiak
    qcs6490-rb3gen2|rb3gen2|qcs6490-rb3gen2-core-kit|qcs6490*)
      TL="kodiak"
      ;;

    # Pakala / SM8750
    sm8750-mtp|sm8750*|pakala*)
      TL="pakala"
      ;;

    *)
      TL=""
      ;;
  esac
fi

PLAT=""
case "$TL" in
  kodiak|lemans|monaco)
    PLAT="--platform $TL"
    ;;
  pakala)
    # Existing run.sh usage lists only lemans/monaco/kodiak.
    # However, if lib_video.sh in your branch already supports pakala,
    # set PASS_PAKALA_PLATFORM=1 to pass --platform pakala.
    #
    # Default is not to pass --platform pakala, and instead use --force for base
    # so we do not fail only because the older platform detector reports unknown.
    if [ "${PASS_PAKALA_PLATFORM:-0}" = "1" ]; then
      PLAT="--platform pakala"
    else
      PLAT=""
    fi
    ;;
  *)
    PLAT=""
    ;;
esac

echo "DEBUG: TARGET='${TARGET:-}' DEVTYPE_RAW='${DEVTYPE_RAW:-}' DEVTYPE='$DEVTYPE' -> TL='$TL' PLAT='$PLAT'"

# ---------------------------------------------------------------------------
# Build args
# ---------------------------------------------------------------------------

ARGS_COMMON="--clips-tar $CLIPS_TAR --app $IRIS_APP $PLAT --retry-on-fail $RETRY_ON_FAIL --loglevel $LOGLEVEL"

# Base/upstream.
ARGS_BASE="--stack base $ARGS_COMMON"

# If pakala/sm8750 is detected, force base to avoid failing just because
# old platform detection reports unknown. Overlay is skipped entirely.
if [ "$TL" = "pakala" ]; then
  ARGS_BASE="$ARGS_BASE --force"
fi

# Overlay/downstream.
ARGS_OVERLAY="--stack overlay $ARGS_COMMON --ko-dir $KO_DIR --ko-prefer-custom"

if [ "$TL" = "kodiak" ]; then
  ARGS_OVERLAY="$ARGS_OVERLAY --downstream-fw $DS_FW"
fi

echo "BASE ARGS: $ARGS_BASE"

if [ "$TL" = "pakala" ]; then
  echo "OVERLAY ARGS: skipped because pakala/sm8750-mtp is upstream-only in this wrapper flow"
else
  echo "OVERLAY ARGS: $ARGS_OVERLAY"
fi

# ---------------------------------------------------------------------------
# Run base/upstream
# ---------------------------------------------------------------------------

# shellcheck disable=SC2086
sh -lc "$RPATH $ARGS_BASE" || true

if [ -x "$SEND_TO_LAVA" ]; then
  "$SEND_TO_LAVA" "$RESFILE" || true
else
  echo "[WARN] send-to-lava.sh not executable or not found: $SEND_TO_LAVA"
fi

# ---------------------------------------------------------------------------
# Run overlay/downstream only on supported downstream platforms
# ---------------------------------------------------------------------------

case "$TL" in
  kodiak|lemans|monaco)
    # shellcheck disable=SC2086
    sh -lc "$RPATH $ARGS_OVERLAY" || true

    if [ -x "$SEND_TO_LAVA" ]; then
      "$SEND_TO_LAVA" "$RESFILE" || true
    else
      echo "[WARN] send-to-lava.sh not executable or not found: $SEND_TO_LAVA"
    fi
    ;;
  pakala)
    echo "[INFO] Skipping overlay/downstream run for pakala/sm8750-mtp."
    ;;
  *)
    echo "[WARN] Platform could not be mapped to kodiak/lemans/monaco/pakala."
    echo "[WARN] Base run was attempted with autodetect. Skipping overlay to avoid false downstream failure."
    ;;
esac

# Optional roll-up.
if [ -x "$RESULT_PARSE" ]; then
  "$RESULT_PARSE" || true
else
  echo "[WARN] result_parse.sh not executable or not found: $RESULT_PARSE"
fi

exit 0
