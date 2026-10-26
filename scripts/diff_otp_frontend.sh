#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

module_renamed_baseline() {
  local tmpdir="$1"

  cp "$ROOT/vendor/otp_stdlib_8_0_1/erl_scan.erl" "$tmpdir/hyperlang_otp_scan.erl"
  cp "$ROOT/vendor/otp_stdlib_8_0_1/erl_parse.erl" "$tmpdir/hyperlang_otp_parse.erl"

  perl -0pi -e 's/-module\(erl_scan\)\./-module(hyperlang_otp_scan)./' \
    "$tmpdir/hyperlang_otp_scan.erl"
  perl -0pi -e 's/-module\(erl_parse\)\./-module(hyperlang_otp_parse)./' \
    "$tmpdir/hyperlang_otp_parse.erl"
}

if [[ "${1:-}" == "--check" ]]; then
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT
  module_renamed_baseline "$tmpdir"

  diff -u --label hyperlang_otp_scan.baseline --label src/hyperlang_otp_scan.erl \
    "$tmpdir/hyperlang_otp_scan.erl" "$ROOT/src/hyperlang_otp_scan.erl" \
    > "$tmpdir/hyperlang_otp_scan.patch" || true
  diff -u --label hyperlang_otp_parse.baseline --label src/hyperlang_otp_parse.erl \
    "$tmpdir/hyperlang_otp_parse.erl" "$ROOT/src/hyperlang_otp_parse.erl" \
    > "$tmpdir/hyperlang_otp_parse.patch" || true

  cmp -s "$tmpdir/hyperlang_otp_scan.patch" "$ROOT/patches/hyperlang_otp_scan.patch"
  cmp -s "$tmpdir/hyperlang_otp_parse.patch" "$ROOT/patches/hyperlang_otp_parse.patch"
  exit 0
fi

diff -u "$ROOT/vendor/otp_stdlib_8_0_1/erl_scan.erl" "$ROOT/src/hyperlang_otp_scan.erl" || true
diff -u "$ROOT/vendor/otp_stdlib_8_0_1/erl_parse.erl" "$ROOT/src/hyperlang_otp_parse.erl" || true
