#!/bin/zsh
# Generates the Xcode project, runs the core tests and builds the app. Log: build.log
cd "$(dirname "$0")"
exec > build.log 2>&1
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
echo "=== $(date) ==="
sw_vers
xcodebuild -version
swift --version
echo "=== xcodegen ==="
if ! command -v xcodegen >/dev/null; then brew install xcodegen; fi
xcodegen generate || { echo "XCODEGEN_FAILED"; exit 1; }
echo "=== swift test (CutterCore) ==="
(cd CutterCore && swift test 2>&1); echo "SWIFT_TEST_EXIT=$?"
echo "=== swift build (app type-check) ==="
swift build 2>&1 | grep -E "error:|warning:|Compiling|Build complete" | sort -u; echo "SWIFT_BUILD_EXIT=${pipestatus[1]}"
echo "=== xcodebuild ==="
xcodebuild -project Recorte.xcodeproj -scheme Recorte -configuration Debug -derivedDataPath build/DerivedData CODE_SIGN_IDENTITY="" CODE_SIGNING_ALLOWED=NO build > xcodebuild.log 2>&1
echo "XCODEBUILD_EXIT=$?"
grep -E "error:|warning:|BUILD " xcodebuild.log | grep -v "^$" | sort -u
rm -rf Recorte.app; cp -R build/DerivedData/Build/Products/Debug/Recorte.app ./Recorte.app && echo "APP_COPIED"
echo "=== done ==="
