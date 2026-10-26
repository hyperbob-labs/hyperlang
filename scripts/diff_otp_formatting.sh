#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cp "$ROOT/vendor/otp_stdlib_8_0_1/src/io_lib.erl" "$TMP/hyperlang_otp_io_lib.erl"
cp "$ROOT/vendor/otp_stdlib_8_0_1/src/io_lib_format.erl" "$TMP/hyperlang_otp_io_lib_format.erl"
cp "$ROOT/vendor/otp_stdlib_8_0_1/src/io_lib_fread.erl" "$TMP/hyperlang_otp_io_lib_fread.erl"
cp "$ROOT/vendor/otp_stdlib_8_0_1/src/io_lib_pretty.erl" "$TMP/hyperlang_otp_io_lib_pretty.erl"

"$ROOT/scripts/rewrite_otp_formatting_modules.sh" "$TMP"

diff -u "$TMP/hyperlang_otp_io_lib.erl" "$ROOT/src/hyperlang_otp_io_lib.erl"
diff -u "$TMP/hyperlang_otp_io_lib_format.erl" "$ROOT/src/hyperlang_otp_io_lib_format.erl"
diff -u "$TMP/hyperlang_otp_io_lib_fread.erl" "$ROOT/src/hyperlang_otp_io_lib_fread.erl"
diff -u "$TMP/hyperlang_otp_io_lib_pretty.erl" "$ROOT/src/hyperlang_otp_io_lib_pretty.erl"

echo "Hyperlang OTP formatting modules match vendored sources after expected rewrites."
