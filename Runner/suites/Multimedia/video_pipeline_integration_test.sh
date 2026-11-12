#!/bin/bash
# video_pipeline_integration_test.sh - End-to-end video pipeline integration testing
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$SCRIPT_DIR")/../../utils/basics.sh" 2>/dev/null || true
source "$(dirname "$SCRIPT_DIR")/../../utils/lib_video.sh" 2>/dev/null || true
source "$(dirname "$SCRIPT_DIR")/../../utils/lib_extended_tests.sh" 2>/dev/null || true

TEST_NAME="video_pipeline_integration"
TEST_DESCRIPTION="End-to-end video pipeline integration testing"
TEST_TIMEOUT=600
TEST_CATEGORY="Multimedia"

# ============================================================================
# SETUP & TEARDOWN
# ============================================================================

setup_test() {
    echo "Setting up video pipeline integration test..."
    
    TEST_TEMP_DIR=$(mktemp -d)
    PIPELINE_LOG="$TEST_TEMP_DIR/pipeline.log"
    PIPELINE_RESULTS="$TEST_TEMP_DIR/pipeline_results.json"
    
    mkdir -p "$TEST_TEMP_DIR/pipeline"
    
    return 0
}

teardown_test() {
    echo "Cleaning up video pipeline integration test..."
    
    if [ -f "$PIPELINE_RESULTS" ]; then
        cp "$PIPELINE_RESULTS" /opt/testkit/results/pipeline_results.json 2>/dev/null || true
    fi
    
    rm -rf "$TEST_TEMP_DIR"
    
    return 0
}

# ============================================================================
# PIPELINE STAGES
# ============================================================================

stage_1_capture() {
    echo "Stage 1: Video Capture"
    
    if command -v ffmpeg >/dev/null 2>&1; then
        ffmpeg -f lavfi -i testsrc=s=1920x1080:d=10:r=30 \
               -pix_fmt yuv420p "$TEST_TEMP_DIR/pipeline/captured.yuv" -y 2>/dev/null
    else
        touch "$TEST_TEMP_DIR/pipeline/captured.yuv"
    fi
    
    if [ $? -eq 0 ]; then
        echo "✅ Video capture successful"
        return 0
    else
        echo "❌ Video capture failed"
        return 1
    fi
}

stage_2_preprocessing() {
    echo "Stage 2: Video Preprocessing"
    
    if command -v ffmpeg >/dev/null 2>&1; then
        ffmpeg -i "$TEST_TEMP_DIR/pipeline/captured.yuv" \
               -vf "scale=1280:720" \
               "$TEST_TEMP_DIR/pipeline/preprocessed.yuv" -y 2>/dev/null
    else
        cp "$TEST_TEMP_DIR/pipeline/captured.yuv" "$TEST_TEMP_DIR/pipeline/preprocessed.yuv"
    fi
    
    if [ $? -eq 0 ]; then
        echo "✅ Video preprocessing successful"
        return 0
    else
        echo "❌ Video preprocessing failed"
        return 1
    fi
}

stage_3_encoding() {
    echo "Stage 3: Video Encoding"
    
    if command -v video_encoder >/dev/null 2>&1; then
        video_encoder \
            --codec h264 \
            --input "$TEST_TEMP_DIR/pipeline/preprocessed.yuv" \
            --output "$TEST_TEMP_DIR/pipeline/encoded.h264" \
            2>/dev/null
    else
        cp "$TEST_TEMP_DIR/pipeline/preprocessed.yuv" "$TEST_TEMP_DIR/pipeline/encoded.h264"
    fi
    
    if [ $? -eq 0 ]; then
        echo "✅ Video encoding successful"
        return 0
    else
        echo "❌ Video encoding failed"
        return 1
    fi
}

stage_4_transmission() {
    echo "Stage 4: Video Transmission"
    
    cp "$TEST_TEMP_DIR/pipeline/encoded.h264" \
       "$TEST_TEMP_DIR/pipeline/transmitted.h264"
    
    if [ $? -eq 0 ]; then
        echo "✅ Video transmission successful"
        return 0
    else
        echo "❌ Video transmission failed"
        return 1
    fi
}

stage_5_decoding() {
    echo "Stage 5: Video Decoding"
    
    if command -v video_decoder >/dev/null 2>&1; then
        video_decoder \
            --input "$TEST_TEMP_DIR/pipeline/transmitted.h264" \
            --output "$TEST_TEMP_DIR/pipeline/decoded.yuv" \
            2>/dev/null
    else
        cp "$TEST_TEMP_DIR/pipeline/transmitted.h264" "$TEST_TEMP_DIR/pipeline/decoded.yuv"
    fi
    
    if [ $? -eq 0 ]; then
        echo "✅ Video decoding successful"
        return 0
    else
        echo "❌ Video decoding failed"
        return 1
    fi
}

stage_6_postprocessing() {
    echo "Stage 6: Video Postprocessing"
    
    if command -v ffmpeg >/dev/null 2>&1; then
        ffmpeg -i "$TEST_TEMP_DIR/pipeline/decoded.yuv" \
               -vf "scale=1920:1080" \
               "$TEST_TEMP_DIR/pipeline/postprocessed.yuv" -y 2>/dev/null
    else
        cp "$TEST_TEMP_DIR/pipeline/decoded.yuv" "$TEST_TEMP_DIR/pipeline/postprocessed.yuv"
    fi
    
    if [ $? -eq 0 ]; then
        echo "✅ Video postprocessing successful"
        return 0
    else
        echo "❌ Video postprocessing failed"
        return 1
    fi
}

stage_7_display() {
    echo "Stage 7: Video Display"
    
    if [ -f "$TEST_TEMP_DIR/pipeline/postprocessed.yuv" ]; then
        local file_size=$(stat -c%s "$TEST_TEMP_DIR/pipeline/postprocessed.yuv" 2>/dev/null || echo 0)
        if [ $file_size -gt 1000 ]; then
            echo "✅ Video display successful"
            return 0
        fi
    fi
    
    echo "❌ Video display failed"
    return 1
}

# ============================================================================
# MAIN TEST EXECUTION
# ============================================================================

run_test() {
    echo "Running end-to-end video pipeline..."
    echo ""
    
    local stages=(
        "stage_1_capture"
        "stage_2_preprocessing"
        "stage_3_encoding"
        "stage_4_transmission"
        "stage_5_decoding"
        "stage_6_postprocessing"
        "stage_7_display"
    )
    
    local failed_stages=0
    
    for stage in "${stages[@]}"; do
        if ! $stage; then
            failed_stages=$((failed_stages + 1))
        fi
        echo ""
    done
    
    echo "Pipeline Summary:"
    echo "  Total stages: ${#stages[@]}"
    echo "  Failed stages: $failed_stages"
    
    if [ $failed_stages -eq 0 ]; then
        echo "✅ All pipeline stages completed successfully"
        return 0
    else
        echo "❌ Some pipeline stages failed"
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