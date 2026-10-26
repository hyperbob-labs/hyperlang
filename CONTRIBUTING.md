# Contributing

## Toolchain

Hyperlang pins its stdlib allowlist to Erlang/OTP 29 and needs Elixir 1.20
or later. `mise.toml` selects the versions used for development.

## Tests

```bash
mix test
```

The isolation stress and finding probes in `test/isolation` are opt-in. They
start peer BEAMs and take several minutes:

```bash
mix test test/isolation --include isolation_stress --include isolation_finding
```

Set `ISOLATION_EVIDENCE_DIR` to keep their measurement records.

Before sending a change, run:

```bash
mix compile --warnings-as-errors
mix format --check-formatted
mix test
```

## Vendored OTP sources

`vendor/` holds unmodified Erlang/OTP reference sources. `src/` and
`priv/guest_lib/` hold the derived files that Hyperlang compiles and runs, and
`patches/` records the scanner and parser changes. `NOTICE` lists every file
and its OTP version. The scripts in `scripts/` keep these in step:

| Script | Purpose |
| --- | --- |
| `update_otp_frontend.sh` | Regenerate `src/hyperlang_otp_scan.erl` and `src/hyperlang_otp_parse.erl` from the vendored sources and the patches. |
| `diff_otp_frontend.sh` | Show the scanner and parser diff against the vendored sources; `--check` verifies that it matches `patches/`. The test suite runs the check. |
| `update_otp_filesystem.sh` | Refresh the vendored `file.erl`, `file.hrl` and `filelib.erl` from the installed OTP and print their SHA-256 hashes. |
| `update_otp_formatting.sh` | Refresh the vendored `io_lib*` sources and regenerate the renamed `src/hyperlang_otp_io_lib*.erl` modules. |
| `rewrite_otp_formatting_modules.sh` | Rename the `io_lib*` modules and their cross-references; used by the two formatting scripts. |
| `diff_otp_formatting.sh` | Verify that the `src/hyperlang_otp_io_lib*.erl` modules equal the vendored sources after the rename. |

When a vendored hash changes, update `Hyperlang.CompatibilityBaseline`
(`test/support/compatibility_baseline.ex`) and the hash table in
`doc/SECURITY_SPECIFICATION.md`.

## Benchmark

`bench/eval_hot_path.exs` measures the per-call cost of a trivial run with
limits disabled and armed: `mix run bench/eval_hot_path.exs`
(`HYPERLANG_BENCH_ITERATIONS` sets the iteration count).
