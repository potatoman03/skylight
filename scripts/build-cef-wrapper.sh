#!/usr/bin/env bash
# Builds libcef_dll_wrapper.a, the C++ glue CEFBridge links against.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CEF="$ROOT/Vendor/cef"

if [[ -f "$CEF/build/libcef_dll_wrapper/libcef_dll_wrapper.a" ]]; then
  echo "libcef_dll_wrapper is already built."
  exit 0
fi

cmake -S "$CEF" -B "$CEF/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DPROJECT_ARCH=arm64
ninja -C "$CEF/build" libcef_dll_wrapper
