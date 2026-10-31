# Changelog

## 0.2.0

### Public API

- **Breaking:** `Hyperlang.module(program)` is removed. It returned a code-slot
  module name that was not pinned until an actor's `init/1` ran. A release
  or reclamation in between made the start fail with `undef`, or made the
  actor run another program that had reused the slot.
- `Hyperlang.Actor` is the public `GenServer` callback module for program
  actors. Its init argument is `{spec, program, arg}`, and `child_spec/1`
  takes the same tuple (id `Hyperlang.Actor`, restart `:permanent`; give
  each of several actors under one supervisor its own id with
  `Supervisor.child_spec/2`). The actor's `init/1` loads the program and
  pins its slot in one step, so the actor always runs exactly that program.
  Bad init arguments stop it with `{:hyperlang, %{category: :api}}`.
- Migration:
  `GenServer.start(Hyperlang.module(program), {spec, arg})` becomes
  `GenServer.start(Hyperlang.Actor, {spec, program, arg})`, and
  `GenServer.start_link` likewise.
- `Hyperlang.load/1` loads a program ahead of its first use and returns
  `:ok` or `{:error, sanitized_error}`. Migration: a preloading
  `Hyperlang.module(program)` call becomes `:ok = Hyperlang.load(program)`.

### Behaviour

- Generated modules no longer export OTP callbacks; `GenServer.start/2` on
  one fails with `undef`. An actor's process module is `Hyperlang.Actor`.
- An actor calls `handle_info/2` and `terminate/2` only when the program
  exports them. A message to a program without `handle_info/2` is dropped
  without a log entry. A missing `handle_cast/2`, `handle_call/3` or
  `handle_continue/2` stops the actor with the typed `run/4` error
  (`category: :export`) instead of `undef`.
- An actor's `init/1` no longer stops with `code_pool` `not_loaded`. It stops with
  `code_pool` when the program's window has no free slot, or with
  `pin_limit` at the scope bound (checked before any load).
- The compile for a load done by `init/1` is charged to the actor's scope.

### Isolation verification

- Heap pressure has a tested bound: with 16 heap-pressure tenants in
  `:background` scopes with a churn quota, the latency-class victim's p99
  stays within 3x its unloaded p99. The R2-4 paired measurement now spreads
  loaded blocks over a whole quota refill period, so rate-limited bursts are
  measured.
- Corrected noisy-neighbour figures. The sequential matrix and the comparison
  bench sampled the victim only before the first quota refill, so they never
  saw the noisy tenants' refill bursts. Requests are now spread evenly over
  four refill periods. With 16 tenants in background scopes the victim's p99
  slowdown is 1.7x (CPU), 2.1x (heap) and 1.9x (compile), and the comparison
  figure is 1.65x; 0.1.0 published 1.1x, 1.1x, 1.0x and 1.37x.

### Package

- The Hex package links to this changelog.

## 0.1.0

First public release.

### Public API

The door:

- `Hyperlang.program/1`: compile an immutable source value into a
  `%Hyperlang.Program{}`.
- `Hyperlang.program/2`: return a program cached under a caller-owned key and
  call the loader only on a miss.
- `Hyperlang.run/4`: run one declared export with the authority in a spec.
  Success is `{:ok, value, %{stdout: [binary], reductions: integer,
  wall_us: integer}}`; failure is `{:error, sanitized_error}` with a category
  from the closed fault taxonomy.
- `Hyperlang.module(program)`: return the confined OTP callback module of a
  program.

Host contracts and tools:

- `Hyperlang.Program`: the opaque, content-addressed program struct.
- `Hyperlang.Binding`: behaviour for host capabilities (`exports/0`,
  `call/3`). Export options are `limits`, `nondeterministic`, `effects` and
  `docs`.
- `Hyperlang.SyscallHost`: behaviour for the `spec.syscall` door behind the
  guest `sys:*` facade (`syscall/3`, optional `opaque_spawn_args?/1`), plus
  `normalize/2`, `get_state/0` and `put_state/1`.
- `Hyperlang.Scope`: host-selected resource scopes (`configure/2`,
  `with_scope/2`, `current/0`, `close/1`, `stats/1`). A scope bounds
  concurrent runs and compiles, queues admission, sets the priority class,
  caps aggregate heap, and charges channels, buffers and timers.
- `Hyperlang.Limits`: process-group reduction, ceiling and wall-deadline
  metering for host spawn hooks (`group/1`, `limit/2`, `attach/3`,
  `detach/2`, `detach_children/1`, `delete/1`, `stat/1`).
- `Hyperlang.Chan`: typed channels for syscall hosts.
- `Hyperlang.Check`: static whole-image checking of multi-module guests.
- `Hyperlang.Manpage`: troff man(2) pages for allowlisted stdlib modules.
- `Hyperlang.Test`: test kit (`program/2`, `program!/2`, `run/4`, `run!/4`,
  `start_actor!/3`, `assert_stdout/2`).

Manifest keys (atoms only; unknown keys are rejected): `entry`, `result`,
`exports`, `bindings`, `limits`, `terms`, `stdlib`, `syntax`,
`capabilities`, `profile`, `code_pool`, `sys`, `modules`, `filesystem`,
`tables` and `atom_universe`.

Run spec keys: `bindings`, `policy` and `syscall`. Policy covers
`max_reductions`/`budget`, `heap_words`, `wall_ms`, `atoms`, `scope`, and
actor-lifetime `rate` and `ceiling`.

Other modules are internal and are not covered by version guarantees.

### Isolation guarantees

- Each run gets fresh reduction accounting, and run-owned guest children
  are killed when it ends. A spawned run's limits group is destroyed with
  the run; the in-caller runs of one process (all callbacks of one actor)
  share one group whose usage restarts with every run.
- Wall deadlines use a per-run timer, not a polling tick.
- Timer quotas and handles are keyed by host scope. Handles are random
  128-bit integers, and cross-scope read or cancel returns `false`.
- Channels, buffers and broker heaps are charged against scope quotas and a
  live owner.
- A live OTP actor pins its program's code slot until it exits, so its
  callback module never unloads under it. Pins are charged to the actor's
  scope and bounded by the scope policy `max_code_pins`.
- OTP actor status and crash reports always go through the host redactor.
- Guest mailboxes are on-heap.
- Internal fun application checks fun provenance.
