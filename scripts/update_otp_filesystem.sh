#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -z "${OTP_KERNEL_SRC:-}" ]]; then
  OTP_KERNEL_DIR="$(erl -noshell -eval 'io:format("~s~n", [code:lib_dir(kernel)]), halt().')"
  OTP_KERNEL_SRC="$OTP_KERNEL_DIR/src"
fi

if [[ -z "${OTP_KERNEL_INCLUDE:-}" ]]; then
  OTP_KERNEL_DIR="$(erl -noshell -eval 'io:format("~s~n", [code:lib_dir(kernel)]), halt().')"
  OTP_KERNEL_INCLUDE="$OTP_KERNEL_DIR/include"
fi

if [[ -z "${OTP_STDLIB_SRC:-}" ]]; then
  OTP_STDLIB_DIR="$(erl -noshell -eval 'io:format("~s~n", [code:lib_dir(stdlib)]), halt().')"
  OTP_STDLIB_SRC="$OTP_STDLIB_DIR/src"
fi

mkdir -p \
  "$ROOT/vendor/otp_kernel_11_0_2/src" \
  "$ROOT/vendor/otp_kernel_11_0_2/include" \
  "$ROOT/vendor/otp_stdlib_8_0_1/src"

chmod u+w \
  "$ROOT/vendor/otp_kernel_11_0_2/src/file.erl" \
  "$ROOT/vendor/otp_kernel_11_0_2/include/file.hrl" \
  "$ROOT/vendor/otp_stdlib_8_0_1/src/filelib.erl" \
  2>/dev/null || true

cp "$OTP_KERNEL_SRC/file.erl" "$ROOT/vendor/otp_kernel_11_0_2/src/file.erl"
cp "$OTP_KERNEL_INCLUDE/file.hrl" "$ROOT/vendor/otp_kernel_11_0_2/include/file.hrl"
cp "$OTP_STDLIB_SRC/filelib.erl" "$ROOT/vendor/otp_stdlib_8_0_1/src/filelib.erl"

chmod u+w \
  "$ROOT/vendor/otp_kernel_11_0_2/src/file.erl" \
  "$ROOT/vendor/otp_kernel_11_0_2/include/file.hrl" \
  "$ROOT/vendor/otp_stdlib_8_0_1/src/filelib.erl"

echo "Updated Hyperlang OTP filesystem sources from:"
echo "  kernel src:     $OTP_KERNEL_SRC"
echo "  kernel include: $OTP_KERNEL_INCLUDE"
echo "  stdlib src:     $OTP_STDLIB_SRC"
echo
echo "New SHA-256 hashes:"
shasum -a 256 \
  "$ROOT/vendor/otp_kernel_11_0_2/src/file.erl" \
  "$ROOT/vendor/otp_kernel_11_0_2/include/file.hrl" \
  "$ROOT/vendor/otp_stdlib_8_0_1/src/filelib.erl"
echo
echo "Update Hyperlang.CompatibilityBaseline and docs/security_specification.md if hashes changed."
