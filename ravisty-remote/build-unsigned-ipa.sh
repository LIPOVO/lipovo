#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"
build_dir="$project_dir/build"
mkdir -p "$build_dir"
xcodebuild -project "$project_dir/RavistyRemote.xcodeproj" \
  -scheme RavistyRemote -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' -derivedDataPath "$build_dir/DerivedData" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
app_path="$build_dir/DerivedData/Build/Products/Release-iphoneos/RavistyRemote.app"
test -d "$app_path"
stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/ravisty-ipa.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
mkdir -p "$stage_dir/Payload"
ditto "$app_path" "$stage_dir/Payload/RavistyRemote.app"
ipa_path="$build_dir/RavistyRemote-unsigned.ipa"
(cd "$stage_dir" && ditto -c -k --keepParent Payload "$ipa_path")
printf 'Unsigned IPA: %s\n' "$ipa_path"
printf 'AltStore must sign this file before it can be installed on an iPhone.\n'
