#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -z "${OTP_STDLIB_SRC:-}" ]]; then
  OTP_STDLIB_DIR="$(erl -noshell -eval 'io:format("~s~n", [code:lib_dir(stdlib)]), halt().')"
  OTP_STDLIB_SRC="$OTP_STDLIB_DIR/src"
fi

mkdir -p "$ROOT/vendor/otp_stdlib_8_0_1/src"

chmod u+w \
  "$ROOT/vendor/otp_stdlib_8_0_1/src/io_lib.erl" \
  "$ROOT/vendor/otp_stdlib_8_0_1/src/io_lib_format.erl" \
  "$ROOT/vendor/otp_stdlib_8_0_1/src/io_lib_fread.erl" \
  "$ROOT/vendor/otp_stdlib_8_0_1/src/io_lib_pretty.erl" \
  "$ROOT/src/hyperlang_otp_io_lib.erl" \
  "$ROOT/src/hyperlang_otp_io_lib_format.erl" \
  "$ROOT/src/hyperlang_otp_io_lib_fread.erl" \
  "$ROOT/src/hyperlang_otp_io_lib_pretty.erl" \
  2>/dev/null || true

cp "$OTP_STDLIB_SRC/io_lib.erl" "$ROOT/vendor/otp_stdlib_8_0_1/src/io_lib.erl"
cp "$OTP_STDLIB_SRC/io_lib_format.erl" "$ROOT/vendor/otp_stdlib_8_0_1/src/io_lib_format.erl"
cp "$OTP_STDLIB_SRC/io_lib_fread.erl" "$ROOT/vendor/otp_stdlib_8_0_1/src/io_lib_fread.erl"
cp "$OTP_STDLIB_SRC/io_lib_pretty.erl" "$ROOT/vendor/otp_stdlib_8_0_1/src/io_lib_pretty.erl"

cp "$ROOT/vendor/otp_stdlib_8_0_1/src/io_lib.erl" "$ROOT/src/hyperlang_otp_io_lib.erl"
cp "$ROOT/vendor/otp_stdlib_8_0_1/src/io_lib_format.erl" "$ROOT/src/hyperlang_otp_io_lib_format.erl"
cp "$ROOT/vendor/otp_stdlib_8_0_1/src/io_lib_fread.erl" "$ROOT/src/hyperlang_otp_io_lib_fread.erl"
cp "$ROOT/vendor/otp_stdlib_8_0_1/src/io_lib_pretty.erl" "$ROOT/src/hyperlang_otp_io_lib_pretty.erl"

chmod u+w \
  "$ROOT/vendor/otp_stdlib_8_0_1/src/io_lib.erl" \
  "$ROOT/vendor/otp_stdlib_8_0_1/src/io_lib_format.erl" \
  "$ROOT/vendor/otp_stdlib_8_0_1/src/io_lib_fread.erl" \
  "$ROOT/vendor/otp_stdlib_8_0_1/src/io_lib_pretty.erl" \
  "$ROOT/src/hyperlang_otp_io_lib.erl" \
  "$ROOT/src/hyperlang_otp_io_lib_format.erl" \
  "$ROOT/src/hyperlang_otp_io_lib_fread.erl" \
  "$ROOT/src/hyperlang_otp_io_lib_pretty.erl"

"$ROOT/scripts/rewrite_otp_formatting_modules.sh"

echo "Updated Hyperlang OTP formatting sources from $OTP_STDLIB_SRC"
echo
echo "New SHA-256 hashes:"
shasum -a 256 "$ROOT"/vendor/otp_stdlib_8_0_1/src/io_lib*.erl
echo
echo "Run: scripts/diff_otp_formatting.sh && mix clean && mix test"
