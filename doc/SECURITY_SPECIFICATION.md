# Hyperlang Security Specification

This is the only security specification document for Hyperlang. It is one
reference for the door, bindings, modules, filesystem, frontend, compatibility,
and rejected forms.

## Security Goal

Hyperlang compiles untrusted Erlang-shaped source into BEAM code generated only
from verified SafeCore IR. It is not an Erlang actor sandbox, and it does not
grant ambient BEAM authority. Host authority enters through an explicit
manifest, declared bindings, selected stdlib MFAs, and optional Hyperlang-owned
compatibility capabilities.

## The Door

The public API is four functions, and this specification secures exactly them:

- `Hyperlang.program/1` compiles an immutable source value
  (`%{entry:, files:, manifest:}` or a single source binary) into a
  `%Hyperlang.Program{}`. All authority the program can ever request is fixed
  here: the manifest, the binding MFA set, the export set, and the allowed
  atom universe are normalized and enter the program hash.
- `Hyperlang.program/2` caches a program under a caller-owned key and calls a
  loader function only on a miss. The cache never widens a program.
- `Hyperlang.run/4` runs one declared export with only the authority present
  in its `spec`. A run cannot add authority the program did not declare.
- `Hyperlang.module/1` returns the confined OTP callback module for a program.
  Every callback goes through `Hyperlang.run/4`, so the callback path has the
  same boundary as a run.

The `run/4` result shape is:

```elixir
{:ok, safe_term, %{stdout: [binary], reductions: non_neg_integer, wall_us: non_neg_integer}}
| {:error, safe_error}
```

`stdout` holds the sanitized, limit-checked guest stdout chunks. `reductions`
and `wall_us` are host-measured integers; they carry no guest data.

`Hyperlang.Test` is a host test kit built only on these four functions. It adds
no authority and no bypass.

## Threat Model

Untrusted guest source may try to create atoms, access BEAM modules, use process
or filesystem authority, load code, exhaust resources, leak host internals, or
smuggle unsupported terms. Hyperlang must prevent those behaviors inside the
configured same-VM boundary.

The embedding host is trusted to configure bindings and filesystem mounts
correctly. Binding modules are trusted host authority, but binding arguments
and returns are still sanitized.

Hyperlang enforces authority isolation for untrusted guest source inside one
VM: a guest cannot reach any function, process, port, file, atom or code path
that its program and run do not grant. Resource isolation between guests on
one node is bounded but not complete. Guests share schedulers, allocators,
the garbage collector and the code server, and some native calls cannot be
interrupted. Hosts that need hard latency or memory bounds against hostile
tenants add OS or node isolation. See Known Limitations.

## Binding Boundary

A binding is a trusted host module implementing `Hyperlang.Binding`. The
program manifest names it once: `bindings: %{"kv" => MyHost.KV}`.

- `Hyperlang.program/1` calls `exports/0` once and pins the derived exact MFA
  allowlist (`kv:get/1`, ...) plus per-export options (`limits`,
  `nondeterministic`, `effects`, `docs`) into the normalized manifest. The
  binding module identity and the MFA set are part of the program hash.
- Guest code reaches a binding only through a static remote call that matches
  a pinned MFA. Any other call on the binding name is a compile-time `verify`
  error. A binding is never a guest-visible value: there is no `env` term, no
  dynamic `M:F` dispatch, and no way to store or forward a binding.
- Binding names must be application-owned lowercase module names. Names of
  reserved authority modules (`erlang`, `file`, `code`, `os`, `lists`, ...) and
  reserved Hyperlang internal names are rejected at `program/1`.
- `Hyperlang.run/4` takes `spec.bindings: %{"kv" => {MyHost.KV, state}}`. The
  supplied map must name exactly the declared bindings, each with the declared
  module. A missing, undeclared, or substituted binding fails the run with a
  `manifest` error before guest code starts. The run never resolves the module
  list or the MFA set; both come from the program.
- `state` is host data. It reaches `MyHost.KV.call(state, function, args)` and
  never reaches the guest, so secrets and tenant identity belong there.
- Binding arguments are sanitized before the call and the return value is
  sanitized after it, with any per-export `limits` applied. A binding exception
  becomes an `import` fault with a sanitized message; raw exception structs,
  pids, refs, and funs never cross.
- An export marked `nondeterministic: true` is rejected at `program/1` unless
  `capabilities.nondeterminism` is enabled.

The separate `spec.syscall` host door (a `Hyperlang.SyscallHost` module and
state) backs the `sys:*` facade. It is selected by the host per run, like a
binding, and guest code cannot select or replace it.

## Parser And Compiler Boundary

- Source is parsed by vendored, renamed OTP `erl_scan` / `erl_parse` code with
  atom-producing paths patched so untrusted names remain binaries or ids.
- Raw user Erlang abstract forms are never compiled as the security boundary.
- Parsed source lowers to SafeCore, verifies structurally, classifies calls,
  verifies semantically, then codegen emits Erlang Abstract Format.
- `compile:noenv_forms/2` runs on Hyperlang-generated forms only.
- The full parse, verify, classify, codegen, and OTP compile path runs in a
  compile worker. The worker is bounded by a reduction budget
  (`limits.max_compile_reductions`, 200,000,000 by default), a wall-clock
  backstop (`limits.max_compile_ms`, 30,000 ms by default) and the scope's
  `compile_heap_words`. OTP compilation runs inside the worker
  (`no_spawn_compiler_process`), so its reductions are charged.
- The budget counts the reductions the worker executes. These do not depend on
  host load, so a given program is admitted or rejected the same way on an
  idle and on a saturated node. The caller samples the worker every 5 ms; the
  overshoot is at most the reductions the worker executes in one sample
  period. A program over budget fails with `compile_budget`.
- The wall backstop stops work that does not execute reductions, such as a
  blocked or descheduled worker. It fails with `compile_timeout`. Admission
  waits before the worker starts are not charged to either limit.
- Loading a program with the gen_server capability compiles the injected OTP
  behaviour library with the program, under a budget floor of 400,000,000
  reductions.
- Generated-form verification rejects unknown call shapes, dynamic calls,
  send/receive/process forms, external funs, and unsupported generated tuples.
- Guards admit guard tests only. A `fun`, `try`, `case`, `if` or comprehension
  inside a guard is a `verify` error, so no expression-mode body reaches guard
  lowering.

## Runtime Boundary

- A run executes in an internal worker process with monitor, wall timeout, heap cap,
  on-heap mailbox, optional external reduction watchdog, and result sanitizer.
- The sandbox entrypoints are generated `$safe_entry/3` for the `result/1`
  root (`Hyperlang.run(spec, program, :entry, [input])`) and generated
  `$safe_export/4` for manifest-declared exports
  (`Hyperlang.run(spec, program, "name/arity", args)`). Both use the same
  worker limits, runtime token checks, stdout capture, result sanitizer, and
  error sanitizer.
- Each run gets a fresh runtime token; a token is not reused across runs or
  callbacks. A spawned run gets its own limits group. The top-level in-caller
  runs of one process share that process's limits group and its one slot:
  every callback of one actor, and every top-level `run_in_caller?` run of
  one host process. Each such run arms a new generation of the slot, and its
  ceiling, wall deadline and `max_procs` bound are its own. Limits resets the
  group's usage when it sees a new generation, admits a guest child only while
  the child's own generation is armed, and the run kills its children before
  it returns. A nested in-caller run, or one with a `rate` quota, gets its own
  group. The process's exit destroys its group.
- Program storage: a loaded program's canonical `%Hyperlang.Program{}` value
  is stored once, as a `:persistent_term` literal on the code slot's record,
  keyed by content hash. Runs, run workers and actors reference that value
  instead of copying it, so an idle actor holds only its own state. The
  record lives exactly as long as the code slot: slot reclamation or release
  erases it, and the runtime's literal-area collection then copies the value
  into any run worker that still references it. Guest code cannot read
  `persistent_term` or another program's module (both are `verify` errors).
- Code-slot pins: a live OTP actor pins the code slot its callback module
  names, from its `init/1` until it exits. Reclamation never takes a pinned
  slot, and `release` of a pinned slot takes effect when its last pin goes.
  An actor's callback module and program literal therefore stay loaded for
  its whole life, and the literal is never copied onto its heap. Pins are
  charged to the actor's scope (`spec.policy.scope`, else the actor's own
  default scope). A scope pins at most `max_code_pins` distinct slots
  (scope policy, default 64); further actors of an already pinned program
  cost no pin. `init/1` past that bound stops with `code_pool`
  (`details.reason` `pin_limit`). When every slot of a load's `code_pool`
  window is pinned or still running guest code, the load fails with
  `code_pool` ("no generated code slots available"). Pins survive a
  CodeServer restart.
- Guest code never receives worker pids, parent pids, monitor refs, ports, raw
  references, external funs, IO devices, or mailboxes.
- The reduction watchdog observes process reductions externally and kills the
  worker. Hyperlang does not insert guest fuel counters.
- Internal tracking is limited to atom-related state, generated code slots, and
  capability state needed to enforce boundaries.

## Resource Scopes And Lifetimes

A scope is a host-selected resource identity. The host selects a shared
scope with `spec.policy.scope` and configures it with
`Hyperlang.Scope.configure/2`; the configuring host owns its lifetime.
Without an explicit scope, the host caller owns the scope, also when a code
load reaches Scope first through the code server. Closing a scope,
or the exit of its owner, kills its workers and cancels its timers and
channels.

- Admission: a scope bounds **live** runs (blocked runs included) and live
  compiles, with a bounded queue governed by `max_queue` and `wait_ms`.
  Saturation, queue timeout and termination return sanitized `busy` faults.
  Same-scope nested calls borrow an ancestor's live lease of the same kind;
  nested compilation still needs a compile lease if the ancestor only holds a
  run lease. A nested request without immediate per-scope capacity returns
  `busy/admission_cycle`. Node-wide compilation remains capped below the
  scheduler count.
- Runnable capacity: a separate node-wide permit bounds executing guest
  processes, including engine-metered and explicitly host-metered children. Its configurable
  `:runtime_concurrency` defaults to `max(256, 32 * schedulers_online)` (256 at
  four schedulers; minimum configured capacity two). One slot is reserved for
  latency scopes. Receive (with or without timeout), channel send/recv/alt,
  sleep, binding/syscall door time, nested calls and child/reply/monitor waits
  release the permit before blocking and reacquire before guest execution.
  Native receives retain their existing permit for at most a one-millisecond
  probe (zero for after-zero), then release before any remaining wait.
  Uncontended resumption atomically inserts an owned ETS slot. It checks that
  the lifetime's Scope server is still the registered one, and makes no call
  and sends no signal to it. One lifetime monitor survives all handoffs; no
  monitor is created per block. A spawned
  run worker opens its lifetime with its scope membership and retires it,
  together with the run's live lease, when it detaches. Its wall deadline,
  ceiling and children are a slot of its run's limits group: arming the slot
  creates the group in a request the worker does not wait for, and finishing
  deletes it without a reply unless a guest child joined the run, in which
  case one call checks the run-level ceiling and kills the children first.
  An in-caller run is admitted by one call that also attaches the caller
  and opens its lifetime. A detach (lifetime, lease and membership) is a
  request the run does not wait for. It is sent before the run returns or
  the worker replies, and one process's requests stay ordered, so the
  caller's next Scope request already sees the lease released. An
  uncontended spawned run therefore makes one admission call in the caller
  and one Scope call in the worker; an uncontended in-caller run or actor
  callback makes one Scope call and no Limits call. The slow
  queue closes a gate against overtaking reservations, and background work
  cannot claim the latency-reserved slot. Death cleanup reclaims all slots
  for that lifetime, including a reservation interrupted before local commit.
  Runtime configuration changes apply at startup or the next idle runtime.
  Admission and resumption are FIFO within each priority class, without the
  live-lease `wait_ms` or `max_queue` bounds. The existing wall deadline continues
  during both host waits and permit waits. Scope closure/termination cancels
  queued resumption with a typed `busy` fault; a generation check prevents
  revival after scope-name reuse. No waiter holds a runnable permit while
  acquiring another. An explicitly small live-run policy can still exclude a
  communicating peer; the host must size that independent lifetime policy.
- Accounting while blocked: scope membership, reductions, heaps, wall time,
  compile rate and churn charges remain intact. Blocking never refills counters.
  Physically suspended workers release capacity and need a permit before the
  scope lifts suspension. An in-caller host cannot be physically suspended, but
  its next resumption still waits for scope refill.
- Channel accounting: each scope has its own quota/sampling controller and a
  counters row in one shared table, keyed by scope and owned by the
  controller's pid. The controller replaces only a row it still owns, so a
  late publication after closure or name reuse cannot revive a row; closure
  and controller death delete it. A quiet controller hibernates after one
  second. A serial transaction checks both channel and
  buffer limits before admitting distinct brokers or a batch of aliases;
  start-channel reservations use the same capacity. Allocation/free does not
  send a request to shared Scope. Channel-only sampling remains local and
  reports configured rate/churn usage or heap violations for enforcement.
  Scopes with workers continue combining worker and channel heaps. Cumulative
  channel CPU, growth and GC totals survive free; stats project fresh counters
  without polling every idle scope. Registry charges measured hot metadata
  work to the allocating scope. Throttled allocation waits outside Registry,
  releases runnable capacity, and cannot resume into a reused controller.
  Registry retains one owner for atomic alias/fork/cleanup operations. It
  replies to each request and then yields, so a request backlog holds a
  scheduler for one request at a time, not for a full time slice.
- Priority: guest workers and compiles run at `low` process priority by
  default. A scope configured with the `latency` class runs at `normal`.
  Trusted host doors retain host priority. Broker startup has separate
  background and latency partition pools, with at least 16 partitions each.
  Registry never waits on uncharging another scope: the allocating caller does
  that work after alias removal. Last-alias free revokes access and quota
  synchronously, then schedules broker retirement and its close hook. Lifetime
  close waits only for its own orphaned brokers, outside supervision. Latency-class calls into
  Scope and Limits use OTP priority aliases, bypassing queued background work.
  Their callers wait for the reply at `high` process priority and return to
  their own priority on wake-up. A latency-class run worker starts at `high`
  and takes `normal` before any other work; its caller also waits for the
  worker's reply at `high` and flushes the worker monitor before it drops
  back, because a flushing demonitor can reschedule the caller. Guest code
  never runs above its class. Scope and
  Limits wake at `high` only while their mailbox is empty and handle every
  message at `normal`: a backlog competes at `normal`, and one handler runs at
  most the rest of one time slice at `high`.
  Explicitly host-metered children retain host-owned budgets and select their
  current host scope when their hook starts them; they do not inherit a
  spawning evaluation's lifetime.
  One monitored control sampler per scope performs process inspection outside
  the admission server. A synchronous inspection of a busy worker or broker
  therefore cannot hold up another scope's admission. Results are bound to both
  scope and member lifetimes, and cannot replace a newer observation. Final
  detach observations preserve CPU and churn charges from short-lived runs.
  The sampler uses its scope's priority, dies with its scope, and its
  unexpected death closes the scope.
  Channel brokers and host allocation/free bookkeeping inherit their allocating
  scope's priority class; the calling host's priority is restored afterwards.
- Memory: a scope caps the aggregate heap of its processes, not only each
  process heap. Optional CPU, compile and heap-churn rates suspend an
  offending scope until refill and terminate it after repeated violations.
  Compile worker heaps have a separate `compile_heap_words` cap (64,000,000
  words by default), consume global compile capacity and `compile_rate`, and
  are excluded from the runtime aggregate heap and churn budgets.
  Scope enforcement kills only guest workers and guest children. It never
  kills or suspends a scope owner or an in-caller host. In-caller work reports
  a typed fault when control returns from the trusted host callback.
- Runs: every run has fresh reduction accounting and an independent
  wall-deadline timer. A spawned run's limits group is destroyed when the run
  ends; in-caller runs reset their process's group per run (see Runtime
  Boundary). Actor lifetime limits (`rate`, `ceiling`) remain separate; an
  actor without either has no actor-lifetime group.
- Children: guest children owned by a run are killed when that run ends. A
  host spawn hook that explicitly takes over metering owns that child's
  lifetime.
- Timers: timer handles are random 128-bit integers bound to their scope,
  and the timer quota is per scope. Read and cancel check ownership; a
  cross-scope read or cancel returns `false`. Expiry delivery, including the
  trusted host resolver, runs in one ordered worker per scope. Pending delivery
  retains its quota charge until completion, bounding the worker queue by the
  scope's timer quota. Expired handles read/cancel as `false`; scope closure
  cancels live timers and stops its delivery worker. Resolver exceptions drop
  that delivery without stopping unrelated scopes. A resolver held open in one
  scope does not delay another scope's delivery: the isolation suite holds one
  scope's resolver until another scope's 21 ms timer has been delivered, and
  requires that delivery to arrive within 5 ms of a bare BEAM timer with the
  same delay.
- Channels: channel and start-channel counts, buffer slots and broker heaps
  are charged against scope quotas and a live owner. Start-channel rows are
  owned by a supervised registry that monitors each creator. Guest channel
  sends (`sys:csend/2` and `sys:alt/1` send arms) follow the same carrier rule
  as `!`, `exit/2` and timers: a fun, pid, port or ref anywhere in the value
  raises `{hyperlang_send, forbidden_term}` before any channel is touched.
  Trusted host kernels that pass broker pids use `Hyperlang.Chan` directly.
- Tables: guest tables (`hyperlang_table`, enabled with manifest `tables`)
  are capped per run by table count, objects per table and bytes per table.
- Mailboxes: guest workers, inherited children and heap-limited members use
  on-heap mailboxes, so mailbox growth counts against the heap limit.
- Diagnostics: OTP actor status and crash reports always use the host
  redactor, including when a guest defines a `format_status` callback.
  Program artifacts, spec, policy and guest state are omitted from status,
  structured reports and rendered text.

## Export Entry Boundary

Manifest `exports.functions` and `exports.fileserver` declare host-callable
capability surfaces. `exports.functions` is a map from host-selected export id
to `%{function:, arity:}`; the list form, `exports.files`, and `:name`/`:id`
entry keys are rejected. Manifest keys are atoms at every level; string keys
and unknown keys are rejected rather than ignored. Source `-export` attributes do not grant authority; they
remain inert metadata for guest source compatibility. Only normalized manifest
exports can be called through `Hyperlang.run/4` and generated `$safe_export/4`.
OTP callbacks (`init/1`, `handle_call/3`, ...) defined by the source are
declared automatically so `Hyperlang.module/1` can dispatch them; no other
function becomes callable that way.

Export dispatch must use host-selected manifest export ids, never guest-supplied
module/function/arity tuples, generated module names, generated helper names, or
raw source `-export` declarations. Non-exported helpers must remain unreachable
through export dispatch even if source lists them in `-export`.

Generated-module secrecy is part of the boundary. Public program metadata
(`program.metadata`), export errors, stdout, and result terms
must not reveal generated slot modules, generated helper atoms such as
`safe_f_N`, internal entrypoint names, stack maps, or generated export tables.

Export calls must not create VM-global atoms from host export ids, guest source
names, malformed arguments, or error payloads. Unknown export ids are binary
data and must stay outside the atom table. Export argument and result terms
cross the same atom policy and term sanitizer as the entry root, bindings,
filesystem, and stdout.

Stack trimming expectations are the same for the entry root and exports.
`$safe_export/4` and `Hyperlang.run/4` may expose sanitized guest source function names for declared
exports, but they must not leak generated module names, generated helper names,
host stack frames, raw exception structs, pids, refs, ports, or external funs.

Error stacks follow a positive rule. A frame survives only as a guest source
frame (`module: "guest"`, mapped through the stack map; compiler-made helper
names such as `-inlined-f/1-` keep the guest source name and arity) or as a
frame of a guest-callable stdlib MFA such as `erlang:element/2`. Every other
frame is dropped, whatever its module naming scheme: Hyperlang runtime modules
(`Hyperlang.*`, `hyperlang_msg`), vendored formatters, OTP internal helpers and
unmapped generated functions.

Exception messages are guest-visible text and name only guest-level
identifiers. A function-clause message names `guest:F/A` for a guest function,
`M:F/A` for a guest-callable stdlib MFA and "an internal function" otherwise.
Every other message is projected before it crosses: pool atoms render as their
source names, generated slot modules and helper names render as guest names,
and inspected funs, pids, refs and ports render as `#Function<guest>`,
`#PID<redacted>`, `#Reference<redacted>` and `#Port<redacted>`.

## Atom And Term Policy

- Source atoms are source names until after atom-safe parsing and policy
  classification.
- Manifest/preapproved atoms may compile to existing atoms.
- Other source atoms use a bounded Hyperlang-owned pool such as
  `hyperlang_atom_N`.
- Hyperlang creates VM atoms only from its own name families. Guest source,
  guest input and binding returns never name a VM atom. The generated
  families are fixed name sets with host-configured caps (compile-time
  application environment): `hyperlang_atom_N` (`:source_atom_count`,
  default 4,096 per atom universe), `hyperlang_kernel_atom_N`
  (`:kernel_source_atom_count`, 4,096), `safe_f_N` (`:function_atom_count`,
  8,192) and `v_N` (`:variable_atom_count`, 524,288). An atom of a family is
  created the first time any program needs its index, so the table holds the
  high-water mark of real use, not the caps.
- Compiler-made names come from a fixed set. The OTP compiler names the
  functions it makes for funs, comprehensions and receive loops after the
  enclosing function and a per-function counter. Codegen lifts every guest
  fun, named fun, local fun reference, list/binary/map comprehension level
  and receive wait fun into its own function `safe_f_N/2` (`N` past the guest
  functions, closure captures in the second argument), whose whole body is
  that one construct. Generated forms are verified to keep this shape. The
  only compiler-made names are then:
  - `-safe_f_N/2-fun-0-`, `-safe_f_N/2-lc$^0/1-0-` and
    `-safe_f_N/2-lbc$^0/2-0-` for `N` below `:function_atom_count`;
  - `label^K` for the clause splits of binary patterns, `K` below the
    manifest limit `max_pattern_splits` (default 256, at most
    `:pattern_split_count`, compile-time application environment, default
    1,024); codegen refuses a function with more split points;
  - eight fixed names: `lc$^0`, `lbc$^0`, `recv$^1`, two `$safe_entry/3`
    thunks and three `$safe_export/4` thunks.
  Generated functions and funs end in a clause that matches anything (an
  explicit `function_clause` error when the guest clauses can fail), so the
  compiler makes no `-inlined-` fallback names; records lower to tuple
  operations in codegen (no `recN` variables); generated code compiles with
  `no_alias` (no `@rN` variables). Over every program the VM holds at most
  3 x `:function_atom_count` + `:pattern_split_count` + 8 compiler-made atoms
  (25,608 with the defaults), whatever guests submit
  (`GeneratedAtoms.compiler_name_bound/0`).
- Atom-table reserve. Hyperlang never takes the VM atom table to fewer than
  `:atom_table_reserve` free entries (runtime application environment;
  default a quarter of `erlang:system_info(atom_limit)`). Each family atom is
  created only if the table is below that ceiling, and each OTP compile of
  generated code first promises the compiler-made names of its forms that do
  not exist yet (`GeneratedAtoms.compiler_atom_names/1`; concurrent compiles
  see each other's promises). When the ceiling is reached, compilation,
  loading and the kernel bridge fail with a `compile` error "VM atom table
  reserve reached" (the kernel bridge with the term reason
  `atom_table_reserve`). Atoms already created stay; already-loaded programs
  keep running; the host keeps the reserve. With the bounded name set the
  reserve is a backstop: a guest stream reaches it only if the host
  configures the caps above the table's capacity.
- Decisions that depend on whether an atom exists treat every family name as
  absent, materialized or not: the binding compatibility profile keeps such
  literals pooled, and exit reasons keep them as binaries. One guest cannot
  learn another's pool use through atom existence.
- Pool atoms never escape public boundaries as internal names; output, stdout,
  errors, bindings, filesystem calls, and JSON map keys translate them back to
  source names or reject them according to the active term policy.
- The allowed atom universe is fixed by the program's `terms.allowed_atoms`.
  A run's `policy.atoms` defaults to it and may only narrow it; a run that
  names an atom outside the program set fails with a `manifest` error.
- Host input and binding returns cannot create new pooled atoms.
- Pids, ports, external refs, raw funs, improper lists, oversized binaries,
  oversized integers, excessive term depth, and unknown atoms are rejected at
  host-facing boundaries.

## Call Authority

Every call is classified before codegen:

- Local helper call or Hyperlang-created local fun.
- Declared binding export (pinned by the program manifest).
- Frozen allowlisted Erlang/OTP stdlib call.
- Hyperlang-owned filesystem, loader, stdout, or compatibility call.
- Rejected forbidden/dynamic call.

Dynamic `apply`, dynamic `M:F(...)`, process operations, ports, NIF loading,
code loading, ETS/DETS/Mnesia, persistent term, distribution, OS, and raw file
authority are rejected unless Hyperlang owns a specific compatibility surface for
that MFA.

## Stdlib Policy

The stdlib profile is direct OTP passthrough only for a frozen positive MFA
allowlist. Runtime must never auto-admit live OTP exports. Direct stdlib calls
still pass through Hyperlang runtime admission, argument sanitization, external
worker limits, and result sanitization.

Live clocks and entropy are a global nondeterminism capability, not part of the
default deterministic profile. VM time readers such as
`erlang:system_time/0,1`, `erlang:monotonic_time/0,1`,
`erlang:time_offset/0,1`, `erlang:timestamp/0`, `erlang:date/0`,
`erlang:time/0`, `erlang:universaltime/0`, `erlang:localtime/0`,
`calendar:universal_time/0`, `calendar:local_time/0`, and
`calendar:iso_week_number/0`, `sys:millisec/0` (when the `sys` facade is
enabled), local-time-zone conversions such as
`calendar:system_time_to_local_time/2`,
`calendar:system_time_to_rfc3339/1`,
`calendar:local_time_to_system_time/1,2`,
`calendar:local_time_to_universal_time/1,2`,
`calendar:local_time_to_universal_time_dst/1`,
`calendar:now_to_local_time/1`, `calendar:universal_time_to_local_time/1`,
`erlang:universaltime_to_localtime/1`, and
`erlang:localtime_to_universaltime/1,2`, plus seedless entropy readers such as
`rand:mwc59_seed/0`, require `capabilities.nondeterminism`.
`calendar:system_time_to_rfc3339/2` runs without the capability only with an
explicit `{offset, Offset}` option (an integer or a non-empty string); without
it OTP formats in the host time zone, and the call fails as a `stdlib` error.
Deterministic UTC time conversions, pure `erlang` term operations, and
`sys:sleep/1` remain admitted without that capability. Guest table handles
(`hyperlang_table:new/1,2`) count from 1 per run, so they carry no node-wide
counter value. `rand:seed_s/1,2` remains rejected until Hyperlang has a safe PRNG
state wrapper; OTP's raw state contains function values that cannot cross the
guest boundary.

Binding exports marked `nondeterministic: true` are also rejected unless the same
capability is enabled. This keeps the deterministic/replay profile enforceable
across both stdlib calls and host authority.

Runtime-owned stdlib vocabulary atoms are merged into the allowed atom set when
stdlib is enabled. This includes option atoms and OTP return tags such as
`value` and `empty`, so admitted stdlib functions can be pattern-matched with
normal Erlang terms without consuming guest atom-pool entries.

`re:run/*`, `re:replace/*`, and `re:split/*` automatically receive Hyperlang
`match_limit` and `match_limit_recursion` options; guest-provided limits are
stripped and replaced. `re:run/*` rejects `{capture, all_names}` because OTP
materializes named capture keys as VM-global atoms.

Raw OTP JSON encoders such as `json:encode/*`, `json:format/*`, and
`json:encode_atom/2` remain rejected because they can stringify arbitrary atoms
or unsupported terms. A host that needs JSON encoding provides it as a binding
or as a verified guest library module; Hyperlang has no runtime stdlib wrapper
for it.

Callbacks must be Hyperlang-created lexical funs. External captures such as
`fun maps:get/2` and host funs cannot cross guest boundaries.

## Stdout And Errors

Supported `io:*` stdout calls append sanitized chunks that `Hyperlang.run/4`
returns as `meta.stdout`.
No host IO device is exposed. `io:format/3` is accepted only for supported
standard devices such as `standard_io`. Captured stdout formatting sanitizes
the format and argument terms first, then renders through vendored, renamed OTP
`io_lib`, `io_lib_format`, `io_lib_fread`, and `io_lib_pretty` sources rather
than ambient host `io_lib`. Guest `io_lib:format/2,3`, `io_lib:fwrite/2,3`,
`io_lib:bformat/2,3`, `io_lib:bfwrite/2,3`, `io_lib:build_text/1,2`, and
`io_lib:format_prompt/1,2` are admitted only through the same Hyperlang
wrapper: formatted terms cross the same walk as captured stdout (funs, pids,
refs and ports fail as a sanitized `stdlib` error, so no generated slot module
is ever rendered), pooled atom names are projected before formatting, the only
accepted option is the closed `{chars_limit, N}` shape, and charlist/binary
output is checked against manifest limits. Other admitted `io_lib` helpers
remain direct OTP passthrough only where the frozen stdlib matrix classifies
them as pure text/term helpers; atom writers, read parsers, raw format
scanners, and device-facing entrypoints remain rejected.

Stdlib helpers that render an atom argument by its name are Hyperlang
wrappers: `filename:*` and `lists:concat/1` receive pooled atoms as their
source names, so their results match OTP on the source atom and never carry
`hyperlang_atom_N` text.

Float textification is an explicit Hyperlang wrapper, not an ambient OTP
passthrough. `float_to_binary/1,2` and `float_to_list/1,2` accept only the
closed option vocabulary `compact`, `short`, `{decimals, N}`, and
`{scientific, N}` after translating guest atom-pool names back to OTP atoms.
Option-list length and precision are bounded before OTP is called, and the
result is checked against the manifest binary/list limits. Unsupported option
names fail as `badarg` without creating VM-global atoms.

Device-form `io:*` remains non-ambient. Hyperlang accepts write-oriented device
calls only when the device term is an opaque guest file handle opened by the
safe `file:*` facade. Supported device calls are `io:put_chars/2`,
`io:nl/1`, `io:format/3`, `io:fwrite/3`, and `io:write/2`. File-server backend
handles are not host IO devices, and unsupported devices raise sanitized stdout
errors. Input and device-control calls remain rejected, including
`io:get_chars/*`, `io:get_line/*`, `io:read/*`, `io:request/*`, and
`io:requests/*`.

Guest `try ... catch C:R:S` stack variables are sanitized to `[]`. Stack
variables are not available in catch guards. Runtime error stacks expose only
sanitized guest frames unless trusted debug tooling explicitly opts into more.

Plain `try ... catch` is supported because compile-time verification still walks
the protected body and catch clauses before guest code can handle exceptions.
`try ... of ... catch` is supported with separate verified `of` and `catch`
clauses and emits a BEAM `try` with distinct of/catch clause lists. As in
Erlang, catch clauses protect only the pre-`of` body; `of` clause mismatch and
`of` clause body errors are not caught by that same catch.

Disallowed atom details in errors are redacted so internal pool/sentinel atoms
cannot leak through error payloads.
Binding exceptions are normalized to sanitized `import` error classes before
crossing the sandbox boundary.

Hyperlang has a closed public fault taxonomy. Primary error categories returned
by `Hyperlang.program/1,2` and `Hyperlang.run/4` (and therefore by every
`Hyperlang.module/1` callback) must be one of:

- Parse, verification, and compiler setup faults: `api`, `source`, `lexer`,
  `parse`, `manifest`, `verify`, `codegen`, `generated_form_verify`,
  `compile`, `compile_budget`, `internal_compile`, `compile_timeout`, `load`,
  `code_pool`, and `lifecycle`.
- Admission and scope termination faults: `busy`. Reasons include
  `queue_full`, `wait_timeout`, `admission_cycle`, `scope_closed` (explicit
  close or owner exit), and `scope_terminated` (resource enforcement). Public
  errors carry these sanitized reasons in `details["reason"]` and `message`.
  Per-call termination markers survive scope-name reuse; scope closure is
  never inferred as a per-worker heap failure.
- Guest execution and boundary faults: `input`, `output`, `stdout`,
  `runtime`, `eval`, `export`, `import`, `stdlib`, `filesystem`, `loader`,
  `module`, `timeout`, `heap`, `reduction_watchdog`, `sandbox_crash`, and
  `internal`. The `module` category covers code-path module loading
  (verification failure, capability not granted, load cycles, and module
  binding limits); missing files, wrong
  `-module` names, and unexported functions stay Erlang-shaped `undef`.

Worker exits, wall timeouts, heap kills, reduction watchdog exits, verifier
failures, output/stdout sanitizer failures, binding failures, stdlib wrapper
failures, filesystem failures, host syscall boundary failures, loader failures,
and export dispatch failures must map to that set. Unknown primary categories
are collapsed to `internal` with reason `unknown_fault_category`.

Internal sanitizer labels such as `error`, `import_args`, `import_return`,
`filesystem_args`, `filesystem_return`, `loader_args`, `loader_return`,
`stdlib_args`, and `stdlib_return` are implementation boundary labels. They
may appear as sanitized nested detail data or direct internal API results, but
they are not public guest fault categories.

The same taxonomy applies to the `result/1` entry root, manifest-declared
exports, and OTP callbacks. Error sanitization must never expose pids, ports, references, funs,
worker state, generated slot module names, generated helper names, raw host
stack frames, backend state, or host filesystem paths.

## Filesystem Capability

Filesystem access is optional Hyperlang-owned compatibility, not direct stdlib.
Guest code writes standard Erlang `file:*` and `filelib:*`; the compiler lowers
supported calls to internal filesystem dispatch.

Supported filesystem operations use virtual paths, mount permissions, byte and
entry limits, safe term boundaries, and sanitized OTP-shaped results/errors.
Unsupported operations return compile-time capability diagnostics.

The supported common `file:*` subset is `read_file/1`, `write_file/2,3`,
`list_dir/1`, `make_dir/1`, `del_dir/1`, `delete/1`, `rename/2`,
`read_file_info/1`, `read_link_info/1`, and, when handle compatibility is
enabled, sequential `open/2`, `read/2`, `write/2`, and `close/1`. Handles are
opaque guest terms and must not reveal pids, refs, fids, or host descriptors.

Hyperlang keeps the mediated `file_server` backend for this facade. It retains
source snapshots, export/materialize, transaction snapshots, cwd, `filelib:*`,
`file:consult/1`, and `file:path_consult/2` compatibility. A host may instead
supply a Plan 9 syscall facade through `sys:*` (the companion OS hyperbob_os
does). Backend and syscall-facade selection are host/runtime configuration,
not guest source behavior.

Unsupported or deferred OTP file operations include ambient raw `file:*`,
`prim_file:*`, symlink or hard-link creation, BEAM binary loading,
`file:script`, `file:eval`, and OTP private `file_request` operations such as
`pread`, `position`, `sync`, and `truncate`. Namespace access through a
`sys:*` syscall facade uses absolute Plan 9 paths; cwd and `filelib:*`
compatibility remain `file_server` backend behavior.

Existing symlinks may be followed by read/stat operations and listed according
to standard Erlang host semantics. Guest-visible APIs do not expose symlink or hard-link creation.
Host-backed mount roots must be chosen with that explicit trust model in mind.

Host paths, device ids, inodes, uid/gid, raw timestamps, pids, ports, raw IO
devices, and host file descriptors must not appear in guest results, stdout, or
errors.

## Source Loading Compatibility

Files can store Erlang source, but bytes do not become authority by being
writable. Source compilation and loader/evaluator compatibility must go through
Hyperlang's parser, verifier, codegen, code slots, atom policy, bindings, stdlib
profile, filesystem capability, and limits.

Hyperlang must not dispatch to ambient OTP `code`, `compile`, `erl_eval`,
`file:script`, `file:eval`, `file:consult`, BEAM binary loading, or generated
module MFA loading as a shortcut.

## OTP Compatibility Baseline

OTP release: 29

### Source References

| Key | OTP app | Source path | Role |
| --- | --- | --- | --- |
| `file` | `kernel` | `kernel/src/file.erl` | filesystem compatibility |
| `filelib` | `stdlib` | `stdlib/src/filelib.erl` | filesystem compatibility |
| `file_hrl` | `kernel` | `kernel/include/file.hrl` | filesystem metadata shape |
| `io_lib` | `stdlib` | `stdlib/src/io_lib.erl` | stdout formatting compatibility |
| `io_lib_format` | `stdlib` | `stdlib/src/io_lib_format.erl` | stdout formatting compatibility |
| `io_lib_fread` | `stdlib` | `stdlib/src/io_lib_fread.erl` | stdout formatting compatibility |
| `io_lib_pretty` | `stdlib` | `stdlib/src/io_lib_pretty.erl` | stdout formatting compatibility |
| `filename` | `stdlib` | `stdlib/src/filename.erl` | path string helpers |
| `compile` | `compiler` | `compiler/src/compile.erl` | loader/evaluator compatibility |
| `code` | `kernel` | `kernel/src/code.erl` | loader/evaluator compatibility |
| `erl_eval` | `stdlib` | `stdlib/src/erl_eval.erl` | loader/evaluator compatibility |

### Vendored Sources

| Key | Vendored path | SHA-256 |
| --- | --- | --- |
| `file` | `vendor/otp_kernel_11_0_2/src/file.erl` | `a8fdd9f93bede84b1d1d00ffa92163826dc452703f50da12a85c2a8d82058e04` |
| `filelib` | `vendor/otp_stdlib_8_0_1/src/filelib.erl` | `e9952a847dc0ee2f5bd1f95ee6c44a90f740156153babcca8114d9933c90c398` |
| `file_hrl` | `vendor/otp_kernel_11_0_2/include/file.hrl` | `4c7ed0e4cc09c454f65c0bf0528e6e56d94ab309e232a4e25db9a486df950299` |
| `io_lib` | `vendor/otp_stdlib_8_0_1/src/io_lib.erl` | `b6da306a37f9ddb4fad3779e65f154f09815cc1ebeb7fca991983033d92fc7c6` |
| `io_lib_format` | `vendor/otp_stdlib_8_0_1/src/io_lib_format.erl` | `8ecbee07d2a39edf081e2888ddb47e8fdfc4b58ee452dd34306e1d1d3cf32c7f` |
| `io_lib_fread` | `vendor/otp_stdlib_8_0_1/src/io_lib_fread.erl` | `d66c2e6b4617bcbd7c497d46830947a90903851c0b1d07ad8369ca0d3004eed3` |
| `io_lib_pretty` | `vendor/otp_stdlib_8_0_1/src/io_lib_pretty.erl` | `c489356b654c63453ef217bf73235ab7f2df1e99fe5cdd8b0424461d860d910b` |

Regenerate candidate vendored sources with `scripts/update_otp_filesystem.sh`,
regenerate stdout formatting sources with `scripts/update_otp_formatting.sh`,
and verify generated module equivalence with `scripts/diff_otp_formatting.sh`;
then update `Hyperlang.CompatibilityBaseline` and this specification if hashes
change.

## Rejected Surfaces

The following classes are rejected unless an explicitly Hyperlang-owned
compatibility path exists:

- Process creation, linking, monitoring, registration, send, receive, process
  dictionary, tracing, scheduler/process inspection, and group leaders.
- Raw filesystem, OS, socket, port, distribution, storage, ETS/DETS/Mnesia,
  persistent term, RPC, global, and pg authority.
- Dynamic code loading/evaluation and raw compiler/code server entrypoints.
- Atom-creating conversions such as `list_to_atom/*`,
  `binary_to_atom/*`, and ambient parser helpers.
- External funs, dynamic remote calls, dynamic `apply`, raw BEAM resources, and
  unsupported opaque state terms.

## Known Limitations

Hyperlang is a same-VM boundary. Authority isolation holds for untrusted
guest source; resource isolation is bounded by the shared VM. An isolation
verification of this release measured the following residual effects:

- Shared node resources. All guests share BEAM schedulers, memory allocators,
  the garbage collector and the code server. Distinct scopes do not create
  OS-level separation.
- Heap-pressure latency. With 16 heavy tenants and scope controls on, victim
  p99 latency stayed within 1.33x of baseline under CPU load and 1.04x under
  compile load. Under heap pressure the factor was 1.29x, 2.30x and 15.87x in
  three trials, so the heap-pressure bound is not reliable.
- Channel contention. Scope-local quota controllers and their counters rows
  remove per-allocation/free traffic from shared Scope. Channel-only
  sampling stays local; rate/churn policies and heap violations report for
  enforcement. Registry retains one owner for atomic alias/fork/cleanup and
  charges measured hot metadata work to the allocating scope. Free releases
  logical aliases and quotas before physical retirement completes; trusted
  close hooks can delay cleanup.

  The R2-4 bound (`test/isolation/round2_stress_test.exs`) is: with 64
  channel tenants on four schedulers, a latency-class victim's p99 is at most
  three times its p99 with no tenants. The measurement
  (`Hyperlang.Isolation.Contention.paired/2`) is:
  - Interleaving. Unloaded and loaded blocks of 250 requests alternate in
    ABBA order, 5,000 requests per cell. Each loaded block starts 64 fresh
    tenants and stops them afterwards. Each block starts on a VM with no
    other runnable process for 1 ms, and its first 20 requests are not
    recorded.
  - Stall exclusion. A max-priority ticker bound to each scheduler measures
    its 1 ms timer delay against the timer's millisecond boundary. A
    request that overlaps a delay of 500 microseconds or more on any
    scheduler is excluded. Run-queue and server queueing cannot delay a
    max-priority tick, so they stay in the kept requests.
  - CPU-share exclusion. A loaded block is excluded when the operating
    system gave the VM less than 75 percent of the time its schedulers were
    busy (user plus system CPU time from `ps`, divided by
    `scheduler_wall_time` active time).
  - Validity. A trial fails as uninformative when either cell keeps fewer
    than 2,500 requests.
  The channel64 trial test runs three fresh trials; the matrix test asserts
  one paired cpu64 trial and one paired channel64 trial, and records its
  sequential rows as evidence only.

  Three BEAM-side waits on the victim path were removed. The local resume
  check called `Process.alive?/1` on Scope, which waits for a busy Scope to
  handle a signal. A latency caller dropped to `normal` before its flushing
  demonitor, which can reschedule it behind every runnable process. Registry
  served dozens of requests per time slice and held a scheduler for up to
  about 300 microseconds. In interleaved runs against the previous code on
  the same harness at load average 5, channel64 p99 ratios were 2.20x-2.31x
  (previous code 3.45x-3.81x). In ten consecutive runs of each R2-4 test at
  load average 4-7, every trial passed: channel64 2.03x-2.58x, cpu64
  1.09x-1.31x. Registry's yield lowered aggregate 64-tenant channel
  allocation/free throughput by about 11 percent and single-tenant
  throughput by about 2 percent.

  The bound depends on host CPU headroom. On the 16-core development host,
  four busy scheduler threads received 74-92 percent of their CPU time at
  load average 6 and 38-75 percent at load average 10-16. A loaded block's
  p99 rises as its CPU share falls (about 250-350 microseconds at 0.8-0.9,
  600-2,200 microseconds at 0.4-0.6). At load average 12 and above most
  trials keep too few loaded blocks and fail as uninformative; the BEAM
  cannot bound that delay.
- Receive selection. Matched and timeout bodies reacquire before execution.
  The native selective-receive matcher and guards in a long wait still run
  before continuation reacquisition. Strict permit coverage of that selection
  work remains incomplete.
- Native work. Some native calls do not yield to the scheduler. A guest
  `binary:copy/2` of 32 MB plus result sanitization ran for about 163 ms
  before it could be stopped. Suspension or exit signals do not interrupt
  native work or garbage collection. Five other large native expressions
  (`phash2`, bignum arithmetic, `re:run`, `unicode`, `io_lib:format`) were
  stopped within about 3.5 ms, which does not establish universal
  preemption.
- Sampled enforcement. CPU, heap and churn enforcement samples process
  state and allows bursts. Churn counts sampled heap growth and minor
  collections plus a conservative charge of the committed heap allowance; it
  is not an exact allocator counter.
- Compile budget. Reductions measure executed Erlang code and charged BIF
  work. Native work that executes few reductions is bounded only by the wall
  backstop and the compile heap cap. Process inspection and the kill signal
  both wait until a non-yielding native call returns. Superlinear compiler
  passes are bounded by the budget, not removed: a single guard with 1,600
  `orelse` terms needs about 600,000,000 reductions in the OTP compiler and is
  admitted only when the host raises both the structural limits and the
  budget. Generated-code loads are serialized in one code server; a load that
  waits behind other loads is not charged.
- Wall precision. Deadlines use per-run timers. A 1 ms deadline overshot by
  1.08 ms at p99 on an unloaded node, but another trial on a shared machine
  overshot by 16 ms. This is not a hard real-time guarantee.
- Timer precision. Guest timers are BEAM timers, so expiry time follows the
  node's BEAM timer service and OS scheduling. On a saturated host, bare BEAM
  21 ms timers fired up to 187 ms late in an empty BEAM and up to 231 ms late
  in a Hyperlang node. In the same trials, Hyperlang delivery added at most
  0.13 ms after expiry. This is not a hard real-time guarantee.
- In-caller execution. Scope violations are reported when trusted host work
  returns. Scope enforcement cannot forcibly interrupt a host callback while
  preserving its process. Per-worker wall, reduction and heap limits are
  separate controls. In-caller wall/reduction expiry is recorded and returned
  when control comes back, preserving the trusted host process; hosts requiring
  preemptible execution should use child workers. Engine-owned OTP actor
  callbacks keep terminating budget enforcement and scope-close semantics. Trusted host channel/timer allocation is outside guest runnable
  admission and can still contend on shared services. Priority mailbox lanes
  protect latency-class scope requests from its queued background bookkeeping.
- Code-slot pins and pool sharing. Pinned slots are bounded by the code pool,
  and per scope by `max_code_pins`, but the code pool and its `code_pool`
  windows are shared: scopes whose actors pin every slot of a window starve
  later loads in that window of other scopes. Bound each scope's
  `max_code_pins` so that the scopes sharing a window cannot pin all of it.
  Actors without an explicit `spec.policy.scope` each own a scope and so are
  bounded only by the pool. A leaked actor holds its slot until it exits.
- Module names before an actor starts. `Hyperlang.module/1` returns the
  slot's module name; the slot is not pinned until an actor's `init/1` runs.
  If the slot is released or reclaimed in between, starting the actor fails
  (`undef` when the slot is free, or the slot's new program when another
  program reused it). Start actors right after `module/1`.
- Per-call floor. Every run and actor callback waits for one Scope admission
  call (the lease, the membership and the runtime lifetime); a spawned run
  also waits for its worker's attach call. This server work, not the guest,
  dominates calls into tiny guests.
- Host responsibilities. Hosts choose scope identities, lifetimes and
  budgets, namespace their own cache keys, and own explicitly host-metered
  children. Quotas cover managed guest, compile and channel processes, not
  arbitrary trusted binding work.
- Atom table. Guest code creates VM atoms only from the generated families
  and the fixed compiler-name set. With the default caps that is at most
  4,096 + 4,096 + 8,192 + 524,288 + 25,608 = 566,280 atoms over the life of
  the VM, below the default reserve ceiling of 786,432 (a 1,048,576 table
  with a quarter reserved), so with default configuration a guest stream
  cannot reach the reserve while the host's own atoms stay under about
  220,000. The `v_N` family dominates that bound because `max_tokens` may be
  raised up to it. A host that raises the caps or runs with a smaller `+t`
  must keep the sum below its ceiling; otherwise a guest stream can still
  reach the reserve, and every later compile or first load that could create
  atoms fails with "VM atom table reserve reached" until the VM restarts.
  BEAM atoms are never collected.
- Live values outside the nondeterminism gate. Some guest-visible values still
  depend on host state without `capabilities.nondeterminism`: start-channel
  handles (`sys:startchan/0`) and guest timer ids are random, channel handles
  come from one node-wide counter, `sys:alt/1` picks among ready arms at random
  (Dis alt semantics), and `erlang:read_timer/1` / `erlang:cancel_timer/1`
  return the remaining milliseconds of a guest timer. Timers need a
  host-installed message policy; channels need a host channel scope.
- Not covered by the isolation verification: authority escapes, host
  filesystem and compiler escape variants. The sandbox probes in
  `test/sandbox` cover those surfaces.

## Verification

Security-sensitive changes must keep `mix test` green. Tests cover atom growth,
forbidden calls, source snapshots, stdlib matrix admission, filesystem behavior,
stdout capture, error redaction, worker termination, binding pinning and
sanitization (`test/door_authority_boundary_test.exs`), the actor path
(`test/durable_actor_test.exs`), scopes (`test/scope_test.exs`), the sandbox
boundary probes (`test/sandbox`: code-generation escape, verifier/codegen
agreement, atom and term policy, bindings, cross-guest isolation, channels,
the `sys` facade, filesystem and loader, error/stdout leaks, and chaining of
known internal names), and the isolation properties above
(`test/isolation/findings_test.exs`). The measurement probes in
`test/isolation` and the fuzz campaigns in `test/sandbox` are opt-in:

```bash
mix test test/isolation --include isolation_stress --include isolation_finding
HL_FUZZ_SEED=20261025 HL_FUZZ_MUT_SEED=77777 HL_FUZZ_N=2000 HL_FUZZ_MUT_N=800 \
  mix test test/sandbox/fuzz_probe_test.exs --include sandbox_fuzz
```
