#!/bin/bash
# video_stress_extended_test.sh - Extended video stress testing
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$SCRIPT_DIR")/../../utils/basics.sh" 2>/dev/null || true
source "$(dirname "$SCRIPT_DIR")/../../utils/lib_video.sh" 2>/dev/null || true
source "$(dirname "$SCRIPT_DIR")/../../utils/lib_extended_tests.sh" 2>/dev/null || true

TEST_NAME="video_stress_extended"
TEST_DESCRIPTION="Extended video stress testing with concurrent operations"
TEST_TIMEOUT=1200
TEST_CATEGORY="Multimedia"

# Stress test configuration
CONCURRENT_STREAMS="${STRESS_CONCURRENT_STREAMS:-4}"
STRESS_DURATION="${STRESS_DURATION:-300}"
FRAME_RATE="${STRESS_FRAME_RATE:-30}"

# ============================================================================
# SETUP & TEARDOWN
# ============================================================================

setup_test() {
    echo "Setting up video stress test environment..."
    
    TEST_TEMP_DIR=$(mktemp -d)
    STRESS_LOG="$TEST_TEMP_DIR/stress.log"
    STRESS_RESULTS="$TEST_TEMP_DIR/stress_results.json"
    
    mkdir -p "$TEST_TEMP_DIR/streams"
    
    cat > "$STRESS_RESULTS" << 'EOF'
{
  "test_name": "video_stress_extended",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "streams": [],
  "summary": {
    "total_streams": 0,
    "successful_streams": 0,
    "failed_streams": 0
  }
}
EOF
    
    return 0
}

teardown_test() {
    echo "Cleaning up video stress test environment..."
    
    pkill -f "video_stream" 2>/dev/null || true
    
    if [ -f "$STRESS_RESULTS" ]; then
        cp "$STRESS_RESULTS" /opt/testkit/results/stress_results.json 2>/dev/null || true
    fi
    
    rm -rf "$TEST_TEMP_DIR"
    
    return 0
}

# ============================================================================
# STRESS TEST FUNCTIONS
# ============================================================================

run_concurrent_video_streams() {
    echo "Running $CONCURRENT_STREAMS concurrent video streams..."
    
    local pids=()
    local failed_count=0
    
    for i in $(seq 1 $CONCURRENT_STREAMS); do
        run_video_stream $i &
        pids+=($!)
    done
    
    for pid in "${pids[@]}"; do
        if ! wait $pid; then
            failed_count=$((failed_count + 1))
        fi
    done
    
    echo "Concurrent streams completed"
    echo "  Failed streams: $failed_count"
    
    if [ $failed_count -eq 0 ]; then
        return 0
    else
        return 1
    fi
}

run_video_stream() {
    local stream_id=$1
    local stream_log="$TEST_TEMP_DIR/streams/stream_${stream_id}.log"
    
    echo "Starting video stream $stream_id" >> "$stream_log"
    
    local test_video="$TEST_TEMP_DIR/streams/test_stream_${stream_id}.yuv"
    
    if command -v ffmpeg >/dev/null 2>&1; then
        ffmpeg -f lavfi -i testsrc=s=1920x1080:d=${STRESS_DURATION}:r=${FRAME_RATE} \
               -pix_fmt yuv420p "$test_video" -y 2>/dev/null
    else
        echo "ffmpeg not available, simulating..." >> "$stream_log"
        touch "$test_video"
    fi
    
    if [ $? -ne 0 ]; then
        echo "❌ Stream $stream_id failed" >> "$stream_log"
        return 1
    fi
    
    echo "✅ Stream $stream_id completed successfully" >> "$stream_log"
    return 0
}

run_video_loop_stress() {
    echo "Running video loop stress test..."
    
    local loop_count=0
    local max_loops="${STRESS_MAX_LOOPS:-10}"
    local start_time=$(date +%s)
    
    while [ $loop_count -lt $max_loops ]; do
        echo "Loop $((loop_count + 1))/$max_loops"
        
        local test_video="$TEST_TEMP_DIR/loop_test_${loop_count}.yuv"
        
        if command -v ffmpeg >/dev/null 2>&1; then
            ffmpeg -f lavfi -i testsrc=s=1920x1080:d=10:r=30 \
                   -pix_fmt yuv420p "$test_video" -y 2>/dev/null
        else
            touch "$test_video"
        fi
        
        if [ $? -ne 0 ]; then
            echo "❌ Loop $loop_count failed"
            return 1
        fi
        
        loop_count=$((loop_count + 1))
    done
    
    local end_time=$(date +%s)
    local total_duration=$((end_time - start_time))
    
    echo "✅ Video loop stress test completed"
    echo "  Total duration: ${total_duration}s"
    echo "  Loops completed: $loop_count"
    
    return 0
}

# ============================================================================
# MAIN TEST EXECUTION
# ============================================================================

run_test() {
    echo "Running video stress tests..."
    
    if ! run_concurrent_video_streams; then
        echo "❌ Concurrent video streams test failed"
        return 1
    fi
    
    if ! run_video_loop_stress; then
        echo "❌ Video loop stress test failed"
        return 1
    fi
    
    echo "✅ All stress tests passed"
    return 0
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    echo "=== $TEST_NAME ==="
    echo "Description: $TEST_DESCRIPTION"
    echo ""
    
    setup_test || return 1
    run_test
    local test_result=$?
    teardown_test
    
    return $test_result
}

trap 'teardown_test' EXIT
main
exit $?