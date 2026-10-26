#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -z "${OTP_STDLIB_SRC:-}" ]]; then
  OTP_STDLIB_DIR="$(erl -noshell -eval 'io:format("~s~n", [code:lib_dir(stdlib)]), halt().')"
  OTP_STDLIB_SRC="$OTP_STDLIB_DIR/src"
fi

cp "$OTP_STDLIB_SRC/erl_scan.erl" "$ROOT/vendor/otp_stdlib_8_0_1/erl_scan.erl"
cp "$OTP_STDLIB_SRC/erl_parse.erl" "$ROOT/vendor/otp_stdlib_8_0_1/erl_parse.erl"
cp "$OTP_STDLIB_SRC/erl_parse.yrl" "$ROOT/vendor/otp_stdlib_8_0_1/erl_parse.yrl"

cp "$ROOT/vendor/otp_stdlib_8_0_1/erl_scan.erl" "$ROOT/src/hyperlang_otp_scan.erl"
cp "$ROOT/vendor/otp_stdlib_8_0_1/erl_parse.erl" "$ROOT/src/hyperlang_otp_parse.erl"
chmod u+w "$ROOT/src/hyperlang_otp_scan.erl" "$ROOT/src/hyperlang_otp_parse.erl"

perl -0pi -e 's/-module\(erl_scan\)\./-module(hyperlang_otp_scan)./' \
  "$ROOT/src/hyperlang_otp_scan.erl"
perl -0pi -e 's/-module\(erl_parse\)\./-module(hyperlang_otp_parse)./' \
  "$ROOT/src/hyperlang_otp_parse.erl"

if [[ -s "$ROOT/patches/hyperlang_otp_scan.patch" ]]; then
  patch "$ROOT/src/hyperlang_otp_scan.erl" "$ROOT/patches/hyperlang_otp_scan.patch"
fi

if [[ -s "$ROOT/patches/hyperlang_otp_parse.patch" ]]; then
  patch "$ROOT/src/hyperlang_otp_parse.erl" "$ROOT/patches/hyperlang_otp_parse.patch"
fi

echo "Updated Hyperlang OTP frontend from $OTP_STDLIB_SRC"
echo "Run: mix clean && mix test && scripts/diff_otp_frontend.sh"
