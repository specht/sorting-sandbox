#!/usr/bin/env bash
# ./run without a Dart SDK: downloads the app for this version once and starts
# it (here from a local stand-in for the GitHub release).
#   bash test/precompiled_run.test.sh
set -euo pipefail
project="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/app/tool" "$work/app/lib" "$work/releases"
cp "$project/run" "$work/app/"
cd "$work/app"
echo 'void main() {}' > tool/host.dart
echo '// lib' > lib/a.dart
printf 'name: x\n' > pubspec.yaml
printf '# lock\n' > pubspec.lock
git init -q . && git add . && git -c user.name=t -c user.email=t@t commit -q -m app
key="$(git ls-tree HEAD tool lib pubspec.yaml pubspec.lock | git hash-object --stdin)"
case "$(uname -s)" in Linux) os=linux ;; Darwin) os=macos ;; esac
case "$(uname -m)" in x86_64|amd64) arch=x64 ;; *) arch=arm64 ;; esac
mkdir -p "$work/releases/host-${key:0:16}"
printf '#!/bin/sh\necho "precompiled app $*"\n' > "$work/releases/host-${key:0:16}/sandbox-host-$os-$arch"

export SANDBOX_PRECOMPILED=1 SANDBOX_DOWNLOADS="file://$work/releases"
mkdir -p runtime/host/host-0000000000000000
out="$(./run --no-open 2>/dev/null)"
[[ "$out" == *"precompiled app --no-open"* ]] || { echo "unexpected: $out" >&2; exit 1; }
[[ -x "runtime/host/host-${key:0:16}/sandbox-host-$os-$arch" ]]
[[ ! -e runtime/host/host-0000000000000000 ]] || { echo 'old version kept' >&2; exit 1; }
rm -rf "$work/releases"
[[ "$(./run 2>/dev/null)" == *"precompiled app"* ]] || { echo 'not cached' >&2; exit 1; }

echo '// changed' >> lib/a.dart
git -c user.name=t -c user.email=t@t commit -q -am change
if ./run > /dev/null 2> err.txt; then echo 'started a missing version' >&2; exit 1; fi
grep -q 'Download failed' err.txt && grep -q 'Dart SDK' err.txt
echo 'PASS: without Dart, ./run downloads the app for this version once, then starts it offline.'
