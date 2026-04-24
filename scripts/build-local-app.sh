#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/PongBar.xcodeproj"
SCHEME="PongBar"
DERIVED_DATA_PATH="$ROOT_DIR/build"
PRODUCTS_DIR="$DERIVED_DATA_PATH/Build/Products/Release"
APP_NAME="PongBar.app"
APP_PATH="$PRODUCTS_DIR/$APP_NAME"
DIST_DIR="$ROOT_DIR/dist"
DIST_APP_PATH="$DIST_DIR/$APP_NAME"

if [[ ! -d "$PROJECT_PATH" ]]; then
    echo "Could not find project at: $PROJECT_PATH" >&2
    exit 1
fi

echo "Building $APP_NAME in Release configuration..."
xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CODE_SIGNING_ALLOWED=NO \
    build \
    > /tmp/pongbar-build.log 2>&1

if [[ ! -d "$APP_PATH" ]]; then
    echo "Build finished, but app was not found at: $APP_PATH" >&2
    echo "See /tmp/pongbar-build.log for details." >&2
    tail -n 80 /tmp/pongbar-build.log >&2 || true
    exit 1
fi

mkdir -p "$DIST_DIR"
rm -rf "$DIST_APP_PATH"
cp -R "$APP_PATH" "$DIST_APP_PATH"

echo "Created local app bundle:"
echo "$DIST_APP_PATH"
echo
echo "Run it with:"
echo "open \"$DIST_APP_PATH\""
