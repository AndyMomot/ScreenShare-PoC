#!/bin/bash
# One-time setup on a fresh Mac: fetches build tools into tools/ (gitignored) and generates the Xcode project.
# Needs: Xcode, git, curl, Node.js. Everything else is downloaded here.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p tools
# Go's download names use amd64/arm64 rather than uname's x86_64/arm64.
ARCH=$(uname -m); [ "$ARCH" = "x86_64" ] && GOARCH=amd64 || GOARCH=arm64

command -v node >/dev/null || { echo "Node.js is required for the support page: https://nodejs.org"; exit 1; }
# Fails early with a clear message if no suitable JDK is installed (Gradle needs one for the KMP framework).
scripts/java-home.sh >/dev/null

# XcodeGen generates iosApp/ScreenSharePoC.xcodeproj from iosApp/project.yml.
if ! command -v xcodegen >/dev/null && [ ! -x tools/xcodegen/bin/xcodegen ]; then
  echo "→ downloading XcodeGen"
  curl -sSL -o tools/xcodegen.zip https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip
  unzip -q -o tools/xcodegen.zip -d tools && rm tools/xcodegen.zip
fi
XCODEGEN=$(command -v xcodegen || echo tools/xcodegen/bin/xcodegen)

# LiveKit server: Homebrew's if present, otherwise built from source (no macOS binaries are published).
if ! command -v livekit-server >/dev/null && [ ! -x tools/livekit-server ]; then
  GO=$(command -v go || true)
  if [ -z "$GO" ]; then
    echo "→ downloading Go"
    # The first entry of go.dev's JSON release list is the latest stable version.
    GOVERSION=$(curl -s "https://go.dev/dl/?mode=json" | python3 -c "import json,sys;print(json.load(sys.stdin)[0]['version'])")
    curl -sSL "https://go.dev/dl/$GOVERSION.darwin-$GOARCH.tar.gz" | tar xz -C tools
    GO="$PWD/tools/go/bin/go"
  fi
  echo "→ building LiveKit server (a few minutes, once)"
  # Pinned release tag; GOPATH is kept inside tools/ so nothing is written to the user's home.
  [ -d tools/livekit-src ] || git clone -q --depth 1 --branch v1.13.11 https://github.com/livekit/livekit tools/livekit-src
  (cd tools/livekit-src && CGO_ENABLED=1 GOPATH="$PWD/../gopath" "$GO" build -o ../livekit-server ./cmd/server)
fi

echo "→ generating Xcode project"
"$XCODEGEN" generate --spec iosApp/project.yml --quiet
echo "✓ setup done. Next: ./run.sh, then open iosApp/ScreenSharePoC.xcodeproj"
