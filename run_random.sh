#!/usr/bin/env bash
# Wrapper for Random Benchmark
TOOL="${1:-fio}"
MODE="${2:-}"
./run_full_benchmark.sh RAND "$TOOL" "$MODE"
