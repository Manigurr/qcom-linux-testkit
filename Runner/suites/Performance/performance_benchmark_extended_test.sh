#!/bin/bash
# performance_benchmark_extended_test.sh - Extended performance benchmarking
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$SCRIPT_DIR")/../../utils/basics.sh" 2>/dev/null || true
source "$(dirname "$SCRIPT_DIR")/../../utils/lib_extended_tests.sh" 2>/dev/null || true

TEST_NAME="performance_benchmark_extended"
TEST_DESCRIPTION="Extended performance benchmarking with detailed metrics"
TEST_TIMEOUT=900
TEST_CATEGORY="Performance"

# Benchmark configuration
BENCHMARK_DURATION="${BENCHMARK_DURATION:-60}"
BENCHMARK_ITERATIONS="${BENCHMARK_ITERATIONS:-5}"

# ============================================================================
# SETUP & TEARDOWN
# ============================================================================

setup_test() {
    echo "Setting up performance benchmark environment..."
    
    TEST_TEMP_DIR=$(mktemp -d)
    BENCHMARK_LOG="$TEST_TEMP_DIR/benchmark.log"
    METRICS_FILE="$TEST_TEMP_DIR/metrics.json"
    
    mkdir -p "$TEST_TEMP_DIR/results"
    
    cat > "$METRICS_FILE" << 'EOF'
{
  "benchmark_name": "performance_extended",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "metrics": [],
  "summary": {}
}
EOF
    
    return 0
}

teardown_test() {
    echo "Cleaning up performance benchmark environment..."
    
    if [ -f "$METRICS_FILE" ]; then
        cp "$METRICS_FILE" /opt/testkit/results/performance_metrics.json 2>/dev/null || true
    fi
    
    rm -rf "$TEST_TEMP_DIR"
    
    return 0
}

# ============================================================================
# BENCHMARK FUNCTIONS
# ============================================================================

run_cpu_benchmark() {
    echo "Running CPU benchmark..."
    
    local start_time=$(date +%s%N)
    
    timeout $BENCHMARK_DURATION bash -c '
        for i in $(seq 1 1000000); do
            echo $((i * i)) > /dev/null
        done
    ' 2>/dev/null
    
    local end_time=$(date +%s%N)
    local duration=$(( (end_time - start_time) / 1000000 ))
    
    local cpu_usage=$(measure_cpu_usage)
    
    echo "CPU Benchmark Results:"
    echo "  Duration: ${duration}ms"
    echo "  CPU Usage: ${cpu_usage}%"
    
    return 0
}

run_memory_benchmark() {
    echo "Running memory benchmark..."
    
    local start_time=$(date +%s%N)
    
    dd if=/dev/zero of="$TEST_TEMP_DIR/test_memory" bs=1M count=100 2>/dev/null
    
    local end_time=$(date +%s%N)
    local duration=$(( (end_time - start_time) / 1000000 ))
    
    local mem_usage=$(measure_memory_usage)
    
    echo "Memory Benchmark Results:"
    echo "  Duration: ${duration}ms"
    echo "  Memory Usage: ${mem_usage}%"
    
    return 0
}

run_io_benchmark() {
    echo "Running I/O benchmark..."
    
    local test_file="$TEST_TEMP_DIR/io_test.bin"
    local test_size=$((50 * 1024 * 1024))
    
    local write_start=$(date +%s%N)
    dd if=/dev/zero of="$test_file" bs=1M count=50 2>/dev/null
    local write_end=$(date +%s%N)
    local write_duration=$(( (write_end - write_start) / 1000000 ))
    
    local read_start=$(date +%s%N)
    dd if="$test_file" of=/dev/null bs=1M 2>/dev/null
    local read_end=$(date +%s%N)
    local read_duration=$(( (read_end - read_start) / 1000000 ))
    
    echo "I/O Benchmark Results:"
    echo "  Write Duration: ${write_duration}ms"
    echo "  Read Duration: ${read_duration}ms"
    
    return 0
}

# ============================================================================
# MAIN TEST EXECUTION
# ============================================================================

run_test() {
    echo "Running performance benchmarks..."
    
    for i in $(seq 1 $BENCHMARK_ITERATIONS); do
        echo ""
        echo "Iteration $i/$BENCHMARK_ITERATIONS"
        
        run_cpu_benchmark
        run_memory_benchmark
        run_io_benchmark
    done
    
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