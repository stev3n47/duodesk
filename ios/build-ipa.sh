#!/usr/bin/env bash
# Build an unsigned ad-hoc IPA for DuoDesk iOS.
# Users resign it with Signulous / AltStore / Sideloadly / Xcode (see README.md).
#
# Deps: Xcode 16+, xcodegen (`brew install xcodegen`). Runs on macOS only.

set -euo pipefail

cd "$(dirname "$0")"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen is required (brew install xcodegen)" >&2
  exit 1
fi

version=$(node -p "require('./package.json').version" 2>/dev/null || \
          python3 -c "import json; print(json.load(open('package.json'))['version'])")

echo "==> Generating DuoDesk.xcodeproj"
xcodegen generate

mkdir -p dist DerivedData

echo "==> Archiving (unsigned)"
xcodebuild \
  -project DuoDesk.xcodeproj \
  -scheme DuoDesk \
  -configuration Release \
  -archivePath "DerivedData/DuoDesk.xcarchive" \
  -destination 'generic/platform=iOS' \
  -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$version" \
  clean archive

echo "==> Hand-rolling IPA (no codesign)"
rm -rf DerivedData/Payload
mkdir -p DerivedData/Payload
cp -R "DerivedData/DuoDesk.xcarchive/Products/Applications/DuoDesk.app" DerivedData/Payload/
(
  cd DerivedData
  zip -qry "../dist/DuoDesk-$version.ipa" Payload
)

echo "==> dist/DuoDesk-$version.ipa"
ls -lh "dist/DuoDesk-$version.ipa"
