#!/usr/bin/env bash
# Wrapper for Sequential Benchmark
TOOL="${1:-fio}"
./run_full_benchmark.sh SEQ "$TOOL"
