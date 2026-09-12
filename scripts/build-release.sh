#!/usr/bin/env bash
# Build foyer's self-contained release binaries with Burrito.
#
# This is the real release-build logic. GitHub Actions only orchestrates it
# (checkout, install toolchain, call this, upload). Run it locally the same way
# CI does:
#
#   scripts/build-release.sh              # build every target into dist/
#   scripts/build-release.sh linux_amd64  # build one target
#
# Output: dist/foyer-<target> for each built target, plus dist/SHA256SUMS.
#
# Requirements (Burrito 1.0): elixir, erlang, zig 0.15.x, xz, 7z (only for
# Windows targets, which foyer does not build). Cross-compiling Linux and macOS
# targets works from a Linux or macOS host.
set -euo pipefail

cd "$(dirname "$0")/.."

OUT_DIR="dist"
BURRITO_OUT="burrito_out"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Fail early and clearly if a required tool is missing, rather than deep inside
# a mix release with a cryptic message.
require() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }
require elixir
require mix
require zig
require xz

# An optional single-target argument maps to Burrito's BURRITO_TARGET env var.
if [ "$#" -gt 0 ]; then
  export BURRITO_TARGET="$1"
  log "building single target: $BURRITO_TARGET"
else
  log "building all targets"
fi

log "fetching deps (MIX_ENV=prod)"
# Burrito is a :prod-only dependency (see mix.exs), so deps must be fetched in
# the prod environment or `mix release` below fails with unchecked deps.
MIX_ENV=prod mix deps.get

log "running mix release (MIX_ENV=prod)"
rm -rf "$BURRITO_OUT"
MIX_ENV=prod mix release

[ -d "$BURRITO_OUT" ] || die "burrito produced no $BURRITO_OUT directory"

log "collecting artifacts into $OUT_DIR/"
mkdir -p "$OUT_DIR"
# Burrito names outputs foyer_<target> (and foyer_<target>.exe on Windows).
# Republish them as foyer-<target> so the release assets read naturally.
shopt -s nullglob
found=0
for bin in "$BURRITO_OUT"/foyer_*; do
  base="$(basename "$bin")"
  target="${base#foyer_}"
  dest="$OUT_DIR/foyer-${target}"
  cp "$bin" "$dest"
  chmod +x "$dest"
  found=1
  log "  $dest"
done
[ "$found" = 1 ] || die "no foyer_* binaries found in $BURRITO_OUT"

log "writing checksums"
( cd "$OUT_DIR" && sha256sum foyer-* > SHA256SUMS )
cat "$OUT_DIR/SHA256SUMS"

log "done"
