#!/bin/bash
# WhisperMe tests: pure domain logic without AppKit/networking (Logic.swift).
# Usage: ./tests/run.sh
set -e
cd "$(dirname "$0")/.."

mkdir -p build

swiftc \
    Logic.swift \
    tests/Tests.swift \
    -o build/tests

./build/tests
