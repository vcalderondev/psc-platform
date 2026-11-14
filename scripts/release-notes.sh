#!/bin/sh
# Release notes for <tag>: its CHANGELOG.md section ("## [x.y.z] - date"), then the
# commits since the previous tag.   scripts/release-notes.sh v1.0.0
set -e
tag=$1; [ -n "$tag" ] || { echo "usage: $0 <tag>"; exit 2; }
cd "$(dirname "$0")/.."
sec=$(awk -v t="[${tag#v}]" '/^## /{p = index($0, t) > 0; next} p' CHANGELOG.md)
[ -n "$sec" ] || { echo "CHANGELOG.md has no section [${tag#v}]" >&2; exit 1; }
printf '%s\n' "$sec"
prev=$(git describe --tags --abbrev=0 "$tag^" 2>/dev/null || true)
echo; echo "### Commits${prev:+ since $prev}"
git log --no-merges --format='- %s (%h)' "${prev:+$prev..}$tag"
