#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
framework_dir="${FLUTTER_MACOS_FRAMEWORK_DIR:-build/macos/Build/Products/Debug}"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/note-agent-credentials.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT
xcrun swiftc -swift-version 5 -F "$framework_dir" -framework FlutterMacOS \
  -Xlinker -rpath -Xlinker "$(cd "$framework_dir" && pwd)" \
  macos/Runner/SecureCredentials.swift tool/credential_channel_probe.swift \
  -o "$probe_dir/probe"
"$probe_dir/probe"
