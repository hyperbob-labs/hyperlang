# Hyperlang compared with other BEAM isolation approaches

This document compares Hyperlang with the other ways to run untrusted or
partly trusted code on, or next to, the BEAM. Every claim below rests on a
probe or benchmark we ran, or on a cited primary source at a stated version.
Where we could not check a claim, we say so.

## Summary

- **Same VM, ordinary Erlang, no ambient authority.** A guest is Erlang
  source. Hyperlang compiles it through its own verifier into a BEAM module
  that can only call what the program declares. Every authority probe we
  ported (`apply`, external funs, computed calls, higher-order laundering,
  `self()`, `list_to_atom`) was rejected at compile time.
- **Compute.** Guest code is compiled BEAM code. A guest `fib(25)` took
  0.35 ms, the same as native Erlang in a peer node or OS process (0.33 to
  0.38 ms). wasmex took 0.68 ms; the interpreted approaches took 85 to
  275 ms.
- **Memory.** An idle guest actor added 23 KiB of resident memory: the
  program is a shared literal, so actors only reference it. A Rust wasmex
  instance added 89 KiB, a Luerl state 71 KiB, a Dune session 109 KiB and
  `erl_eval` bindings 23 KiB. A peer node or an OS `erl` process added 74 to
  76 MiB.
- **Noisy neighbours.** Next to 16 CPU-bound tenants, a latency-class
  victim's p99 rose 1.6x (54 to 89 µs) with `Hyperlang.Scope`, and 3.6x
  without scope controls. In Luerl it rose 3.0x, in `erl_eval` 7.4x and in
  Dune 36x. A victim in its own peer node rose 1.1x.
- **Tenant start.** A new tenant of a compiled program answered in 0.05 ms.
  Luerl took 0.03 ms, wasmex 0.08 ms and Dune 0.41 ms. A peer node or OS
  process took 111 to 123 ms to boot. Compiling a small program from source
  is a separate one-time step of about 17 ms.
- **Cost.** Each call into a guest has a fixed cost: about 21 µs for a
  `run/4` in the caller, 29 µs for an actor call and 45 µs for a `run/4`
  worker on this host. Workloads made of many tiny calls run faster in
  Luerl's in-caller mode or in wasmex.

All numbers come from one 16-core Apple Silicon host. Other jobs shared it,
with a load average of 6 to 32 during the final runs. The BEAM ran with four
schedulers (`+S 4:4`). The [method](#benchmark-method) and
[limitations](#limitations-of-this-comparison) sections give the detail.

## The common wisdom, and where it comes from

The usual position is that the BEAM cannot isolate untrusted code in the same
VM. The sources are clear and official:

- [Erlang/OTP Secure Coding Guidelines](https://www.erlang.org/doc/system/secure_coding.html)
  (OTP 29, "What is not protected against"): "All loaded code is assumed to be trusted. There is no built-in
  sand-boxing mechanism for running untrusted Erlang code." and "Excessive
  resource usage is not prevented by default."
- EEF Security Working Group,
  [*Sandboxing*](https://security.erlef.org/secure_coding_and_deployment_hardening/sandboxing)
  (erlef/security-wg at
  `e7f03719`, `docs/secure_coding_and_deployment_hardening/sandboxing.md`):
  "It is therefore not possible to isolate 'untrusted' processes in some sort
  of sandbox." Its advice is "Use an embedded language runtime, such as Lua",
  and not to use `Code.eval_string/1,2,3` on untrusted input.
- EEF, *Atom exhaustion*: the atom table holds "a default of 1.048.576
  entries. If an attempt is made to add a new value while the table is at
  capacity, the virtual machine crashes." OTP's memory guide adds: "The atom
  table is not garbage-collected."
- Robert Virding, Elixir Forum, 2017,
  ["How to create a sandbox to run untrusted code modules"](https://elixirforum.com/t/how-to-create-a-sandbox-to-run-untrusted-code-modules/4142): "It is basically impossible to sandbox an
  erlang/elixir system if you allow it to run untested code", and "the only
  safe way is to interpret/run another language". In the same thread, Michał
  Muskała wrote: "OS-process-level sandboxing is definitely a much better
  idea."
- Bram Verburg (EEF Security WG), in the
  [Dune announcement thread](https://elixirforum.com/t/dune-sandbox-for-elixir/42480): "Personally
  I would stick with Luerl until the BEAM offers a native, runtime sandboxing
  feature".
- Dune's own README (v0.3.18): "Dune cannot offer strong security guarantees,
  and should not be considered a sufficient security layer by itself." and
  "Due to how the Erlang VM works, an attacker able to escape the sandbox
  could get full access to the VM without restriction."
- Erlang distribution gives no isolation between nodes. The OTP guidelines
  say: "All nodes connected through Erlang distribution are assumed to be
  trusted, and have unrestricted access to all other connected systems."

### What is true in it

These parts of the wisdom are correct, and Hyperlang does not change them:

- **Shared schedulers.** All processes in one VM share the scheduler threads.
  A busy tenant takes CPU time from others unless something admits and
  prioritises work.
- **Shared allocators and garbage collection.** Heap pressure in one tenant
  costs time in others.
- **One atom table.** It is global, finite and never collected.
- **One code server.** Code loading is serialised.
- **Native work.** A long non-yielding BIF or NIF cannot be preempted.
- **Loaded code is trusted.** Any BEAM module, once loaded, can do anything.

### What Hyperlang changes

The wisdom assumes that guest code becomes ordinary loaded code, or that it
runs in an interpreter that needs hooks to stop it. Hyperlang does neither:

- The guest never loads its own code. Hyperlang loads a module that its own
  code generator wrote. That generator can only emit calls to a closed set of
  functions (see [Isolation by lowering](#isolation-by-lowering)).
- Every atom a guest can cause comes from a fixed set bounded by host limits.
  Pool atoms are created on first use of each index, and the OTP compiler
  only ever creates names from a fixed set, because codegen lifts every fun,
  comprehension and receive into a fixed-name function. 1,000 distinct
  adversarial programs added no atoms after warm-up.
- Every run has its own reduction, heap and wall limits. Scopes add
  admission and priority classes on top.
- Every term that crosses the boundary is sanitized. Pids, ports, references
  and funs do not cross.

### Residual effects that remain

The security specification lists these as Known Limitations. They are why
hosts that need hard latency or memory bounds against hostile tenants add OS
or node isolation:

- Guests share schedulers, allocators, the garbage collector and the code
  server.
- Heap-pressure latency is bounded by the scope's churn rate. With 16
  heap-pressure tenants in churn-limited background scopes, a victim's p99
  stays within three times its unloaded p99 (tested; 1.19x-1.67x measured).
  With churn enforcement disabled it rose to about 9x.
- Some native calls do not yield. A 32 MB `binary:copy/2` ran for about
  163 ms before it could be stopped.
- CPU, heap and churn enforcement is sampled and allows short bursts.
- Wall deadlines and timers are not hard real time.

## Why the guest language is Erlang

Elixir compilation runs Elixir code. Module bodies, module attributes, macro
expansion (`defmacro`, `require`), `use` and its `__using__/1` callback, and
`@before_compile` hooks all execute while the module compiles. Nothing has to
be called for that code to run.

We checked each form on Elixir 1.20.0 (`probes/elixir_compile_time.exs` in
the comparison harness). Each source wrote a file during
`Code.compile_string/1`, before any function was called:

| Construct | Ran code at compile time |
| --- | --- |
| Module body | yes |
| Module attribute value | yes |
| Macro expansion | yes |
| `@before_compile` hook | yes |
| `use` / `__using__/1` | yes |

A sandbox that checks Elixir source or its AST from outside has two choices.
It can forbid these constructs, or it can run untrusted compile-time code
with the host's authority, with no time or memory bound. Dune 0.3.18 takes
the first path. Our probes show that it rejects `defmacro`, `quote`, `use`,
`require` and module attributes. It also does not create real modules: its
`defmodule` is simulated with maps of anonymous functions, and the sanitized
AST is evaluated with `Code.eval_quoted_with_env/3` (`lib/dune/eval.ex:93`).

Erlang source has no user-defined code that runs at compile time.
Hyperlang's front end does not run the preprocessor (`epp`). It expands one
macro, `?MODULE`, by token substitution (`lib/hyperlang/otp_frontend.ex`,
`expand_module_macro/1`). It admits these attributes: `-module`, `-export`
(both inert), `-record`, `-behaviour`, `-vsn`, `-doc`, `-moduledoc`,
`-spec`, `-callback` and `-optional_callbacks`. It rejects every other
attribute. Our probes confirmed the rejections: `-include`, `-define`,
`-compile({parse_transform, ...})`, `-on_load` and `-nifs` all fail at
`program/1` as parse errors, and so does `?LINE`.

The compile itself is metered. The whole parse, verify, code generation and
OTP compile path runs in one worker. That worker is bounded by a reduction
budget (`max_compile_reductions`, 200,000,000 by default), a wall-clock
backstop and a heap cap. Reductions do not depend on host load, so a program
is admitted or rejected the same way on an idle host and on a busy one.

### The sound path to sandboxed Elixir

The sound way to sandbox Elixir source is to run the unchanged Elixir
compiler inside the isolate. Macro expansion is then guest execution. The
same reduction, heap and wall limits that bound any run then bound the
compile, so a compile bomb dies by budget. Hyperlang provides the substrate
this needs: metered guest execution, a bounded atom universe and
capability-scoped surfaces.

Such an effort needs three things from the host. First, the OTP surfaces
that the Elixir compiler uses, such as the code server, ETS and file reads,
exposed as Hyperlang capabilities. Second, atom creation routed through a
bounded encoder. Third, loading of the compiler's output through Hyperlang's
verified code generation. Hyperlang does not include an Elixir guest
compiler. If you want to work on one, see [`CONTRIBUTING.md`](../CONTRIBUTING.md).

## Isolation by lowering

Hyperlang enforces isolation in the compiler front end. It does not apply
surface checks to source text. The pipeline (`lib/hyperlang/compiler.ex`) is:

1. **Parse.** A vendored, renamed copy of OTP's `erl_scan` and `erl_parse`
   reads the source. Its atom-producing paths are patched so that names stay
   binaries. Parsing creates no atoms.
2. **Lower to SafeCore.** The parsed forms become Hyperlang's own IR.
   Unsupported forms are errors.
3. **Verify** (`lib/hyperlang/verifier.ex`) over the whole IR: function and
   record limits, guard-only expressions in guards, and record and variable
   rules.
4. **Classify** (`lib/hyperlang/classifier.ex`). Every call becomes exactly
   one kind: a local call, a call to a declared binding export, a call to an
   allowlisted stdlib MFA (`lib/hyperlang/stdlib_allowlist.ex`), or a
   Hyperlang-owned surface. The last clause rejects everything else ("remote
   call M:F/A is not declared"). Dynamic `M:F(...)`, `apply/2,3` and external
   funs are errors. The only dynamic dispatch is source-snapshot `apply`,
   which dispatches over a candidate set fixed at compile time.
5. **Verify again** after classification.
6. **Generate code** (`lib/hyperlang/codegen.ex`). Each call becomes a call
   into a Hyperlang runtime wrapper, which sanitizes arguments and results
   (`lib/hyperlang/terms.ex`), or a direct call to a function in a small,
   fixed set of pure stdlib functions. Receive clauses are wrapped in a
   message envelope. Atoms are mapped onto the program's pooled universe.
7. **Check the generated forms** (`Codegen.verify_generated_forms/2`). Every
   call in the output must pass one positive gate,
   `generated_call_allowed?/3` in `lib/hyperlang/stdlib.ex`. Unknown tuple shapes,
   dynamic calls, `!`, bare receives and external funs are errors
   (`generated_form_verify`).
8. **Compile and load the generated module only.**
   `compile:noenv_forms/2` runs on Hyperlang's own forms in the
   reduction-bounded worker. The result is loaded into a code slot.

The generated BEAM code therefore cannot express a call outside the
program's closed call graph. This holds even if an earlier stage has a bug,
because step 7 checks the output against an allowlist, not the input.

Two results from the sandbox suite show why this matters:

- **Guard bodies (fix G1).** The verifier once accepted `fun`, `try`,
  `case`, `if` and comprehensions inside guards. In one fuzzed program
  (grammar seed 364), a raw `filename:basename/1` call came out of a fun in a
  guard. `filename:*` calls are only allowed through a Hyperlang wrapper, and
  this one had been emitted without it. The generated-form gate (step 7)
  rejected it before any code loaded. In 36 other seeds, the OTP compiler
  rejected the output. A check on the source surface would have seen an
  allowlisted stdlib call and passed it. The verifier now rejects these forms
  itself.
- **Fuzzing.** Grammar and mutation fuzzing produced no program that crashed
  the host, returned a pid, port, ref or fun, or escaped the fault taxonomy.

### What the other approaches enforce, and where

| Approach | Where enforcement happens | Mechanism (source) |
| --- | --- | --- |
| Hyperlang | Compile time over the full IR, then a positive gate over the generated forms | Lowering plus a closed call graph (above) |
| Dune 0.3.18 | Parse time, then run time | Parses with an atom encoder, rewrites the AST against an allowlist, and routes dynamic calls through `Dune.Shims.Kernel.safe_apply/4`, which checks `allowlist.fun_status/3` at run time (`lib/dune/shims/kernel.ex:62`). Evaluates the sanitized AST with `Code.eval_quoted_with_env/3`, so it interprets the code and does not compile it. |
| `erl_eval` with function handlers | Run time | The non-local function handler is an interpreter hook. The OTP docs state that calls to funs created by `fun ... end` are hidden from it. Our probe found that it also does not see an external fun such as `fun os:cmd/1`, so `F("...")` and `lists:map(fun os:cmd/1, ...)` ran `os:cmd`. |
| Luerl 1.5.1 | Run time | The guest is Lua, interpreted in Erlang. `luerl_sandbox` overwrites a fixed list of dangerous globals with the value `sandboxed` (`src/luerl_sandbox.erl:48-65`). The host decides which Erlang functions to expose. |
| safeish 0.5.0 | Load time | A BEAM bytecode verifier with call and function-literal allowlists. Its README says "NOT FOR PRODUCTION USE". Bounty exploits were merged as test cases (PRs #1 to #4, #7 and #9). No longer maintained. |
| wasmex 0.15.1 | Instantiate and run time | WebAssembly's import model: a module can call only its declared imports. wasmtime 47.0.3 compiles it to native code with fuel or epoch interruption. |
| Peer node, OS process | OS | A separate OS process with its own VM. There is no capability restriction inside it. |

We found no text, regex or string-blocklist sandbox among the systems we
checked, and we do not describe any of them that way.

To our knowledge, Hyperlang is the first in-VM isolation design for the BEAM
that lowers guest source through its own compiler into a closed,
per-program call graph and checks the generated code against a positive
allowlist before loading it. We checked Dune, Luerl, tv-labs `lua`,
`erl_eval` with handlers, safeish, wa_embedder (it compiles WebAssembly to
BEAM modules but makes no security claim and creates atoms from export
names), ptc_runner, QuickBEAM, abacus, wasmex, Extism, Orb and Firefly. Our
search was limited to public hex packages, GitHub and the forums cited here.

## Partial trust in agent systems

Agent systems run code that is not entirely trusted. Some of it the agent
writes itself. Some of it comes as tools and plugins, or as per-tenant
logic. The agent's own behaviour can also be steered by untrusted input,
through prompt injection or poisoned tool output. Most such code is fine.
But it must not hold ambient authority. It must be metered and contained, so
that one bad step cannot reach the host, other tenants, or capabilities it
was not granted.

The actor model suits this work. Agents are long-lived, stateful, concurrent
and message-driven. They fail independently and need supervision. BEAM
processes and OTP give that directly. What the BEAM lacks is a way to run
partly trusted code inside the VM as an actor with no ambient authority,
metered and admitted. So teams leave the BEAM to get it:

- E2B gives every session "a hardware-isolated Firecracker microVM"
  ([e2b.dev](https://e2b.dev/)). Its docs state that resuming a sandbox
  "takes approximately 1 second"
  ([*Persistence*](https://docs.e2b.dev/sandbox/persistence)).
- Firecracker's specification states that a microVM with 1 CPU and 128 MiB
  of RAM boots in at most 125 ms, with at most 5 MiB of VMM memory overhead
  ([`SPECIFICATION.md`](https://github.com/firecracker-microvm/firecracker/blob/main/SPECIFICATION.md),
  *Overhead*).
- smolagents runs generated code in the host process by default. Its docs
  warn that "no local python sandbox can ever be completely secure" and point
  to E2B, Docker or other remote executors
  ([*Secure code execution*](https://huggingface.co/docs/smolagents/tutorials/secure_code_execution)).
- AutoGen's `DockerCommandLineCodeExecutor` "will create a Docker container
  and run all commands within that container". Its local executor carries
  the warning "Use it with caution."
  ([*Command line code executors*](https://microsoft.github.io/autogen/stable/user-guide/core-user-guide/components/command-line-code-executors.html)).
- Pydantic's `mcp-run-python` ran Python in Pyodide inside Deno. Its
  archival notice says "there's just no safe way to run Python within
  pyodide safely with reasonable latency"
  ([pydantic/mcp-run-python](https://github.com/pydantic/mcp-run-python)).
- Cloudflare's Dynamic Workers run code in V8 isolates. Cloudflare writes
  that "An isolate takes a few milliseconds to start and uses a few megabytes
  of memory" ([*Sandboxing AI agents, 100x faster*](https://blog.cloudflare.com/dynamic-workers/)).
  Its [Worker Loader API](https://developers.cloudflare.com/dynamic-workers/api-reference)
  documents `load(code)` "for one-time AI-generated tool calls".
- The Anthropic API
  [code execution tool](https://platform.claude.com/docs/en/agents-and-tools/tool-use/code-execution-tool)
  runs in a Linux container with 5 GiB of RAM and internet access disabled.
  [Claude Code](https://code.claude.com/docs/en/sandboxing) sandboxes
  commands with Seatbelt on macOS and bubblewrap on Linux.

Hyperlang gives the BEAM that primitive inside the VM. Guest actors are
ordinary Erlang: callback actors, durable actors with storage bindings,
channels and timers. They are capability-scoped and metered. In our
harness, a new tenant of a compiled program answered in 0.05 ms, an idle
guest actor added 23 KiB of resident memory, and a guest message round trip
took 0.83 µs. A peer node, the nearest BEAM-native alternative, took 111 ms
to boot and added 74 MiB. The README shows an agent running a generated tool
as a guest.

The isolation strength differs. A microVM or a separate OS process gives
OS-level separation, which Hyperlang does not provide. See
[Residual effects that remain](#residual-effects-that-remain).

## Prior art

Versions are those on hex.pm or GitHub when we checked. Sources were read at
the stated tag.

### Dune (Elixir, AST rewriting)

- **Version:** hex 0.3.18, tag `v0.3.18` (`b82ff4aa`), github.com/functional-rewire/dune.
- **Mechanism:** parse with an atom encoder, sanitize the AST against an
  allowlist, evaluate with `Code.eval_quoted_with_env/3` in a spawned
  process. The process has `priority: :low` and
  `max_heap_size: %{size: _, kill: true}` (`lib/dune/eval/process.ex:61-77`).
- **Limits:** `max_reductions` (default 30,000), `max_heap_size` (default
  50,000 words), `timeout` (default 50 ms) and `atom_pool_size` (default
  5,000) (`lib/dune/opts.ex:83-91`). A watcher process polls reductions.
- **Gaps we measured:**
  - The heap cap does not set `include_shared_binaries`. A guest that
    collected 1 KB strings under a 10M-word (80 MB) cap was stopped after
    1.3 s, when host memory had risen by 270 MB.
  - Guest code can read its own pid: `self()` returned a pid.
  - In a `Dune.Session`, defining a module with a one-letter name (`K` or
    `A`) and calling it in a later evaluation raised a `KeyError` in Dune's
    parser. The exit killed the calling host process
    (`probes/dune_session_crash.exs`). Longer names worked.
  - Existing atoms pass through (`String.to_existing_atom/1` in
    `lib/dune/parser/atom_encoder.ex:192`), so guest code can name any atom
    already in the VM.
- **Self-reported fixes** (CHANGELOG): atom leaks (0.1.1), a VM crash via
  bitstrings (0.3.3), and security fixes in 0.3.14 and 0.3.17.
- **Language limits** (README): no structs, behaviours, protocols, processes
  or metaprogramming.

### Luerl (Lua on the BEAM)

- **Version:** hex 1.5.1, tag `v1.5.1` (`772b25e9`), github.com/rvirding/luerl.
- **Mechanism:** a Lua interpreter whose whole state is an Erlang term.
  `luerl_sandbox` removes `io`, `file`, parts of `os`, `package`, `load`,
  `loadfile`, `require`, `dofile` and `loadstring`
  (`src/luerl_sandbox.erl:48-65`). It leaves `debug` installed.
- **Limits:** `max_time` (default 100 ms), `max_reductions` (default
  `none`), and `spawn_opts`. There is no memory limit unless the caller
  passes `max_heap_size` in `spawn_opts`.
- **Gaps we measured:**
  - Reductions are polled every 100 ms (`wait_reductions/2`). An infinite
    loop under a 10M-reduction limit ran to 36.7M reductions before it was
    killed.
  - With `max_reductions` set, even a trivial `return 1` took 100 ms,
    because the first poll sleeps.
  - When the runner died on its heap limit, `luerl_sandbox:run/3` did not see
    the death. It returned `{error, timeout}` only when `max_time` (4 s)
    expired.
  - The runner is spawned without a link (`start/4`), and only the caller
    enforces `max_time`. When we killed the caller of an infinite loop, the
    runner kept one core busy past its 1 s `max_time`
    (`probes/orphan_runs.exs`).
- **Atoms:** Lua names stay binaries. 50,000 distinct string keys added 13
  atoms after warm-up.

### `erl_eval` with restricted function handlers

- **Docs:** OTP 29 `erl_eval`, "Non-Local Function Handler". The handler is
  called for fun calls, BIF calls, `M:F` calls and operators. Exceptions:
  "calls to erlang:apply/2,3" and functions defined by `fun ... end`
  expressions are hidden from it.
- **Gaps we measured** (`probes/probes.exs`, handler allowing only `lists`,
  `maps` and arithmetic BIFs):
  - `F = fun os:cmd/1, F("echo pwned")` ran the command.
  - `lists:map(fun os:cmd/1, [...])` also ran it.
  - Scanning creates atoms: each program with 2,000 new atom literals added
    2,000 atoms. Stock `erl_scan` calls `list_to_atom/1`.
  - `erl_eval` runs in the calling process. A `receive` in guest code read a
    message from the host's mailbox.
  - It has no limits. The host must add a process, `max_heap_size` and a
    kill timer. With an unlinked evaluator process, a guest loop kept running
    after its caller died (`probes/orphan_runs.exs`).
- **Elixir:** `Code.eval_string/3` docs (Elixir 1.20): "Don't use
  `eval_string/3` with untrusted input".

### Peer nodes and OS processes

- **Mechanism:** a separate VM in its own OS process. The OTP `peer` module
  (OTP 25+) can connect over standard I/O, without distribution.
- **What it gives:** separate memory, schedulers and atom table. In our
  probe, 50,000 atoms created in a peer added 0 atoms to the host.
- **What it does not give:** any restriction inside the VM. In the peer,
  `os:cmd/1` and `file:read_file/1` worked. Over distribution, connected
  nodes have full access to each other (OTP Secure Coding Guidelines; EEF
  *Distribution*).
- **OS tools:** MuonTrap (hex 2.0.1) applies cgroup limits and kills child
  processes. Its README says that network sandboxing "is not supported. Look
  at tools like bubblewrap." ex_sandbox (hex 1.6.0) composes cgroups,
  namespaces, `setpriv` and `bwrap` on Linux.

### WebAssembly: wasmex

- **Version:** hex 0.15.1 (`c34f951a`), github.com/tessi/wasmex. It pins
  wasmtime 47.0.3 (`native/wasmex/Cargo.lock`).
- **Mechanism:** a Rust NIF over wasmtime. Guest code runs on a Tokio
  runtime whose thread count equals the number of host CPU cores
  (`native/wasmex/src/engine.rs:9-21`). It does not run on the BEAM's
  schedulers.
- **Limits:**
  - Fuel is off by default (`lib/wasmex/engine_config.ex`).
  - Linear memory is unlimited by default; `Wasmex.StoreLimits` caps it.
  - `call_function/4` has a timeout (default 5 s). In 0.15.0 and later, a
    timed-out call is interrupted by epoch. Our probe confirmed that CPU use
    stopped after the timeout.
- **What we measured:**
  - Fuel stopped an infinite loop.
  - A `memory.grow` loop stopped at the 80 MB store limit.
  - With 16 concurrent infinite loops (one per host core, the size of the
    Tokio pool), every call returned its 100 ms timeout, but the loops kept
    running: the BEAM still used 4 to 8 cores 10 to 12 s later, in two runs.
    With 8 or 15 loops, CPU use dropped to zero after the timeouts
    (`probes/wasm_pool_saturation.exs`). We did not find the cause.
  - In the 16-tenant noisy-neighbour cell, the first three victim calls each
    exceeded 5 s. The host BEAM used 11.0 cores while running with `+S 4:4`,
    and 11.8 cores after the cell ended
    (`results/noisy_trial_with_wasm16.log`).
- **Advisories in range for wasmtime 47.0.3:**
  - GHSA-32h6-97mm-8q3c (critical): component async-lifted callback results
    are unvalidated, causing a native stack buffer overflow; fixed in 48.0.4.
  - GHSA-mghf-wjfp-p5xm (critical): Cranelift on aarch64 can jump to the
    wrong target on a large `br_table`; fixed in 48.0.7.
  - We did not check whether wasmex's configuration reaches either path.

### Other systems we checked

- **safeish** (hex 0.5.0, last commit 2022): a BEAM bytecode verifier,
  broken by bounty exploits (see above).
- **tv-labs `lua`** (hex 1.0.2): a pure-Elixir Lua VM. `max_instructions` is
  `:infinity` by default, and its budget is "recoverable via `pcall`".
- **ptc_runner** (hex 0.15.0): an interpreted Lisp with a closed atom
  allowlist. It uses `max_heap_size` with `include_shared_binaries: true`.
  Its docs ask hosts to add an OS or container memory limit for adversarial
  tenants (`lib/ptc_runner/sandbox.ex:64-66`).
- **QuickBEAM** (hex 0.11.3): QuickJS as a Zig NIF, plus a BEAM interpreter
  of QuickJS bytecode with step, memory and time limits.
- **wa_embedder** (hex 0.3.3): compiles WebAssembly to BEAM modules. It makes
  no security claim, creates atoms from export names
  (`src/wa_embedder.erl:503`), and has no fuel or reduction limits.
- **Firefly:** archived (last commit 2023). **Extism Elixir SDK:** last commit
  2024. **Orb:** a compiler from Elixir to WebAssembly, not a runtime.

## Guarantee matrix

Each cell is labelled. **P** means a probe we ran (`probes/` in the
harness). **M** means a measurement. **S** means the project's source or
docs at the stated version. **Spec** means Hyperlang's security
specification and its tests.

| Property | Hyperlang | Dune 0.3.18 | Luerl 1.5.1 | `erl_eval` + handler | wasmex 0.15.1 | Peer node / OS process |
| --- | --- | --- | --- | --- | --- | --- |
| Guest language | Erlang | Elixir subset | Lua | Erlang | Any language compiled to Wasm | Any |
| Same VM as the host | Yes | Yes | Yes | Yes | Yes (native code via NIF, own threads) | No |
| Ambient authority | None by construction: positive call classification plus a generated-code gate. `apply`, external funs, computed `M:F`, HOF laundering and `self()` are rejected at compile time (P) | AST allowlist plus a run-time check. Same probes restricted (P). `self()` returns a pid (P) | Lua has no Erlang reach unless the host installs functions. Dangerous globals are overwritten (S) | Hook at run time. External funs bypass it: `os:cmd` ran (P) | Only declared imports (S) | Full ambient authority inside the VM: `os:cmd` and file reads worked (P) |
| Atom table | Fixed host-bounded set; pool atoms created on first use; 0 after warm-up across 1,000 adversarial programs (P) | Pooled, 0 growth after the first pool fill (P). Existing atoms reachable (S) | Names stay binaries: +13 for 50,000 keys (P) | +2,000 atoms per 2,000-literal program, unbounded (P) | No atoms from guest code (S) | Separate table: host +0 (P) |
| Reductions | Per run, watchdog; loop stopped in 28 ms at 10M (P) | Polled; loop stopped in 30 ms at 10M (P) | Polled every 100 ms; 36.7M at a 10M limit (P) | None built in (S) | Fuel, exact (P) | OS only |
| Heap | Per run, shared binaries counted; stopped at +77 MB under an 80 MB cap in 39 ms (P) | Shared binaries not counted: +270 MB under an 80 MB cap, 1.3 s (P) | Only via `spawn_opts`; death reported as timeout after 4 s (P) | Host-built (P) | `StoreLimits` cap held (P) | OS only |
| Wall time | Per run; 100 ms deadline hit at 109 ms (P) | `timeout`; 100 ms (P) | `max_time`; 100 ms (P) | Host-built (P) | Call timeout, epoch interrupt (P) | Host-built |
| Compile bound | Reduction budget plus wall backstop (Spec) | `parse_timeout` (S) | None found (S) | None (S) | None measured | N/A |
| Noisy-neighbour admission | Scopes: live-run admission, runnable permits, latency and background classes (Spec, M) | Evaluator at `low` priority (S) | None (S) | None (S) | None; shared native pool (M) | OS scheduler |
| Term sanitization at the boundary | Pids, ports, refs and funs rejected both ways (Spec) | Returns raw terms, including pids (P) | Lua values only (S) | Raw terms (S) | Numbers and linear memory (S) | Full term exchange |
| Capability-scoped filesystem | Virtual mounts with permissions and limits (Spec) | None; `File` restricted (P) | None; `io`/`file` removed (S) | None | WASI preopens (S) | Full host filesystem |
| Guest code loading | Only verified generated code, content-addressed (Spec) | No real modules (S) | `load` removed (S) | No modules | Per store | Unrestricted |
| Guest stops when its caller dies | Yes (P) | Yes (P) | No: runner continues past `max_time` (P) | Only if the host links the evaluator (P) | At its call timeout; not at pool saturation (P) | Child VM stops when its control connection closes (S) |
| Cross-tenant isolation | Per-run process and limits group; scoped timers and channels (Spec). Shared schedulers, allocators and code server (Spec) | Process per evaluation (S) | State is a value; no sharing (S) | Runs in the caller; read the host mailbox (P) | Store per instance; shared thread pool (M) | Separate VMs |
| Deterministic profile | Clocks and entropy need `capabilities.nondeterminism` (Spec) | Not checked | Not checked | No | Fuel is deterministic (S) | No |
| Guest actors (OTP) | `gen_server`, `gen_statem`, `gen_event` and supervisor conformance suites (Spec) | No processes (S) | No (S) | No | No | Full OTP |
| Tested sandbox surface | Adversarial suite: code-generation escape, verifier/codegen agreement, atoms and terms, bindings, cross-guest access, channels, the `sys` facade, filesystem and loader, error and stdout leaks, chaining of leaked names; plus grammar and mutation fuzzing; no escape found (Spec) | CHANGELOG security fixes (S) | Not found | N/A | wasmtime advisories exist (S) | N/A |

## Probe results

These are the outcomes of the ported probes (`probes/probes.exs`,
`results/probes.txt`). The probes are a subset of Hyperlang's sandbox suite.

| Probe | Hyperlang | Dune | Luerl | `erl_eval` + handler | wasmex | Peer node |
| --- | --- | --- | --- | --- | --- | --- |
| Many new atom literals in source | 500 admitted, +0 atoms; 2,000 rejected (pool limit), +0 | Pool exceeded at 1,251; +1,314 first round, then +0 | n/a (names are binaries) | +2,000 per program | n/a | +0 in the host |
| `list_to_atom` × 50,000 | Rejected at compile | Restricted at run time | n/a | Denied by handler | n/a | n/a |
| `apply(os, cmd, ...)` | Rejected at compile | Restricted | `os.execute` sandboxed | Denied | n/a | Ran |
| External fun `fun os:cmd/1` | Rejected at compile | Restricted | n/a | **Ran** | n/a | Ran |
| HOF laundering (`lists:map(fun os:cmd/1, ...)`) | Rejected at compile | Restricted | n/a | **Ran** | n/a | Ran |
| `self()` | Rejected at compile | **Returned a pid** | n/a | Denied | n/a | n/a |
| `spawn` | Run-time error without a host hook | Restricted | n/a | Denied | n/a | n/a |
| Read the host's mailbox | Not expressible: generated receives must match the message envelope (S) | n/a | n/a | **Read a host message** | n/a | n/a |
| Unbounded heap, 80 MB cap | Stopped in 39 ms, +77 MB | Stopped in 1.3 s, **+270 MB** | Stopped, reported as timeout after 4 s | Host-built cap: 32 ms, +60 MB | Store cap held | OS limits only |
| Infinite loop, 10M reductions | Stopped in 28 ms | Stopped in 30 ms | **36.7M reductions**, 100 ms | Host-built timer | Fuel trap in 50 ms | OS limits only |
| Caller killed during an infinite loop (1 s limit) | Stopped, 0 CPU after | Stopped, 0 CPU after | **Kept running** | **Kept running** (unlinked evaluator) | Stopped at its timeout | n/a |
| `-include`, `-define`, `-compile`, `-on_load`, `-nifs` | Rejected at compile | n/a | n/a | n/a | n/a | n/a |

## Benchmark method

### Workloads

Every system runs the same kernels and returns the same values:

- `id(42)`: a trivial call.
- `fib(N)`: naive recursive Fibonacci (`fib(20) = 6765`, `fib(25) = 75025`).
- `sort(1000)`: generate 1,000 integers with an LCG (seed 42,
  `x' = (x * 1103515245 + 12345) rem 2^31`), sort them, and return the first
  plus the last. wasmex has no list kernel.
- `loop(500)`: count down from 500 (the noisy-neighbour victim).
- `spin(_)`: loop forever (the noisy-neighbour load).

The sources are in `compare/lib/compare.ex`: Erlang for Hyperlang, the peer
node and the OS process; Elixir for Dune; Lua for Luerl; Erlang expressions
for `erl_eval`; WAT for wasmex.

### Configurations

- **Hyperlang:** `Hyperlang.run/4` with default policy (a worker process per
  run), `run_in_caller?: true`, and a callback actor from
  `Hyperlang.Actor` called with `GenServer.call/2`.
- **Dune:** `Dune.Session` with the module defined once. Limits:
  `max_reductions: 100_000_000`, `max_heap_size: 10_000_000`,
  `timeout: 5_000`.
- **Luerl:** a `luerl_sandbox:init/0` state with the functions loaded.
  Measured two ways: `luerl:call_function_dec/3` in the caller (no limits),
  and `luerl_sandbox:run/3` (spawned, `max_time` only, because
  `max_reductions` adds 100 ms to every run).
- **`erl_eval`:** funs bound once. Each call is evaluated in a process
  spawned with a 10M-word `max_heap_size`.
- **wasmex:** one instance per tenant, fuel on, 1 MB memory limit.
- **Peer node:** `:peer.start_link/1` over standard I/O with `+S 4:4`; the
  kernel module loaded with `code:load_binary/3`; calls with `:peer.call/4`.
- **OS process:** `erl -noshell -noinput +S 4:4` behind a `{packet, 4}`
  port; calls are `term_to_binary` RPCs.
- **Native reference:** the Erlang kernel compiled with `compile:forms/2` and
  called directly in the host VM.

### Procedure

- One host BEAM at a time, with `+S 4:4`. At most two child VMs.
- Each round runs every system, and the system order rotates between rounds.
- Results report the median and the range over rounds. The load column is
  the 1-minute load average at each sample.
- Warm calls: the mean over 5,000 (`id`), 50 (`fib(20)`), 100 (`sort`) or 5
  (`fib(25)`) calls, after a warm-up.

## Results

Host: 16-core Apple Silicon (macOS), OTP 29.0.2, Elixir 1.20.0, BEAM
`+S 4:4`. Other jobs ran on the host during every measurement.

### Tenant start from a compiled program

Each system prepares what it can once: Hyperlang compiles the program,
wasmex compiles the module against a shared engine, Luerl loads the state,
`erl_eval` builds the bindings and Dune evaluates the module into a session.
Each measured start then creates one new tenant from that prepared form and
answers `id(42)`. Child VMs have nothing to prepare and pay their boot. Five
rounds; the in-VM rows average 200 starts per round, the child VMs 3. Load
average 12 to 15 (`bench/prestart.exs`).

| System | Median | Range |
| --- | ---: | ---: |
| Hyperlang `run/4` of a compiled program | 0.052 ms | 0.044 ms–0.099 ms |
| `luerl_sandbox:run/3` on a loaded state | 0.029 ms | 0.028 ms–0.041 ms |
| `erl_eval` call on prepared bindings | 0.007 ms | 0.006 ms–0.018 ms |
| wasmex new store and instance of a compiled module | 0.084 ms | 0.045 ms–0.402 ms |
| Dune call on a prepared session | 0.409 ms | 0.292 ms–1.8 ms |
| Peer node boot + call | 111.5 ms | 104.1 ms–290.6 ms |
| OS `erl` process boot + call | 123.2 ms | 108.5 ms–409.4 ms |

### Start from source

Time from source text to the first answer of `id(42)`, measured on an
earlier build of this release. Five rounds; the in-VM rows average 20 starts
per round. Load average 7.5 to 7.6, except the Docker row (10.1).

| System | Median | Range |
| --- | ---: | ---: |
| Hyperlang `program/1` + `run/4` | 17.0 ms | 16.7–17.3 ms |
| Hyperlang `program/2` cache hit + `run/4` | 0.17 ms | 0.17–0.18 ms |
| Dune session + call | 1.11 ms | 1.10–1.16 ms |
| Luerl sandbox init + load + call | 0.11 ms | 0.09–0.11 ms |
| `erl_eval` parse + eval + call | 0.05 ms | 0.05–0.07 ms |
| wasmex compile + instantiate + call | 0.53 ms | 0.52–0.56 ms |
| Peer node boot + load + call | 91.2 ms | 87.9–93.9 ms |
| OS `erl` process boot + load + call | 94.2 ms | 93.8–97.3 ms |
| `docker run --rm alpine:3 true` (no Erlang inside) | 178 ms | 163–192 ms |

Hyperlang's cold start is a full compile through the verifier and the OTP
compiler. The interpreters only build a data structure. The container figure
is a lower bound for container isolation: the image was `linux/amd64`, run
under emulation in Docker Desktop's VM, with no BEAM inside.

### Warm calls

Mean time per call, in µs. Three rounds; median, with the range in brackets
where it matters. Load average 11 to 15.

| System | `id(42)` | `fib(20)` | `sort(1000)` | `fib(25)` |
| --- | ---: | ---: | ---: | ---: |
| Native BEAM, in the caller (reference) | 0.06 | 82 | 54 | 961 |
| Native BEAM, fresh process per call (reference) | 1.9 | 79 | 74 | 950 |
| Hyperlang actor `GenServer.call` | 30 | 62 | 269 (232–316) | 464 (401–1,148) |
| Hyperlang `run/4`, worker process | 46 | 125 (67–147) | 240 (237–375) | 1,051 (396–1,339) |
| Hyperlang `run/4`, in caller | 21 | 54 (51–124) | 243 (231–332) | 373 (346–1,026) |
| Dune session eval | 320 | 23,714 | 9,248 | 294,149 |
| Luerl `call_function`, in caller, no limits | 0.31 | 9,062 | 758 | 115,775 (106,844–139,324) |
| `luerl_sandbox:run/3`, spawned | 28 | 7,122 (6,750–12,815) | 663 (490–731) | 94,044 (84,676–115,376) |
| `erl_eval`, spawned, heap cap | 4.4 | 9,740 | 1,819 | 111,653 (106,320–204,206) |
| wasmex `call_function`, fuel | 15 (10–15) | 76 (71–105) | n/a | 684 |
| Peer node `:peer.call` | 31 | 54 (51–79) | 94 (83–109) | 348 (326–487) |
| OS process port RPC | 26 | 48 (45–88) | 91 (64–96) | 432 |

- **Two speed levels.** Plain BEAM code ran `fib(25)` at about 0.37 ms or
  about 1.0 ms, depending on the run. The ranges above show both levels for
  the same row. This fits scheduler threads landing on different core types
  of this Apple Silicon host. We did not pin threads, so compare compute
  across rows with care.
- **Guest against native, same load.** `bench/guest_cost.exs` alternates
  single guest and native calls so that both see the same conditions. Over
  50 pairs, a guest `fib(25)` through `run/4` took a median 1.20x the native
  time in a fresh process (range 0.93x to 2.84x), and this includes the
  per-run cost. The medians were 0.39 ms (guest) and 0.36 ms (native) at load
  average 8.
- **Interpreters.** On `fib(25)`, Dune, Luerl and `erl_eval` took 94 to
  294 ms (median), against 0.35 to 1 ms for compiled code in the same runs.
- **Per-call cost.** Each Hyperlang call takes one Scope admission call,
  fresh per-run limits and sanitization: about 21 µs for a `run/4` in the
  caller, 30 µs for an actor call and 46 µs for a `run/4` worker. Luerl in
  the caller and wasmex have a lower fixed cost for tiny calls.

### Throughput under concurrent tenants

Each tenant owns its own instance and calls `fib(15)` in a loop for 1.5 s.
Calls per second for all tenants together (three rounds, median). Child VMs
are capped at two by the lane rules.

| System | 1 tenant | 2 | 4 | 16 | 64 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Hyperlang actor | 25,721 | | 44,948 | 46,642 | 38,529 |
| Hyperlang `run/4` | 19,055 | | 26,162 | 36,950 | 28,556 |
| Dune | 229 | | 725 | 69 | 86 |
| Luerl in caller, no limits | 1,270 | | 3,237 | 3,291 | 3,634 |
| `luerl_sandbox:run/3` | 1,333 | | 3,090 | 3,318 | 2,973 |
| `erl_eval` | 837 | | 2,548 | 2,518 | 2,547 |
| wasmex | 27,485 | | 106,490 | 240,446 | 280,838 |
| Peer node, one VM per tenant | 22,076 | 32,290 | | | |
| OS process, one VM per tenant | 24,585 | 31,873 | | | |

Load average 10 to 17.

- The BEAM systems run on four schedulers. wasmex runs guest code on its own
  thread pool, sized to all 16 host cores. Each child VM brings four more
  schedulers. So the wasmex and child-VM rows use more CPU than the in-VM
  BEAM rows.
- For calls this small, per-call cost dominates. Hyperlang ran 8x to 20x
  more calls than Luerl and `erl_eval`, more than the child VMs, and fewer
  than wasmex, which uses all host cores.

### Memory per tenant

Each row is one fresh BEAM per round, so allocator caches from another
system do not leak into the result. The harness warms the system up, forces a
garbage collection of every process, waits 1 s, and samples. It then creates
N tenants, collects and waits again, and samples a second time. The numbers
are the per-tenant difference: OS resident memory (RSS), and the BEAM's own
counters. Three rounds, systems interleaved; median and range. Load average
9 to 11. The child-VM rows are from an earlier run at load 9.5 to 14.6.

| Tenant | N | RSS per tenant | BEAM total per tenant |
| --- | ---: | ---: | ---: |
| Hyperlang idle actor, one shared program | 2,000 | 23 KiB (22–26) | 9.5 KB |
| Dune session with the module | 2,000 | 109 KiB (101–124) | 29.9 KB |
| Luerl sandboxed state with the functions | 2,000 | 71 KiB (58–71) | 20.6 KB |
| `erl_eval` bindings with the funs | 5,000 | 23 KiB (23–23) | 6.9 KB |
| wasmex instance of a Rust guest: own store, shared engine and module | 2,000 | 89 KiB (88–89) | 3.2 KB |
| Peer node | 1 VM | 75,824 KiB (74,832–77,184) | |
| OS `erl` process | 1 VM | 77,360 KiB (76,096–77,776) | |

What each number includes:

- **Hyperlang actor.** The loaded program is one shared literal in its code
  slot, which the actor pins while it lives, so actors only reference it.
  The figure covers the actor process and its scope and limits bookkeeping.
- **Hyperlang program.** A compiled `%Hyperlang.Program{}` value is about
  35 KB of terms, and a loaded program's shared literal about 46 KB.
- **Interpreters** (Dune, Luerl, `erl_eval`): the tenant is a data structure
  held by the host. Each run then copies it into a fresh process.
- **wasmex.** `erlang:memory/0` does not count NIF memory, so only the RSS
  column covers the wasmtime store and instance. The guest is the same
  kernels compiled from Rust (std, default 1 MiB stack, heap), and each
  instance ran `id`, `fib` and `sort` once, so its stack and heap pages are
  touched. RSS counts touched pages only; a larger guest touches more.
- **Peer node and OS process:** the RSS of one child VM started with
  `+S 4:4`, idle after loading the kernel module.

An idle Hyperlang actor costs about 3,300x less resident memory than a peer
node or an OS `erl` process, and less than a Luerl state, a Dune session or
a wasmex instance. Only `erl_eval` bindings, which hold no isolation, are as
small.

### Message round trip

- Hyperlang message ping-pong (`bench/message_ping_pong.exs`): a guest sends
  to an echo process through the host's message hook and receives the reply,
  50,000 times. Three runs took 0.82, 0.83 and 0.90 µs per round trip at
  load average 7.4.
- Calls from the host into a tenant: see the `id(42)` column above. The
  peer node took 29 µs and the OS process 25 µs.

### Victim latency next to noisy neighbours

The victim makes 1,000 sequential `loop(500)` calls. Each noisy tenant runs
`spin/1` over and over, and each run is stopped at 100 ms by the system's own
control. We report the victim's p99 in µs (three rounds, median and range),
the host BEAM's CPU use in cores, and victim calls that failed or exceeded
5 s.

The `Hyperlang.Scope` noise runs under a CPU rate quota of 100,000
reductions per 100 ms. Each tenant spends the budget in a burst of a few
milliseconds after each refill and is suspended for the rest of the period.
Back-to-back calls of a fast victim end before the first refill and never
meet a burst. So call k starts no earlier than k × 0.4 ms into the window:
the calls cover four whole periods at even phase spacing. Calls slower than
0.4 ms run back to back. The noise of the other systems does not depend on
the phase of a period.

| System | Victim p99, 0 tenants | 4 tenants | 16 tenants | Host BEAM cores used, 16 tenants |
| --- | ---: | ---: | ---: | ---: |
| Hyperlang with `Hyperlang.Scope` (victim `:latency`, noise `:background` with a rate quota) | 54 (46–58) | 72 (67–84) | 89 (87–92) | 1.1 |
| Hyperlang without scope controls | 51 (49–60) | 107 (99–129) | 182 (142–227) | 3.2 |
| Luerl `luerl_sandbox` (`max_time` 100 ms) | 183 (150–200) | 272 (262–389) | 557 (451–1,399) | 3.4 |
| `erl_eval` (host kill timer 100 ms) | 287 (204–321) | 715 (596–12,476) | 2,124 (1,365–2,310) | 3.4 |
| Dune (`timeout` 100 ms) | 3,551 (2,720–8,347) | 18,969 (15,250–23,731) | 126,638 (106,458–137,530) | 3.5 |
| wasmex (call timeout 100 ms) | 32 (29–72) | 145 (41–405) | not measured, see below | n/a |
| Peer nodes (victim in one VM, noise in another) | 107 (73–817) | 152 (116–180) | 122 (63–426) | 0.25 (noise runs in the other VM) |

Victim p99 in µs; three rounds, median and range. The Hyperlang rows were
measured with the even call spacing at load average 3.9 to 4.8. The other
rows were measured with back-to-back calls at load average 12.7 to 32.0.
The core counts include the victim's caller, which polls between calls.
No victim call failed. After every cell, the VM's idle CPU use returned to
at most 0.01 cores, so no cell left work running that could bias the next.

- With scope controls, the victim's p99 rose 1.6x from 0 to 16 noisy
  tenants. Without them it rose 3.6x. Luerl rose 3.0x, `erl_eval` 7.4x and
  Dune 36x. With the scope rate quota, the VM used 1.1 cores, victim
  included.
- The peer-node victim stayed flat because its noise ran in another VM with
  its own four schedulers, on a 16-core host. That is the OS-level
  separation Hyperlang does not provide.
- wasmex at 16 tenants is not in the table. Sixteen spinning calls fill
  wasmex's 16-thread pool, and the calls kept running after their timeouts
  (see [WebAssembly: wasmex](#webassembly-wasmex)). In a single trial of that
  cell, the first three victim calls each exceeded 5 s. The host BEAM used
  11.0 cores, and 11.8 cores after the cell ended. Those loops would have
  biased every later cell, so the final runs skip it.
- Every noisy tenant stops at a flag between runs. Killing a Luerl or
  `erl_eval` caller mid-run leaves its runner spinning
  (`probes/orphan_runs.exs`). An earlier attempt killed the callers, left
  orphaned runners, and we discarded its data
  (`results/discarded/noisy_attempt2_orphan_leak.*`).

These victims run a short loop, so they measure scheduling delay. Heap
pressure and compile load are covered by the specification's own isolation
measurements.

## Limitations of this comparison

- **One shared, loaded host.** Other jobs ran during every measurement. The
  load average ranged from 6 to 32 in the final runs, and reached 100
  during discarded attempts. We interleaved systems and report ranges. Absolute numbers will differ on a quiet host.
- **Apple Silicon core types.** Scheduler threads can land on performance or
  efficiency cores. Compare compute numbers within one execution context.
- **Unequal CPU budgets.** The in-VM BEAM systems ran on four schedulers.
  wasmex used its own pool sized to all host cores. Child VMs added four
  schedulers each.
- **Child VMs capped at two.** The lane rules allowed at most two child
  VMs, so the peer-node and OS-process throughput stops at two tenants.
- **Container baseline.** The Docker figure is a lower bound under emulation,
  with no BEAM inside the container.
- **Our harness, our configurations.** Each competitor ran with the
  configuration that the comparison describes. Other configurations may do
  better.
- **Probes are a subset.** The ported probes cover representative attacks.
  They are not each competitor's full attack surface, and a passing probe
  does not prove a system secure.
- **Published claims.** We did not reproduce vendor figures for E2B,
  Firecracker or Cloudflare. They are quoted from their docs.

## Reproduction

The comparison harness is a separate Mix project. It depends on Hyperlang by
path and on the competitors from hex. It is not part of this repository.

```bash
export MIX_BUILD_ROOT=$HOME/.cache/mixbuild/hyperlang_pitch/compare ELIXIR_ERL_OPTIONS='+S 4:4'
mix deps.get
mix run bench/compare_bench.exs cold 5
mix run bench/compare_bench.exs warm 3
mix run bench/compare_bench.exs tput 3
mix run bench/compare_bench.exs noisy 3
mix run bench/compare_bench.exs docker 5
./run_mem.sh            # one fresh BEAM per system and round
mix run probes/probes.exs
mix run probes/dune_session_crash.exs
mix run probes/elixir_compile_time.exs
export ELIXIR_ERL_OPTIONS='+S 4:4 +sbwt none +sbwtdcpu none +sbwtdio none'
mix run probes/orphan_runs.exs
mix run probes/wasm_runaway.exs
mix run probes/wasm_stop_midcall.exs
mix run probes/wasm_pool_saturation.exs 16
python3 scripts/summarize.py
python3 scripts/tables.py noisy
python3 scripts/tables.py mem
```

Hyperlang-only measurements live in this repository:

```bash
mix run bench/guest_cost.exs
mix run bench/message_ping_pong.exs
mix run bench/eval_hot_path.exs
```

The sandbox suite and the fuzz campaigns cited in the matrix run with:

```bash
mix test test/sandbox
HL_FUZZ_SEED=20261025 HL_FUZZ_MUT_SEED=77777 HL_FUZZ_N=2000 HL_FUZZ_MUT_N=800 \
  mix test test/sandbox/fuzz_probe_test.exs --include sandbox_fuzz
```

The grammar campaign generates 2,000 programs and the mutation campaign 800.
