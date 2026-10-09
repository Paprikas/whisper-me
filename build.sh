#!/bin/bash
set -e

ARCH="${1:-universal}"
MIN_MACOS="13.0"

echo "🔨 Compiling WhisperMe (target: $ARCH, macOS $MIN_MACOS+)..."

mkdir -p build/WhisperMe.app/Contents/MacOS
mkdir -p build/WhisperMe.app/Contents/Resources

cat << EOF > build/WhisperMe.app/Contents/Info.plist
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>whisper-me</string>
    <key>CFBundleIdentifier</key>
    <string>com.whisperme.app</string>
    <key>CFBundleName</key>
    <string>WhisperMe</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS}</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>WhisperMe requires microphone access for voice transcription.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>WhisperMe uses speech recognition for dictation text input.</string>
</dict>
</plist>
EOF

SWIFT_SOURCES=(
    SettingsManager.swift
    Log.swift
    Logic.swift
    HotKeyManager.swift
    AudioRecorder.swift
    GeminiTranscriber.swift
    OpenRouterTranscriber.swift
    TranscriptionService.swift
    TextInjector.swift
    StreamingTranscriber.swift
    SettingsWindow.swift
    AppDelegate.swift
    main.swift
)

FRAMEWORKS=(
    -framework Speech
    -framework AVFoundation
    -framework Carbon
)

OUTPUT_BIN="build/WhisperMe.app/Contents/MacOS/whisper-me"

case "$ARCH" in
    intel|x86_64)
        echo "📦 Building for Intel (x86_64, macOS $MIN_MACOS Ventura+)..."
        swiftc -O \
            -target x86_64-apple-macosx${MIN_MACOS} \
            "${SWIFT_SOURCES[@]}" \
            "${FRAMEWORKS[@]}" \
            -o "$OUTPUT_BIN"
        ;;
    arm64|apple-silicon)
        echo "📦 Building for Apple Silicon (arm64, macOS $MIN_MACOS+)..."
        swiftc -O \
            -target arm64-apple-macosx${MIN_MACOS} \
            "${SWIFT_SOURCES[@]}" \
            "${FRAMEWORKS[@]}" \
            -o "$OUTPUT_BIN"
        ;;
    universal)
        echo "📦 Building Universal binary (x86_64 + arm64, macOS $MIN_MACOS+)..."
        mkdir -p build/tmp
        swiftc -O \
            -target x86_64-apple-macosx${MIN_MACOS} \
            "${SWIFT_SOURCES[@]}" \
            "${FRAMEWORKS[@]}" \
            -o build/tmp/whisper-me-x86_64
        swiftc -O \
            -target arm64-apple-macosx${MIN_MACOS} \
            "${SWIFT_SOURCES[@]}" \
            "${FRAMEWORKS[@]}" \
            -o build/tmp/whisper-me-arm64
        lipo -create \
            build/tmp/whisper-me-x86_64 \
            build/tmp/whisper-me-arm64 \
            -output "$OUTPUT_BIN"
        rm -rf build/tmp
        ;;
    *)
        echo "❌ Unknown architecture: $ARCH. Available: universal, intel (x86_64), arm64"
        exit 1
        ;;
esac

# Sign with a stable self-signed identity so macOS TCC permissions
# (microphone, accessibility) survive rebuilds. Fallback to ad-hoc.
codesign --force --sign "WhisperMe Dev" --timestamp=none \
    build/WhisperMe.app 2>/dev/null || \
codesign --force --sign - --timestamp=none \
    build/WhisperMe.app 2>/dev/null || \
    echo "⚠️ Code signing failed"

# Also create a direct executable symlink
ln -sf build/WhisperMe.app/Contents/MacOS/whisper-me ./whisper-me-bin

echo "✅ Successfully built! Launch via ./whisper-me-bin or open build/WhisperMe.app"
