#!/usr/bin/env bash
# Bump the DuoDesk version in every place that pins it. Run from the repo root:
#   scripts/bump-version.sh 2.6.0
#
# Touches:
#   mac/package.json
#   windows/package.json
#   linux/package.json
#   ios/package.json
#   android/app/build.gradle.kts    (versionName and derived versionCode)
#   flake.nix                        (currently drifted — this script fixes it)
#   README.md                        (download URLs that embed the version)
#
# The android versionCode is derived from the semver: major*10000 + minor*100 + patch
# (so 2.5.0 -> 20500, 2.6.0 -> 20600, 2.5.1 -> 20501).

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <version>  e.g. $0 2.6.0" >&2
  exit 1
fi

v="$1"
if ! [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]]; then
  echo "error: version '$v' doesn't match MAJOR.MINOR.PATCH[-prerelease]" >&2
  exit 1
fi

core="${v%%-*}"
IFS=. read -r major minor patch <<< "$core"
code=$(( major * 10000 + minor * 100 + patch ))

cd "$(dirname "$0")/.."

bump_json() {
  local path="$1"
  if [ -f "$path" ]; then
    node -e "const fs=require('fs');const p='$path';const j=JSON.parse(fs.readFileSync(p));j.version='$v';fs.writeFileSync(p, JSON.stringify(j, null, 2) + '\n');"
    echo "  bumped $path"
  fi
}

bump_json mac/package.json
bump_json windows/package.json
bump_json linux/package.json
bump_json ios/package.json

# Android: both versionName (semver) and versionCode (integer).
if [ -f android/app/build.gradle.kts ]; then
  tmp=$(mktemp)
  sed -E \
    -e "s/versionCode = [0-9]+/versionCode = $code/" \
    -e "s/versionName = \"[^\"]+\"/versionName = \"$v\"/" \
    android/app/build.gradle.kts > "$tmp"
  mv "$tmp" android/app/build.gradle.kts
  echo "  bumped android/app/build.gradle.kts (versionCode $code)"
fi

# flake.nix — version = "x.y.z";
if [ -f flake.nix ]; then
  tmp=$(mktemp)
  sed -E "s/(version = \")[^\"]+(\";)/\1$v\2/" flake.nix > "$tmp"
  mv "$tmp" flake.nix
  echo "  bumped flake.nix"
fi

# README download URLs: /releases/download/v<old>/DuoDesk-<old>...
if [ -f README.md ]; then
  tmp=$(mktemp)
  # The URLs always carry the version twice: /vX.Y.Z/DuoDesk-X.Y.Z... — one regex catches both.
  sed -E "s#(/releases/download/v)[0-9]+\.[0-9]+\.[0-9]+(/DuoDesk-)[0-9]+\.[0-9]+\.[0-9]+#\1$v\2$v#g" README.md > "$tmp"
  mv "$tmp" README.md
  echo "  bumped README.md download URLs"
fi

echo "done. Review the diff with: git diff"
