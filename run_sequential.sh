#!/usr/bin/env bash
# Wrapper for Sequential Benchmark
TOOL="${1:-fio}"
MODE="${2:-}"
./run_full_benchmark.sh SEQ "$TOOL" "$MODE"
