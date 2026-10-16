#!/bin/bash
# Domain and mocked HTTP regressions. No microphone, credentials or network required.
# Usage: ./tests/run.sh
set -e
cd "$(dirname "$0")/.."

mkdir -p build

swiftc \
    Logic.swift \
    tests/Tests.swift \
    -o build/tests

./build/tests

swiftc \
    Logic.swift SettingsManager.swift Log.swift GeminiTranscriber.swift StreamingTranscriber.swift TextInjector.swift \
    tests/NetworkTests.swift tests/LiveTests.swift \
    -framework AVFoundation -o build/network-tests

./build/network-tests
