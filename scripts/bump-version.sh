#!/usr/bin/env bash
# Read or bump the marketing version of a convos app checkout.
# Layouts: convos-client (android/gradle.properties VERSION_NAME),
#          convos-ios   (Convos.xcodeproj/project.pbxproj MARKETING_VERSION).
set -euo pipefail

mode="${1:?usage: bump-version.sh read|bump <repo-dir> [new-version]}"
dir="${2:?usage: bump-version.sh read|bump <repo-dir> [new-version]}"

gradle_props="$dir/android/gradle.properties"
pbxproj="$dir/Convos.xcodeproj/project.pbxproj"

if [ -f "$gradle_props" ]; then
  layout=android
elif [ -f "$pbxproj" ]; then
  layout=ios
else
  echo "bump-version: no known version file under $dir" >&2; exit 1
fi

read_version() {
  case "$layout" in
    android) sed -n 's/^VERSION_NAME=\(.*\)$/\1/p' "$gradle_props" ;;
    ios)     sed -n 's/.*MARKETING_VERSION = \([0-9][0-9.]*\);.*/\1/p' "$pbxproj" | sort -u ;;
  esac
}

case "$mode" in
  read)
    v=$(read_version)
    # ios: multiple entries must agree
    if [ "$(echo "$v" | wc -l)" -ne 1 ]; then
      echo "bump-version: inconsistent versions found:" >&2; echo "$v" >&2; exit 1
    fi
    echo "$v"
    ;;
  bump)
    new="${3:?bump needs <new-version>}"
    echo "$new" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "bump-version: bad version '$new'" >&2; exit 1; }
    case "$layout" in
      android) sed -i "s/^VERSION_NAME=.*/VERSION_NAME=$new/" "$gradle_props" ;;
      ios)     sed -i "s/MARKETING_VERSION = [0-9][0-9.]*;/MARKETING_VERSION = $new;/g" "$pbxproj" ;;
    esac
    [ "$(read_version | sort -u)" = "$new" ] || { echo "bump-version: post-bump verify failed" >&2; exit 1; }
    ;;
  *) echo "bump-version: unknown mode '$mode'" >&2; exit 1 ;;
esac
