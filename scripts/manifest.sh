#!/usr/bin/env bash
# Train manifest operations. Schema: spec §"The keystone".
set -euo pipefail
op="${1:?usage: manifest.sh init|append-rc|get ...}"; shift
case "$op" in
  init)
    file="$1" version="$2" kind="$3" cutdate="$4"; shift 4
    [ -e "$file" ] && { echo "manifest: $file already exists" >&2; exit 1; }
    yq -n ".version=\"$version\" | .kind=\"$kind\" | .\"cut-date\"=\"$cutdate\" | .status=\"cut\"" > "$file"
    for pair in "$@"; do
      repo="${pair%%=*}" sha="${pair##*=}"
      yq -i ".repos.\"$repo\".\"source-sha\"=\"$sha\"
           | .repos.\"$repo\".\"release-branch\"=\"${kind}/${version}\"
           | .repos.\"$repo\".status=\"branched\"
           | .repos.\"$repo\".rc=[]" "$file"
    done
    ;;
  append-rc)
    file="$1" repo="$2" sha="$3" run="$4" key="$5" val="$6"
    # id-value is interpolated unquoted into the yq expression as a yaml
    # int — anything non-numeric would crash yq with a cryptic lexer error.
    case "$val" in (''|*[!0-9]*) echo "manifest: id-value must be a positive integer, got '$val'" >&2; exit 1;; esac
    # idempotent: skip if this sha+key already recorded
    exists=$(yq ".repos.\"$repo\".rc[] | select(.sha==\"$sha\") | .\"$key\"" "$file")
    if [ -n "$exists" ] && [ "$exists" != "null" ]; then
      echo "manifest: rc entry for $sha already present, skipping"; exit 0
    fi
    yq -i ".repos.\"$repo\".rc += [{\"sha\":\"$sha\",\"run\":\"$run\",\"$key\":$val}]
         | .repos.\"$repo\".status=\"rc-available\"" "$file"
    ;;
  get)
    file="$1" path="$2"
    yq "$path" "$file"
    ;;
  *) echo "manifest: unknown op '$op'" >&2; exit 1 ;;
esac
