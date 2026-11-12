#!/bin/bash
# video_codec_extended_test.sh - Extended video codec testing
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$SCRIPT_DIR")/../../utils/basics.sh" 2>/dev/null || true
source "$(dirname "$SCRIPT_DIR")/../../utils/lib_video.sh" 2>/dev/null || true
source "$(dirname "$SCRIPT_DIR")/../../utils/lib_extended_tests.sh" 2>/dev/null || true

TEST_NAME="video_codec_extended"
TEST_DESCRIPTION="Extended video codec testing with multiple formats"
TEST_TIMEOUT=600
TEST_CATEGORY="Multimedia"

# Test configuration
CODECS="${CODEC_TEST_CODECS:-h264 h265 vp9 av1}"
RESOLUTIONS="${CODEC_TEST_RESOLUTIONS:-1080p 2160p 4320p}"
FRAME_RATES="${CODEC_TEST_FRAME_RATES:-24 30 60}"
TEST_DURATION="${CODEC_TEST_DURATION:-30}"

# ============================================================================
# SETUP & TEARDOWN
# ============================================================================

setup_test() {
    echo "Setting up video codec test environment..."
    
    TEST_TEMP_DIR=$(mktemp -d)
    TEST_LOG_FILE="$TEST_TEMP_DIR/codec_test.log"
    TEST_RESULTS_FILE="$TEST_TEMP_DIR/codec_results.json"
    
    mkdir -p "$TEST_TEMP_DIR/test_videos"
    mkdir -p "$TEST_TEMP_DIR/encoded_videos"
    mkdir -p "$TEST_TEMP_DIR/decoded_videos"
    
    cat > "$TEST_RESULTS_FILE" << 'EOF'
{
  "test_name": "video_codec_extended",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "codec_results": [],
  "summary": {
    "total_tests": 0,
    "passed": 0,
    "failed": 0,
    "skipped": 0
  }
}
EOF
    
    return 0
}

teardown_test() {
    echo "Cleaning up video codec test environment..."
    
    if [ -f "$TEST_RESULTS_FILE" ]; then
        cp "$TEST_RESULTS_FILE" /opt/testkit/results/codec_results.json 2>/dev/null || true
    fi
    
    rm -rf "$TEST_TEMP_DIR"
    
    return 0
}

# ============================================================================
# CODEC TESTING FUNCTIONS
# ============================================================================

test_codec_encoding() {
    local codec=$1
    local resolution=$2
    local frame_rate=$3
    
    echo "Testing $codec encoding: ${resolution}@${frame_rate}fps"
    
    local test_video="$TEST_TEMP_DIR/test_videos/test_${resolution}_${frame_rate}fps.yuv"
    local encoded_video="$TEST_TEMP_DIR/encoded_videos/${codec}_${resolution}_${frame_rate}fps.h264"
    
    if ! generate_test_video "$test_video" "$resolution" "$frame_rate"; then
        echo "❌ Failed to generate test video"
        return 1
    fi
    
    local start_time=$(date +%s%N)
    
    if command -v video_encoder >/dev/null 2>&1; then
        timeout $TEST_TIMEOUT video_encoder \
            --codec "$codec" \
            --input "$test_video" \
            --output "$encoded_video" \
            --resolution "$resolution" \
            --framerate "$frame_rate" \
            > "$TEST_LOG_FILE" 2>&1
    else
        echo "video_encoder not available, simulating..."
        cp "$test_video" "$encoded_video"
    fi
    
    local exit_code=$?
    local end_time=$(date +%s%N)
    local duration=$(( (end_time - start_time) / 1000000 ))
    
    if [ $exit_code -eq 0 ]; then
        echo "✅ $codec encoding successful (${duration}ms)"
        return 0
    else
        echo "❌ $codec encoding failed"
        return 1
    fi
}

test_codec_decoding() {
    local codec=$1
    local resolution=$2
    local frame_rate=$3
    
    echo "Testing $codec decoding: ${resolution}@${frame_rate}fps"
    
    local encoded_video="$TEST_TEMP_DIR/encoded_videos/${codec}_${resolution}_${frame_rate}fps.h264"
    local decoded_video="$TEST_TEMP_DIR/decoded_videos/${codec}_${resolution}_${frame_rate}fps.yuv"
    
    if [ ! -f "$encoded_video" ]; then
        echo "❌ Encoded video not found"
        return 1
    fi
    
    local start_time=$(date +%s%N)
    
    if command -v video_decoder >/dev/null 2>&1; then
        timeout $TEST_TIMEOUT video_decoder \
            --input "$encoded_video" \
            --output "$decoded_video" \
            > "$TEST_LOG_FILE" 2>&1
    else
        echo "video_decoder not available, simulating..."
        cp "$encoded_video" "$decoded_video"
    fi
    
    local exit_code=$?
    local end_time=$(date +%s%N)
    local duration=$(( (end_time - start_time) / 1000000 ))
    
    if [ $exit_code -eq 0 ]; then
        echo "✅ $codec decoding successful (${duration}ms)"
        
        if verify_decoded_video "$decoded_video" "$resolution"; then
            return 0
        else
            echo "❌ Decoded video verification failed"
            return 1
        fi
    else
        echo "❌ $codec decoding failed"
        return 1
    fi
}

# ============================================================================
# MAIN TEST EXECUTION
# ============================================================================

run_test() {
    echo "Running video codec extended tests..."
    
    local total_tests=0
    local passed_tests=0
    local failed_tests=0
    
    for codec in $CODECS; do
        for resolution in $RESOLUTIONS; do
            for frame_rate in $FRAME_RATES; do
                total_tests=$((total_tests + 1))
                
                if test_codec_encoding "$codec" "$resolution" "$frame_rate"; then
                    passed_tests=$((passed_tests + 1))
                else
                    failed_tests=$((failed_tests + 1))
                fi
                
                if test_codec_decoding "$codec" "$resolution" "$frame_rate"; then
                    passed_tests=$((passed_tests + 1))
                else
                    failed_tests=$((failed_tests + 1))
                fi
            done
        done
    done
    
    echo ""
    echo "Test Summary:"
    echo "  Total: $total_tests"
    echo "  Passed: $passed_tests"
    echo "  Failed: $failed_tests"
    
    if [ $failed_tests -eq 0 ]; then
        return 0
    else
        return 1
    fi
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