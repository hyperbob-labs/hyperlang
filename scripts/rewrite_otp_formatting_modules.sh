#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="${1:-$ROOT/src}"

perl -0pi -e 's/-module\(io_lib\)\./-module(hyperlang_otp_io_lib)./g; s/\bio_lib_format:/hyperlang_otp_io_lib_format:/g; s/\bio_lib_fread:/hyperlang_otp_io_lib_fread:/g; s/\bio_lib_pretty:/hyperlang_otp_io_lib_pretty:/g; s/Modules = \[io_lib_format, io_lib_pretty, string, unicode\]/Modules = [hyperlang_otp_io_lib_format, hyperlang_otp_io_lib_pretty, string, unicode]/g' \
  "$TARGET_DIR/hyperlang_otp_io_lib.erl"

perl -0pi -e 's/-module\(io_lib_format\)\./-module(hyperlang_otp_io_lib_format)./g; s/\bio_lib:/hyperlang_otp_io_lib:/g; s/\bio_lib_pretty:/hyperlang_otp_io_lib_pretty:/g' \
  "$TARGET_DIR/hyperlang_otp_io_lib_format.erl"

perl -0pi -e 's/-module\(io_lib_fread\)\./-module(hyperlang_otp_io_lib_fread)./g; s/\bio_lib:/hyperlang_otp_io_lib:/g' \
  "$TARGET_DIR/hyperlang_otp_io_lib_fread.erl"

perl -0pi -e 's/-module\(io_lib_pretty\)\./-module(hyperlang_otp_io_lib_pretty)./g; s/\bio_lib:/hyperlang_otp_io_lib:/g' \
  "$TARGET_DIR/hyperlang_otp_io_lib_pretty.erl"
