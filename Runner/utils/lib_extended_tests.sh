#!/bin/bash
# lib_extended_tests.sh - Extended test utilities library
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

# ============================================================================
# CODEC TESTING UTILITIES
# ============================================================================

generate_test_video() {
    local output_file=$1
    local resolution=$2
    local frame_rate=$3
    local duration=${4:-30}
    
    echo "Generating test video: ${resolution}@${frame_rate}fps"
    
    if command -v ffmpeg >/dev/null 2>&1; then
        ffmpeg -f lavfi -i testsrc=s=${resolution}:d=${duration}:r=${frame_rate} \
               -pix_fmt yuv420p "$output_file" -y 2>/dev/null
        return $?
    else
        echo "ffmpeg not available"
        return 1
    fi
}

verify_decoded_video() {
    local video_file=$1
    local expected_resolution=$2
    
    if [ ! -f "$video_file" ]; then
        return 1
    fi
    
    local file_size=$(stat -c%s "$video_file" 2>/dev/null || echo 0)
    if [ "$file_size" -lt 1000 ]; then
        return 1
    fi
    
    return 0
}

# ============================================================================
# PERFORMANCE TESTING UTILITIES
# ============================================================================

measure_cpu_usage() {
    if command -v top >/dev/null 2>&1; then
        top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1
    else
        echo "0"
    fi
}

measure_memory_usage() {
    if command -v free >/dev/null 2>&1; then
        free | grep Mem | awk '{printf "%.2f", $3/$2 * 100}'
    else
        echo "0"
    fi
}

measure_io_throughput() {
    local test_file=$1
    local test_size=$2
    
    if [ -z "$test_size" ]; then
        test_size=$((50 * 1024 * 1024))
    fi
    
    local start_time=$(date +%s%N)
    dd if=/dev/zero of="$test_file" bs=1M count=$((test_size / 1024 / 1024)) 2>/dev/null
    local end_time=$(date +%s%N)
    
    local duration=$(( (end_time - start_time) / 1000000000 ))
    if [ "$duration" -gt 0 ]; then
        echo "scale=2; $test_size / 1024 / 1024 / $duration" | bc
    else
        echo "0"
    fi
}

# ============================================================================
# STRESS TESTING UTILITIES
# ============================================================================

run_concurrent_task() {
    local task_id=$1
    local task_command=$2
    local task_log=$3
    
    echo "Starting task $task_id" >> "$task_log"
    
    eval "$task_command" >> "$task_log" 2>&1
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        echo "✅ Task $task_id completed" >> "$task_log"
    else
        echo "❌ Task $task_id failed" >> "$task_log"
    fi
    
    return $exit_code
}

# ============================================================================
# RESULT LOGGING UTILITIES
# ============================================================================

log_test_result() {
    local result_file=$1
    local test_name=$2
    local status=$3
    local duration=$4
    local metrics=$5
    
    local result_entry=$(cat <<EOF
{
  "test_name": "$test_name",
  "status": "$status",
  "duration_ms": $duration,
  "metrics": $metrics,
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
)
    
    echo "$result_entry" >> "$result_file"
}

# ============================================================================
# VALIDATION UTILITIES
# ============================================================================

validate_test_environment() {
    local required_tools=("bash" "grep" "awk" "sed")
    
    for tool in "${required_tools[@]}"; do
        if ! command -v $tool &> /dev/null; then
            echo "❌ Required tool not found: $tool"
            return 1
        fi
    done
    
    return 0
}

validate_disk_space() {
    local required_space=$1  # in MB
    local check_path=${2:-/opt/testkit}
    
    if [ ! -d "$check_path" ]; then
        return 0
    fi
    
    local available_space=$(df "$check_path" 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
    local required_kb=$((required_space * 1024))
    
    if [ "$available_space" -lt "$required_kb" ]; then
        echo "❌ Insufficient disk space"
        return 1
    fi
    
    return 0
}

validate_memory() {
    local required_memory=$1  # in MB
    
    if ! command -v free >/dev/null 2>&1; then
        return 0
    fi
    
    local available_memory=$(free 2>/dev/null | grep Mem | awk '{print $7}' || echo 0)
    local required_kb=$((required_memory * 1024))
    
    if [ "$available_memory" -lt "$required_kb" ]; then
        echo "❌ Insufficient memory"
        return 1
    fi
    
    return 0
}

# ============================================================================
# EXPORT FUNCTIONS
# ============================================================================

export -f generate_test_video
export -f verify_decoded_video
export -f measure_cpu_usage
export -f measure_memory_usage
export -f measure_io_throughput
export -f run_concurrent_task
export -f log_test_result
export -f validate_test_environment
export -f validate_disk_space
export -f validate_memory