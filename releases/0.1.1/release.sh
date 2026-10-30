#!/bin/bash
# ./release.sh 0.2.0 "one line on what changed"
# Copies the current files into releases/<version>/ (plain folder, not zipped),
# updates VERSION, commits, and tags v<version>.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
v="${1:?usage: ./release.sh <version> [message]}"
msg="${2:-release $v}"
dst="releases/$v"
[ -e "$dst" ] && { echo "$dst already exists"; exit 1; }
mkdir -p "$dst"
cp -R install.sh release.sh README.md CHANGELOG.md device "$dst"/
echo "$v" > VERSION
cp VERSION "$dst"/
git add -A
git commit -q -m "v$v: $msg"
git tag -a "v$v" -m "$msg"
echo "released $v -> $dst (tag v$v)"
