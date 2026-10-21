#!/bin/sh
#
# Single entry point for the whole video test suite.
#
#   ./run.sh                          run everything
#   ./run.sh v4l2-compliance | iris_v4l2_test | fluster    run only the named suite(s)
#   ./run.sh iris_v4l2_test decoder             decoder/ configs only
#   ./run.sh iris_v4l2_test encoder             encoder/ configs only
#   ./run.sh iris_v4l2_test both                decoder+encoder/ (concurrent) configs only
#   ./run.sh iris_v4l2_test decoder encoder     union of the named folders
#   ./run.sh --list                   show platform + which iris configs would RUN/SKIP, run nothing
#
# decoder/encoder/both without a suite name imply "iris_v4l2_test".
# Timeouts: iris_v4l2_test 10s per config (timeout = FAIL), fluster 100s per test vector,
#           v4l2-compliance 60s per video node (timeout = FAIL).
# Platform capabilities (codecs, formats, resolution, sessions, features): platforms.json
# Add future tests as a new run_<name>() (dashes -> underscores) + an entry in SUITES below.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT" || exit 1

IRIS_TIMEOUT=30
FLUSTER_TIMEOUT=180
V4L2_TIMEOUT=60

SUITES="v4l2-compliance iris_v4l2_test fluster"          # default order when nothing is selected
SEL_SUITES=""
SEL_IRIS=""
LIST_ONLY=0

usage() { sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        v4l2-compliance|iris_v4l2_test|fluster)  SEL_SUITES="$SEL_SUITES $1" ;;
        decoder)            SEL_IRIS="$SEL_IRIS decoder" ;;
        encoder)            SEL_IRIS="$SEL_IRIS encoder" ;;
        both|decoder+encoder) SEL_IRIS="$SEL_IRIS decoder+encoder" ;;
        --list|--detect-only) LIST_ONLY=1 ;;
        -h|--help)          usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
    shift
done
[ -n "$SEL_IRIS" ] && SEL_SUITES="$SEL_SUITES iris_v4l2_test"
[ -z "$SEL_SUITES" ] && SEL_SUITES="$SUITES"
[ -z "$SEL_IRIS" ] && SEL_IRIS="decoder encoder decoder+encoder"

want() { case " $SEL_SUITES " in *" $1 "*) return 0 ;; esac; return 1; }

##############################################################################
# 1. Environment (GStreamer wrappers, python, ...) + v4l2 tools
##############################################################################

. "$ROOT/setup_tools.sh" || { echo "setup_tools.sh failed"; exit 1; }
cd "$ROOT" || exit 1

##############################################################################
# 2. Platform detection + capability filter (python helper, written to /tmp)
##############################################################################

TMPD=$(mktemp -d /tmp/video-test-suite.XXXXXX) || exit 1
trap 'rm -rf "$TMPD"' EXIT
CAPS_PY="$TMPD/caps.py"

# Failed-test bookkeeping: logs of every failure are collected under failed_logs/<suite>/
FAILDIR="$ROOT/failed_logs"
FAILED_LIST="$TMPD/failed.txt"; : > "$FAILED_LIST"
# fail_begin <suite>: start with a clean folder for this suite
fail_begin() { rm -rf "$FAILDIR/$1"; }
# record_fail <suite> <name> <reason> [logfile]
record_fail() {
    mkdir -p "$FAILDIR/$1"
    [ -n "$4" ] && [ -f "$4" ] && cp "$4" "$FAILDIR/$1/$2.log"
    printf '%s | %s | %s\n' "$1" "$2" "$3" >> "$FAILED_LIST"
}

cat > "$CAPS_PY" <<'PYEOF'
import json, re, sys, os

# usage: caps.py <platforms.json> <machine> info
#        caps.py <platforms.json> <machine> filter <config.json>...
path, machine, cmd = sys.argv[1:4]
db = {k.lower(): v for k, v in json.load(open(path)).items()}   # platform keys are case-insensitive
m = machine.strip().lower()
plat = "default"
for k in sorted((k for k in db if k != "default" and not k.startswith("_")), key=len, reverse=True):
    if k == m or k in m:
        plat = k
        break
caps = dict(db["default"])
own = db.get(plat, {})
for p in ("dec", "enc"):        # a platform's own session table replaces the default's
    if any(re.match(r"%s_max_\d+_\d+_sessions$" % p, k) for k in own):
        caps = {k: v for k, v in caps.items() if not re.match(r"%s_max_\d+_\d+_sessions$" % p, k)}
caps.update(own)
low = lambda v: [x.lower() for x in v]
CODECS = {"decoder": low(caps["decoder"]), "encoder": low(caps["encoder"])}
# 10-bit support is a subset; if "<domain>_10bit" is absent, 10-bit follows the 8-bit list
CODECS10 = {"decoder": low(caps.get("decoder_10bit", caps["decoder"])),
            "encoder": low(caps.get("encoder_10bit", caps["encoder"]))}
TEN_BIT_FORMATS = ("qc10c", "p010")
FORMATS = low(caps["pixel_formats"])
FEATS = low(caps["encoder_supported_features"])
PFX = {"decoder": "dec", "encoder": "enc"}

if cmd == "info":
    print("PLATFORM=%s" % plat)
    print("MATCHED=%d" % (plat != "default"))
    print("DECODER_CODECS='%s'" % " ".join(CODECS["decoder"]))
    print("ENCODER_CODECS='%s'" % " ".join(CODECS["encoder"]))
    print("DECODER_CODECS_10BIT='%s'" % " ".join(CODECS10["decoder"]))
    print("ENCODER_CODECS_10BIT='%s'" % " ".join(CODECS10["encoder"]))
    print("PIXEL_FORMATS='%s'" % " ".join(FORMATS))
    print("FLUSTER_JOBS=%s" % caps.get("fluster_jobs", 8))
    for c, n in caps.get("fluster_min_pass", {}).items():
        print("FLUSTER_MIN_%s=%d" % (c.upper(), n))
    print("ENC_FEATURES='%s'" % " ".join(FEATS))
    for d in ("decoder", "encoder"):
        p = PFX[d]
        sess = sorted((int(a), int(b), n) for a, b, n in
                      (re.match(r"%s_max_(\d+)_(\d+)_sessions$" % p, k).groups() + (v,)
                       for k, v in caps.items() if re.match(r"%s_max_\d+_\d+_sessions$" % p, k)))
        print("INFO_%s='max %sx%s, sessions: %s'" % (d.upper(), caps[p + "_max_width"], caps[p + "_max_height"],
              ", ".join("%dx%d=%d" % s for s in sess) or "unlimited"))
    sys.exit(0)

def session_limit(domain, w, h):
    """Limit of the smallest listed size that still fits WxH (None = unlisted)."""
    p = PFX[domain]
    best = None
    for k, v in caps.items():
        r = re.match(r"%s_max_(\d+)_(\d+)_sessions$" % p, k)
        if r:
            cw, ch = int(r.group(1)), int(r.group(2))
            if cw >= w and ch >= h and (best is None or cw * ch < best[0]):
                best = (cw * ch, v)
    return best[1] if best else None

# feature keyword in the test-case NAME -> required feature
NAME_FEATS = [
    ("multislice_maxbytes", "multislice_maxbytes"), ("multislice_maxmb", "multislice_maxmb"),
    ("intrarefresh_cyclic", "intrarefresh_cyclic"), ("intrarefresh_random", "intrarefresh_random"),
    ("dynamic_bitrate", "dynamic_bitrate"), ("downscale", "downscale"),
    ("rotate(?:90|180|270)?", "rotate"), ("hflip", "hflip"), ("vflip", "vflip"),
    ("hierb", "hierb"), ("hierp", "hierp"), ("ltr", "ltr"),
]
# control Ids inside the JSON -> required feature (catches mislabelled file names)
CTRL_FEATS = {"Rotate": "rotate", "HFlip": "hflip", "VFlip": "vflip", "LTRCount": "ltr",
              "MaxBytesPerSlice": "multislice_maxbytes", "MaxMacroBlocksPerSlice": "multislice_maxmb"}

def feat_ok(f):
    base = f.split("_")[0]
    return f in FEATS or base in FEATS      # 'multislice' covers multislice_*, etc.

def check(cfg):
    name = os.path.basename(cfg)[:-5]
    txt = open(cfg).read()
    # split into test cases at each "Domain"
    marks = [(mm.start(), mm.group(1).lower()) for mm in re.finditer(r'"Domain"\s*:\s*"(\w+)"', txt)]
    if not marks:
        return "no Decoder/Encoder test cases found"
    concurrent = re.search(r'"ExecutionMode"\s*:\s*"Concurrent"', txt) is not None
    groups = {}
    feats = set()
    for k, v in NAME_FEATS:
        if re.search(r"(?<![a-z0-9])%s(?![a-z0-9])" % k, name):
            feats.add(v)
    for i, (pos, dom) in enumerate(marks):
        blk = txt[pos:marks[i + 1][0] if i + 1 < len(marks) else len(txt)]
        if dom not in CODECS:
            continue
        g = lambda key: (re.search(r'"%s"\s*:\s*"?(\w+)' % key, blk) or [None, None])[1]
        codec, fmt, w, h = (g("CodecName") or "").lower(), (g("PixelFormat") or "").lower(), int(g("Width") or 0), int(g("Height") or 0)
        if codec not in CODECS[dom]:
            return "%s codec %s unsupported" % (dom, codec)
        if fmt not in FORMATS:
            return "pixel format %s unsupported" % fmt
        if fmt in TEN_BIT_FORMATS and codec not in CODECS10[dom]:
            return "%s 10-bit (%s) not supported for codec %s" % (dom, fmt, codec)
        if w > int(caps[PFX[dom] + "_max_width"]) or h > int(caps[PFX[dom] + "_max_height"]):
            return "%s %dx%d > max %sx%s" % (dom, w, h, caps[PFX[dom] + "_max_width"], caps[PFX[dom] + "_max_height"])
        groups[(dom, w, h)] = groups.get((dom, w, h), 0) + 1
        for cid in re.findall(r'"Id"\s*:\s*"(\w+)"', blk):
            if cid in CTRL_FEATS:
                feats.add(CTRL_FEATS[cid])
        if re.search(r'"DownScaleWidth"', blk):
            feats.add("downscale")
    # the WxH in the file name should match the Width/Height inside the JSON
    in_name = set((int(a), int(b)) for a, b in re.findall(r"(?<![0-9])(\d{3,4})_(\d{3,4})(?![0-9])", name))
    in_json = set((w, h) for (_, w, h) in groups)
    if in_name and in_name != in_json:
        sys.stderr.write("WARNING: %s: name says %s but JSON has %s\n" % (
            os.path.basename(cfg), sorted(in_name), sorted(in_json)))
    for f in sorted(feats):
        if not feat_ok(f):
            return "encoder feature %s unsupported" % f
    for (dom, w, h), n in groups.items():
        n = n if concurrent else 1          # Sequential runs one session at a time
        lim = session_limit(dom, w, h)
        if lim is not None and n > int(lim):
            return "%s %dx%d: %d sessions > max %d" % (dom, w, h, n, int(lim))
    return None

for cfg in sys.argv[4:]:
    why = check(cfg)
    print("SKIP\t%s\t%s" % (cfg, why) if why else "RUN\t%s" % cfg)
PYEOF

MACHINE=$(cat /sys/devices/soc0/machine 2>/dev/null)
[ -z "$MACHINE" ] && MACHINE=$(tr '\0' ' ' < /proc/device-tree/model 2>/dev/null)

caps() { python3 -I "$CAPS_PY" "$ROOT/platforms.json" "$MACHINE" "$@"; }

eval "$(caps info)" || { echo "ERROR: cannot read platforms.json"; exit 1; }

echo "========================================"
echo "Machine      : ${MACHINE:-unknown}"
echo "Platform     : $PLATFORM"
[ "$MATCHED" = 0 ] && echo "WARNING      : machine not in platforms.json -> using 'default' (add it!)"
echo "Decoder      : $DECODER_CODECS  ($INFO_DECODER)"
echo "Decoder 10bit: $DECODER_CODECS_10BIT"
echo "Encoder      : $ENCODER_CODECS  ($INFO_ENCODER)"
echo "Encoder 10bit: $ENCODER_CODECS_10BIT"
echo "Pixel formats: $PIXEL_FORMATS"
echo "Enc features : $ENC_FEATURES"
echo "Fluster jobs  : $FLUSTER_JOBS  (min pass: avc>=$FLUSTER_MIN_AVC hevc>=$FLUSTER_MIN_HEVC vp9>=$FLUSTER_MIN_VP9)"
echo "Suites       : $SEL_SUITES"
want iris_v4l2_test && echo "Iris folders : $SEL_IRIS"
echo "========================================"

##############################################################################
# 3. Iris config selection (shared by --list and the real run)
##############################################################################

# Fills $IRIS_DIR/runlist with configs that pass the platform filter; prints SKIPs.
iris_select() {
    IRIS_DIR="$ROOT/iris-v4l2-test"
    : > "$TMPD/all"
    for d in $SEL_IRIS; do
        [ -d "$IRIS_DIR/$d" ] && (cd "$IRIS_DIR" && find "$d" -name '*.json' | sort) >> "$TMPD/all"
    done
    (cd "$IRIS_DIR" && xargs -r python3 -I "$CAPS_PY" "$ROOT/platforms.json" "$MACHINE" filter < "$TMPD/all") > "$TMPD/verdict"
    cut -f1,2 "$TMPD/verdict" | awk -F'\t' '$1=="RUN"{print $2}' > "$TMPD/runlist"
    awk -F'\t' '$1=="SKIP"{printf "SKIP (%s): %s\n", $3, $2}' "$TMPD/verdict"
    echo "Iris configs: $(wc -l < "$TMPD/runlist") to run, $(grep -c '^SKIP' "$TMPD/verdict") skipped (of $(wc -l < "$TMPD/all"))"
}

if [ "$LIST_ONLY" -eq 1 ]; then
    want iris_v4l2_test && { cd "$ROOT" && iris_select; sed 's/^/RUN: /' "$TMPD/runlist"; }
    exit 0
fi

##############################################################################
# 4. Suites
##############################################################################

run_v4l2_compliance() {
    echo; echo "################ V4L2-COMPLIANCE ################"
    fail_begin v4l2-compliance
    cd "$ROOT/v4l2" || return 1

    BITSTREAM="$ROOT/v4l2/avc_decoder_input_1280_720.h264"

    DEC_LOG="$ROOT/decoder_compliance.log"
    ENC_LOG="$ROOT/encoder_compliance.log"

    rm -f "$DEC_LOG" "$ENC_LOG"

    DEC_COUNT=0
    ENC_COUNT=0

    for node in /dev/video*; do
        info="$(v4l2-ctl -d "$node" --info)"

        echo "........ $info"
        if echo "$info" | grep -q "Iris Decoder"; then
            DEC_COUNT=$((DEC_COUNT + 1))
            NODELOG="$TMPD/node_decoder_$(basename "$node").log"

            echo
            echo "========================================="
            echo "Running Decoder Compliance on $node"
            echo "========================================="

            {
                echo
                echo "===== $node ====="
                timeout -k 2 "$V4L2_TIMEOUT" v4l2-compliance \
                    -d "$node" \
                    -s5 \
                    --stream-from="$BITSTREAM" 2>&1
                [ $? -eq 124 ] && echo "TIMEOUT: v4l2-compliance exceeded ${V4L2_TIMEOUT}s on $node"
            } | tee "$NODELOG"
            cat "$NODELOG" >> "$DEC_LOG"
            if grep -Eq "Failed: [1-9]|^TIMEOUT:" "$NODELOG" || ! grep -q "Total for" "$NODELOG"; then
                record_fail v4l2-compliance "decoder_$(basename "$node")" "$(grep -E '^TIMEOUT:|Total for' "$NODELOG" | tail -1)" "$NODELOG"
            fi
        fi

        if echo "$info" | grep -q "Iris Encoder"; then
            ENC_COUNT=$((ENC_COUNT + 1))
            NODELOG="$TMPD/node_encoder_$(basename "$node").log"

            echo
            echo "========================================="
            echo "Running Encoder Compliance on $node"
            echo "========================================="

            {
                echo
                echo "===== $node ====="
                timeout -k 2 "$V4L2_TIMEOUT" v4l2-compliance \
                    -d "$node" \
                    -s 2>&1
                [ $? -eq 124 ] && echo "TIMEOUT: v4l2-compliance exceeded ${V4L2_TIMEOUT}s on $node"
            } | tee "$NODELOG"
            cat "$NODELOG" >> "$ENC_LOG"
            if grep -Eq "Failed: [1-9]|^TIMEOUT:" "$NODELOG" || ! grep -q "Total for" "$NODELOG"; then
                record_fail v4l2-compliance "encoder_$(basename "$node")" "$(grep -E '^TIMEOUT:|Total for' "$NODELOG" | tail -1)" "$NODELOG"
            fi
        fi
    done

    echo
    echo "========================================="
    echo "FINAL SUMMARY"
    echo "========================================="

    echo
    echo "Decoder:"
    grep "Total for" "$DEC_LOG"

    echo
    echo "Encoder:"
    grep "Total for" "$ENC_LOG"
    echo

    if [ "$DEC_COUNT" -eq 0 ] && [ "$ENC_COUNT" -eq 0 ]; then
        echo "ERROR: no Iris Decoder/Encoder nodes found - nothing was tested"
        record_fail v4l2-compliance "no_nodes" "no 'Iris Decoder'/'Iris Encoder' video node found"
        return 1
    fi
    ! grep -q '^v4l2-compliance |' "$FAILED_LIST"
}

run_fluster() {
    echo; echo "################ FLUSTER ################"
    fail_begin fluster
    cd "$ROOT/fluster" || return 1
    # codec : fluster test suite : gstreamer decoder : min passed vectors
    for e in "avc:JVT-AVC_V1:GStreamer-H.264-V4L2-Gst1.0:$FLUSTER_MIN_AVC" \
             "hevc:JCT-VC-HEVC_V1:GStreamer-H.265-V4L2-Gst1.0:$FLUSTER_MIN_HEVC" \
             "vp9:VP9-TEST-VECTORS:GStreamer-VP9-V4L2-Gst1.0:$FLUSTER_MIN_VP9"; do
        codec=${e%%:*}; rest=${e#*:}; ts=${rest%%:*}; rest=${rest#*:}; dec=${rest%%:*}; min=${rest#*:}
        echo; echo "========== $codec =========="
        case " $DECODER_CODECS " in
            *" $codec "*)
                python3 fluster.py -tsd ./test_suites -r ./resources run -ts "$ts" -d "$dec" -j "$FLUSTER_JOBS" -t "$FLUSTER_TIMEOUT" | tee "${codec}_log.txt" ;;
            *) echo "SKIPPED: $codec decoder unsupported on $PLATFORM" | tee "${codec}_log.txt" ;;
        esac
    done
    echo; echo "FLUSTER SUMMARY"
    for e in "avc:$FLUSTER_MIN_AVC" "hevc:$FLUSTER_MIN_HEVC" "vp9:$FLUSTER_MIN_VP9"; do
        codec=${e%%:*}; min=${e#*:}
        case " $DECODER_CODECS " in *" $codec "*) ;; *) echo "$codec: skipped (unsupported)"; continue ;; esac
        if [ -z "$min" ]; then
            echo "$codec: FAIL - fluster_min_pass.$codec missing in platforms.json"
            record_fail fluster "$codec" "fluster_min_pass.$codec missing in platforms.json" "${codec}_log.txt"
            continue
        fi
        line=$(grep -E 'Ran [0-9]+/[0-9]+ tests successfully' "${codec}_log.txt" | tail -1)
        passed=$(echo "$line" | sed -n 's/.*Ran \([0-9]*\)\/\([0-9]*\) tests.*/\1/p')
        total=$(echo "$line" | sed -n 's/.*Ran \([0-9]*\)\/\([0-9]*\) tests.*/\2/p')
        if [ -z "$passed" ]; then
            echo "$codec: FAIL - no result line (crash or timeout)"
            record_fail fluster "$codec" "no 'Ran X/Y tests' result line" "${codec}_log.txt"
        elif [ "$passed" -ge "$min" ]; then
            echo "$codec: PASS  $passed/$total passed (expected >= $min)"
        else
            echo "$codec: FAIL  $passed/$total passed (expected >= $min)"
            record_fail fluster "$codec" "$passed/$total passed, expected >= $min" "${codec}_log.txt"
        fi
    done
    ! grep -q '^fluster |' "$FAILED_LIST"
}

run_iris_v4l2_test() {
    echo; echo "################ IRIS_V4L2_TEST ################"
    fail_begin iris_v4l2_test
    cd "$ROOT" && iris_select
    cd "$IRIS_DIR" || return 1
    BINARY=./iris_v4l2_test; LOG_DIR=logs; SUMMARY=iris_v4l2_test_result.txt
    [ -x "$BINARY" ] || { echo "ERROR: $BINARY not found"; return 1; }
    TOTAL=$(wc -l < "$TMPD/runlist")
    if [ "$TOTAL" -eq 0 ]; then
        if [ -s "$TMPD/all" ]; then echo "All configs skipped for platform $PLATFORM"; return 0; fi
        echo "ERROR: no iris config files found in: $SEL_IRIS"; return 1
    fi
    mkdir -p "$LOG_DIR"
    PASSED=0; FAILED=0; DONE=0
    printf 'IRIS TEST SUMMARY (%s)\n=================\n\n' "$PLATFORM" > "$SUMMARY"

    # live display: colours only on a terminal
    if [ -t 1 ]; then
        GRN=$(printf '\033[32m'); RED=$(printf '\033[31m'); YEL=$(printf '\033[33m')
        DIM=$(printf '\033[2m'); OFF=$(printf '\033[0m'); TTY=1
    else
        GRN=; RED=; YEL=; DIM=; OFF=; TTY=0
    fi
    W=$(awk '{ if (length($0) > m) m = length($0) } END { print m - 5 }' "$TMPD/runlist")   # longest "<dir>/<name>" without .json
    printf '\n%-9s %-6s %-*s %9s %7s   %s\n' "#" "RESULT" "$W" "CONFIG" "SUCCESS" "TIME" "LIVE COUNTS"
    printf '%s\n' "$(printf '%*s' $((W + 75)) '' | tr ' ' '-')"

    while read -r JSON; do
        [ -z "$JSON" ] && continue
        BASE=$(basename "$JSON" .json); LOGFILE="$LOG_DIR/$BASE.log"
        NAME=${JSON%.json}
        EXPECTED=$(grep -c '"Domain":[[:space:]]*"\(Decoder\|Encoder\)"' "$JSON")
        IDX=$(printf '[%*d/%d]' "${#TOTAL}" $((DONE + 1)) "$TOTAL")
        # transient "running" line, overwritten by the result
        [ "$TTY" -eq 1 ] && printf '%-9s %s%-6s%s %s   %sPassed:%d Failed:%d Pending:%d%s\r' "$IDX" "$YEL" "RUN" "$OFF" "$NAME" \
            "$DIM" "$PASSED" "$FAILED" $((TOTAL - DONE)) "$OFF"
        T0=$(date +%s.%N)
        timeout -k 2 "$IRIS_TIMEOUT" "$BINARY" --config "$JSON" > "$LOGFILE" 2>&1 < /dev/null
        TRC=$?
        SECS=$(awk -v a="$T0" -v b="$(date +%s.%N)" 'BEGIN { printf "%.1fs", b - a }')
        ACTUAL=$(grep -c "SUCCESS!" "$LOGFILE")
        REASON=""
        if [ "$TRC" -ne 124 ] && [ "$EXPECTED" -gt 0 ] && [ "$ACTUAL" -eq "$EXPECTED" ]; then
            RESULT=PASS; COL=$GRN; PASSED=$((PASSED + 1)); rm -f "$LOGFILE"
        else
            RESULT=FAIL; COL=$RED; REASON="expected $EXPECTED: actual $ACTUAL"
            [ "$TRC" -eq 124 ] && { RESULT=TIME; REASON="timeout after ${IRIS_TIMEOUT}s"; }
            FAILED=$((FAILED + 1))
            record_fail iris_v4l2_test "$BASE" "$REASON" "$LOGFILE"; rm -f "$LOGFILE"
        fi
        DONE=$((DONE + 1))
        [ "$TTY" -eq 1 ] && printf '\033[2K'      # clear the transient line
        printf '%-9s %s%-6s%s %-*s %9s %7s   %sPassed:%d Failed:%d Pending:%d%s\n' "$IDX" "$COL" "$RESULT" "$OFF" "$W" "$NAME" \
            "$ACTUAL/$EXPECTED" "$SECS" "$DIM" "$PASSED" "$FAILED" $((TOTAL - DONE)) "$OFF"
        [ -n "$REASON" ] && printf '%-9s %s%s%s\n' "" "$RED" "-> $REASON" "$OFF"
        echo "$BASE : $RESULT (Expected=$EXPECTED Actual=$ACTUAL, $SECS)" >> "$SUMMARY"
        rm -rf output_folder/* 2>/dev/null
    done < "$TMPD/runlist"

    rm -rf back_trace_*.log
    printf '\n=================\nTOTAL : %s\nPASS  : %s\nFAIL  : %s\n' "$TOTAL" "$PASSED" "$FAILED" | tee -a "$SUMMARY"
    echo "Summary : $IRIS_DIR/$SUMMARY"
    [ "$FAILED" -eq 0 ]
}

RC=0
for s in $SUITES; do
    want "$s" || continue
    ( "run_$(echo "$s" | tr - _)" ) || { echo ">>> suite '$s' FAILED"; RC=1; }
done

echo; echo "========================================"
if [ -s "$FAILED_LIST" ]; then
    echo "FAILED TESTS ($(wc -l < "$FAILED_LIST")):"
    while IFS='|' read -r fs fn fr; do
        fs=$(echo "$fs" | sed 's/^ *//;s/ *$//'); fn=$(echo "$fn" | sed 's/^ *//;s/ *$//'); fr=$(echo "$fr" | sed 's/^ *//')
        echo "  [$fs] $fn : $fr"
        [ -f "$FAILDIR/$fs/$fn.log" ] && echo "      log: $FAILDIR/$fs/$fn.log"
    done < "$FAILED_LIST"
fi
[ "$RC" -eq 0 ] && echo "********** PASSED **********" || echo "********** FAILED **********"
exit $RC
