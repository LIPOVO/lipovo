#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"
destination="${1:-platform=iOS Simulator,name=iPhone 16}"
xcodebuild -project "$project_dir/RavistyRemote.xcodeproj" -scheme RavistyRemote \
  -configuration Debug -destination "$destination" \
  -derivedDataPath "$project_dir/build/TestDerivedData" \
  CODE_SIGNING_ALLOWED=NO test
