# Hyperlang

Hyperlang runs untrusted Erlang inside an Elixir host, on the same BEAM, with
no ambient authority. A guest is ordinary Erlang source. Hyperlang compiles
it through its verifier into a BEAM module that can call only its own
functions, a frozen stdlib allowlist and the host bindings you pass in. Every run is metered for
reductions, heap and wall time. Host-owned scopes admit and prioritise the
work.

The Erlang/OTP secure-coding guide says there is "no built-in sand-boxing
mechanism for running untrusted Erlang code", and the EEF advises an embedded
language such as Lua. Teams therefore use Luerl, WebAssembly, a restricted
evaluator, or a separate node or OS process. Hyperlang guests still share
schedulers, memory allocators, the atom table and the code server. Hyperlang
adds three properties:

- Guest code never becomes trusted loaded code.
- Every atom a guest can cause comes from a fixed set bounded by host limits.
- The generated module cannot express calls outside the declared set.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/comparison_dark.svg">
  <img alt="Hyperlang against wasmex, Luerl and Dune, with erl_eval, peer nodes, OS processes and Docker as unsandboxed references. fib(25): Hyperlang 0.35 ms, wasmex 0.68 ms, interpreters 85 to 275 ms. Idle actor memory: Hyperlang 23 KiB, others 71 to 109 KiB. Noisy-neighbour p99 slowdown: Hyperlang 1.65x, Luerl 3.0x, Dune 35.7x. Tenant start from a compiled program: Hyperlang 0.05 ms, Luerl 0.03 ms, child VM about 115 ms." src="assets/comparison_light.svg" width="960">
</picture>

Measurements are from one shared 16-core host (BEAM with 4 schedulers, load
average 9 to 32). Method and raw data are in
[`doc/COMPARISON.md`](doc/COMPARISON.md). Among the BEAM sandboxes (wasmex,
Luerl, Dune), Hyperlang is fastest, smallest and least disturbed by noisy
neighbours:

- **Compute:** guest code is compiled BEAM code. A guest `fib(25)` took
  0.35 ms. Native Erlang in a peer node or OS process took 0.33 to 0.38 ms,
  wasmex 0.68 ms, and Luerl, `erl_eval` and Dune 85 to 275 ms.
- **Memory:** an idle guest actor added 23 KiB of resident memory. A Rust
  wasmex instance added 89 KiB, a Luerl state 71 KiB, a Dune session
  109 KiB, and a peer node or OS `erl` process 74 to 76 MiB.
- **Noisy neighbours:** next to 16 CPU-bound tenants, a victim's p99 rose
  1.6x with `Hyperlang.Scope` admission and priority classes, 3.0x in Luerl,
  7.4x in `erl_eval` and 36x in Dune. A victim in its own peer node rose 1.1x.
- **Tenant start:** a new tenant of a compiled program answered in 0.05 ms.
  Luerl took 0.03 ms, wasmex 0.08 ms and Dune 0.41 ms. A peer node or OS
  process took 111 to 123 ms to boot. Compiling a small program from source
  is a separate one-time step of about 17 ms.

Each call into a guest costs about 21 µs for a `run/4` in the caller and
29 µs for an actor call. For many tiny calls, wasmex and Luerl in the caller
are faster.

### Code you do not fully trust, inside the VM

Agent systems run partly trusted code: code the agent wrote, tools and
plugins, per-tenant logic, and agent steps that untrusted input (prompt
injection, poisoned tool output) can steer. None of it should hold ambient
authority. A bad step must not reach the host, other tenants, or capabilities
it was not given. Agents are long-lived, stateful, concurrent and supervised,
which BEAM processes and OTP provide. Current agent sandboxes run
outside the VM: E2B uses Firecracker microVMs, AutoGen uses Docker
containers, and Cloudflare loads V8 isolates
([sources](doc/COMPARISON.md#partial-trust-in-agent-systems)). Hyperlang runs
these steps inside the VM as capability-scoped, metered guest actors written
in ordinary Erlang. [Running a generated tool](#running-a-generated-tool)
shows an example.

### Why the guest language is Erlang

Compiling Elixir runs Elixir. Module bodies, attributes, macros, `use` and
`@before_compile` hooks execute during compilation, with the host's authority
and no time bound. A sandbox that checks Elixir source from outside must
either forbid those constructs or run untrusted code while compiling. Erlang
source runs no user code at compile time. Hyperlang runs no preprocessor,
rejects `-include`, `-define`, `-compile` and `-on_load`, and meters its own
compile with a reduction budget. The sound path to sandboxed Elixir is to run
the Elixir compiler itself as a guest
([design](doc/COMPARISON.md#the-sound-path-to-sandboxed-elixir)). If you want
to work on that, see [`CONTRIBUTING.md`](CONTRIBUTING.md).

### How it compares

| | Hyperlang | Dune | Luerl | `erl_eval` + handler | wasmex | Peer node / OS process |
| --- | --- | --- | --- | --- | --- | --- |
| Guest language | Erlang | Elixir subset | Lua | Erlang | Wasm | Any |
| Ambient authority | None | AST allowlist + run-time check | Lua globals removed | **`os:cmd/1` ran** | Declared imports only | **Full** |
| VM atoms added by guest | 0 after warm-up | +1,314, then 0 | +13 for 50,000 keys | **+2,000 per program** | None | Own table |
| 80 MB heap cap held | Yes (39 ms) | **No: +270 MB, 1.3 s** | If the host sets it | If the host builds it | Yes | OS limits only |
| Guest outlives its caller | No | No | **Yes, past `max_time`** | **Yes, unlinked spawn** | Until call timeout | n/a |
| `fib(25)` | 0.35 ms | 275 ms | 85 ms | 106 ms | 0.68 ms¹ | 0.33–0.38 ms¹ |
| Memory per idle tenant | 23 KiB | 109 KiB | 71 KiB | 23 KiB | 89 KiB (Rust guest) | 74–76 MiB |
| Tenant start, compiled program | 0.05 ms | 0.41 ms | 0.03 ms | 0.007 ms | 0.08 ms | 111–123 ms |

¹ Runs on its own threads or VM, so compare with care. Evidence for every
cell (probes, measurements, sources) is in [`doc/COMPARISON.md`](doc/COMPARISON.md).
Guests share the VM's schedulers, allocators, garbage collector and code
server; the [threat model](#threat-model) states what that leaves.

### Running a generated tool

An agent wrote this tool at run time. Its only authority is the host-declared
`search:query/1` binding. A step that calls the operating system fails to
compile. A step that never ends stops at its reduction budget.

<!-- hyperlang:example run -->
```elixir
defmodule Readme.Search do
  @behaviour Hyperlang.Binding

  @impl true
  def exports, do: [query: 1]

  @impl true
  def call(%{docs: docs}, :query, [term]), do: Enum.filter(docs, &String.contains?(&1, term))
end

manifest = %{bindings: %{"search" => Readme.Search}, terms: %{public: :erlang}}

spec = %{
  bindings: %{"search" => {Readme.Search, %{docs: ["BEAM schedulers", "BEAM atoms are not collected"]}}},
  policy: %{max_reductions: 1_000_000, wall_ms: 100, heap_words: 100_000}
}

tool = ~S"""
-module(tool).
-export([result/1]).
result(Term) -> [D || D <- search:query(Term), byte_size(D) < 20].
"""

{:ok, program} = Hyperlang.program(%{entry: "tool.erl", files: %{"tool.erl" => tool}, manifest: manifest})
{:ok, ["BEAM schedulers"], _meta} = Hyperlang.run(spec, program, :entry, ["BEAM"])

shell = "-module(shell).\n-export([result/1]).\nresult(Cmd) -> os:cmd(Cmd).\n"
{:error, [%{category: :verify} | _]} =
  Hyperlang.program(%{entry: "shell.erl", files: %{"shell.erl" => shell}, manifest: manifest})

loop = "-module(loop).\n-export([result/1]).\nresult(X) -> result(X).\n"
{:ok, looping} = Hyperlang.program(%{entry: "loop.erl", files: %{"loop.erl" => loop}, manifest: manifest})
{:error, %{category: :reduction_watchdog}} = Hyperlang.run(spec, looping, :entry, [0])
```

## Hyperlang 101

The model maps onto Cloudflare Workers: a program is a Worker script, a run
is a request, bindings are `env`, and a callback actor is a Durable Object.
This guide pairs each Workers concept with its Hyperlang equivalent. The
JavaScript blocks are Cloudflare reference code. Every Elixir block runs as
written; `test/readme_examples_test.exs` extracts and executes them.

The security contract is [`doc/SECURITY_SPECIFICATION.md`](doc/SECURITY_SPECIFICATION.md).
To report a vulnerability, see [`SECURITY.md`](SECURITY.md). The companion
project hyperbob_os is an OS-scale host on Hyperlang: a BEAM port of the
Inferno OS that runs its userland as Hyperlang guests.

## Install

Add `{:hyperlang, "~> 0.2.0"}` to `deps` in `mix.exs` and run `mix deps.get`.

Hyperlang needs Erlang/OTP 29 and Elixir 1.20 or later. The stdlib allowlist
and the vendored OTP sources are pinned to OTP 29. Later OTP releases are
untested.

## Threat model

Hyperlang enforces authority isolation for untrusted guest source inside one
VM. A guest cannot reach any function, process, port, file, atom or code path
that its program and run do not grant. The compiler lowers and checks every
call before the module exists. Each run is metered for reductions, heap and
wall time. Every term that crosses the door is sanitized.

`Hyperlang.Scope` adds resource isolation between tenants. Each scope has its
own admission limits, quotas and priority class. Node-wide admission counts
only runnable guest work, so blocked guests hold no capacity. Latency scopes
keep a reserved slot and wake first. An isolation verification of this
release measured the effect on a victim tenant:

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/isolation_noisy_neighbours_dark.svg">
  <img alt="Victim p99 latency next to 0, 1, 4 and 16 noisy tenants. With neighbours that have no scope policy it rises to 2.4x under CPU load, 13.6x under heap pressure and 2.4x under compile load. With the neighbours in background scopes with quotas it rises to 1.7x, 2.1x and 1.9x." src="assets/isolation_noisy_neighbours_light.svg" width="960">
</picture>

Each point is the p99 of 1,000 requests from one latency-class tenant on a
node with 4 schedulers, divided by that tenant's p99 with no neighbours, and
is the median of three runs. Each noisy tenant repeatedly spins a CPU-bound
loop, grows its heap until its heap limit kills the run, or compiles a new
guest module. The victim keeps its reserved latency slot in both series. The
neighbours either have no scope policy or each run in their own
`:background` scope with a CPU, heap-churn or compile quota.

The quotas refill every 100 ms. A tenant spends each period's budget in a
burst of a few milliseconds after the refill and is suspended for the rest,
and the victim's p99 rises inside the burst. The 1,000 requests start at
even intervals over 400 ms, so they cover four whole periods and every
phase of a period equally.

| Noisy tenants | 0 | 1 | 4 | 16 |
|---|---:|---:|---:|---:|
| CPU, no neighbour policy | 1.0x | 1.4x | 2.4x | 2.4x |
| CPU, background scopes | 1.0x | 1.4x | 1.7x | 1.7x |
| Heap, no neighbour policy | 1.0x | 1.1x | 6.5x | 13.6x |
| Heap, background scopes | 1.0x | 1.2x | 1.4x | 2.1x |
| Compile, no neighbour policy | 1.0x | 1.5x | 2.4x | 2.4x |
| Compile, background scopes | 1.0x | 1.5x | 1.7x | 1.9x |

Resource control guarantees:

- Each run has fresh reduction accounting. A spawned run's limits group is
  destroyed when the run ends: 10,000 runs leave 0 groups, processes, ports,
  ETS tables or file descriptors behind. An actor's callbacks, and one host's
  in-caller runs, share one limits group per process. Its usage restarts with
  every run, and the process's exit destroys it.
- Guest children owned by a run are killed when the run ends.
- Timer quotas and handles belong to a host-selected scope. One scope cannot
  read or cancel another scope's timers.
- Channels, buffers and broker heaps count against scope quotas (1,024
  channels per scope by default).
- OTP actor status and crash reports never show binding state or policy
  secrets, whatever `format_status` the guest defines.
- Internal fun application rejects host funs.

Guests share the VM's schedulers, allocators, garbage collector and code
server, and a few native calls cannot be interrupted. Hosts that need hard
latency or memory bounds against hostile tenants add OS or node isolation.
The [security specification](doc/SECURITY_SPECIFICATION.md) lists the full
contract and its known limitations.

## Workers and Hyperlang at a glance

Left: Cloudflare Workers code. Right: the equivalent Hyperlang guest in plain
Erlang. Authority that Workers get through `env` arrives as static calls to
named bindings (`kv:get/1`, `storage:put/2`). The host declares the bindings
once and supplies them at run time. The sections below show and run the host
side of each pair. Each Erlang snippet is copied from one of those examples,
and the test suite checks that the copies match.

<table>
<tr><th>Cloudflare Workers (JavaScript)</th><th>Hyperlang guest (Erlang)</th></tr>
<tr><td colspan="2"><b>Entrypoint</b>: <code>fetch</code> becomes <code>result/1</code></td>
</tr>
<tr>
<td>

```js
export default {
  async fetch(request, env, ctx) {
    const { name } = await request.json();
    return Response.json({ greeting: `hello ${name}` });
  },
};
```

</td><td>

<!-- hyperlang:example mirror -->
```erlang
-module(hello).
-export([result/1]).

result(#{<<"name">> := Name}) ->
    #{<<"greeting">> => <<"hello ", Name/binary>>}.
```

</td>
</tr>
<tr><td colspan="2"><b>RPC method</b>: a <code>WorkerEntrypoint</code> method becomes a manifest-declared export</td>
</tr>
<tr>
<td>

```js
export class Calc extends WorkerEntrypoint {
  add(a, b) {
    return a + b;
  }
}
```

</td><td>

<!-- hyperlang:example mirror -->
```erlang
-module(calc).
-export([add/2]).
add(A, B) -> A + B.
```

</td>
</tr>
<tr><td colspan="2"><b>KV binding</b>: <code>env.KV</code> becomes the <code>kv</code> binding</td>
</tr>
<tr>
<td>

```js
export default {
  async fetch(request, env) {
    await env.KV.put("greeting", "hi");
    return new Response(await env.KV.get("greeting"));
  },
};
```

</td><td>

<!-- hyperlang:example mirror -->
```erlang
-module(greet).
-export([result/1]).
result(Key) -> ok = kv:put(Key, <<"hi">>), kv:get(Key).
```

</td>
</tr>
<tr><td colspan="2"><b>Secret</b>: <code>env.API_TOKEN</code> stays inside the binding's host state, and the guest never sees it</td>
</tr>
<tr>
<td>

```js
export default {
  async fetch(request, env) {
    return new Response(await sign(env.API_TOKEN, "payload"));
  },
};
```

</td><td>

<!-- hyperlang:example mirror -->
```erlang
-module(signed).
-export([result/1]).
result(P) -> signer:sign(P).
```

</td>
</tr>
<tr><td colspan="2"><b>Logging</b>: <code>console.log</code> becomes <code>io:format</code>, returned to the host in <code>meta.stdout</code></td>
</tr>
<tr>
<td>

```js
export default {
  async fetch(request) {
    console.log("pricing", "A1");
    return new Response("42");
  },
};
```

</td><td>

<!-- hyperlang:example mirror -->
```erlang
-module(price).
-export([result/1]).
result(Sku) -> io:format("pricing ~s~n", [Sku]), 42.
```

</td>
</tr>
<tr><td colspan="2"><b>Durable Object</b>: a class with <code>ctx.storage</code> becomes a gen_server callback module with a <code>storage</code> binding</td>
</tr>
<tr>
<td>

```js
export class Counter extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      this.n = (await ctx.storage.get("n")) ?? 0;
    });
  }
  async inc() {
    this.n += 1;
    await this.ctx.storage.put("n", this.n);
    return this.n;
  }
}
```

</td><td>

<!-- hyperlang:example mirror -->
```erlang
-module(counter).
-behaviour(gen_server).
-export([init/1, handle_call/3]).

init(_Id) -> {ok, storage:get(<<"n">>, 0)}.

handle_call(<<"inc">>, _From, N) ->
    ok = storage:put(<<"n">>, N + 1),
    {reply, N + 1, N + 1}.
```

</td>
</tr>
</table>

## The door

The public API is four functions and one callback module:

| Function or module | Role |
| --- | --- |
| `Hyperlang.program/1` | Compile a source value into an immutable `%Hyperlang.Program{}`. |
| `Hyperlang.program/2` | Return a program cached under your key; compile on a miss. |
| `Hyperlang.run/4` | Run one export of a program with the authority in a spec. |
| `Hyperlang.load/1` | Load a program into the code pool ahead of its first use. |
| `Hyperlang.Actor` | The `GenServer` callback module that runs a program's OTP callbacks: `GenServer.start(Hyperlang.Actor, {spec, program, arg})`, or `{Hyperlang.Actor, {spec, program, arg}}` as a supervisor child. |

`Hyperlang.Binding` is the behaviour for host capabilities, and
`Hyperlang.Test` is the test kit.

## A Worker entrypoint is `result/1` plus `run/4`

A Worker exports `fetch`. A Hyperlang program exports `result/1`. The host
calls it with `Hyperlang.run(spec, program, :entry, [input])`.

<!-- hyperlang:example run -->
```elixir
# Hyperlang: guest Erlang + host Elixir
{:ok, program} =
  Hyperlang.program(%{
    entry: "hello.erl",
    files: %{
      "hello.erl" => ~S"""
      -module(hello).
      -export([result/1]).

      result(#{<<"name">> := Name}) ->
          #{<<"greeting">> => <<"hello ", Name/binary>>}.
      """
    },
    manifest: %{terms: %{public: :erlang}}
  })

{:ok, %{<<"greeting">> => "hello Ada"}, meta} =
  Hyperlang.run(%{}, program, :entry, [%{<<"name">> => "Ada"}])

%{stdout: [], reductions: _, wall_us: _} = meta
```

The value comes back as a plain term. Inputs and outputs cross a sanitizer.
Binaries, numbers, lists, tuples, maps and allowlisted atoms pass. Pids,
ports, references and funs are rejected. `terms: %{public: :erlang}` selects
the Erlang term profile used in this guide. The default profile projects
terms to a JSON-safe shape (binaries become `%{"$binary" => base64}`) for
hosts that serialize results.

Named exports correspond to RPC methods on a `WorkerEntrypoint`. Only exports
the manifest declares are callable. A source `-export` attribute alone grants
nothing.

<!-- hyperlang:example run -->
```elixir
{:ok, program} =
  Hyperlang.program(%{
    entry: "calc.erl",
    files: %{"calc.erl" => "-module(calc).\n-export([add/2]).\nadd(A, B) -> A + B.\n"},
    manifest: %{
      terms: %{public: :erlang},
      exports: %{functions: %{"add" => %{function: "add", arity: 2}}}
    }
  })

{:ok, 3, _meta} = Hyperlang.run(%{}, program, "add", [1, 2])
```

## `env` bindings and wrangler config are `Hyperlang.Binding` and manifest `bindings`

In Workers, `wrangler.jsonc` declares a binding by name and the code calls
`env.KV.get(key)`. In Hyperlang, a binding is a trusted host module. The
manifest names it once. Guest code calls it as a static module call,
`kv:get(Key)`.

```js
// wrangler.jsonc: { "kv_namespaces": [{ "binding": "KV", "id": "..." }] }
export default {
  async fetch(request, env) {
    return new Response(await env.KV.get("greeting"));
  },
};
```

<!-- hyperlang:example run -->
```elixir
defmodule Readme.KV do
  @behaviour Hyperlang.Binding

  @impl true
  def exports, do: [get: 1, put: 2]

  @impl true
  def call(%{table: table}, :get, [key]) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> value
      [] -> :undefined
    end
  end

  def call(%{table: table}, :put, [key, value]) do
    true = :ets.insert(table, {key, value})
    :ok
  end
end

{:ok, program} =
  Hyperlang.program(%{
    entry: "greet.erl",
    files: %{
      "greet.erl" => """
      -module(greet).
      -export([result/1]).
      result(Key) -> ok = kv:put(Key, <<"hi">>), kv:get(Key).
      """
    },
    manifest: %{
      bindings: %{"kv" => Readme.KV},
      terms: %{public: :erlang, allowed_atoms: [:ok, :undefined]}
    }
  })

table = :ets.new(:readme_kv, [:public])
spec = %{bindings: %{"kv" => {Readme.KV, %{table: table}}}}

{:ok, "hi", _meta} = Hyperlang.run(spec, program, :entry, ["greeting"])
```

`Hyperlang.program/1` reads `exports/0` once and pins the MFA set
(`kv:get/1`, `kv:put/2`) into the program and its hash. A call to any other
`kv:` function is a compile error. At run time, `spec.bindings` must name
exactly the declared bindings with the same modules, or the run fails before
the guest starts.

Export options:

- `{:get, 1, limits: %{max_binary_bytes: 4096}}` caps argument and return
  sizes.
- `{:now_ms, 0, nondeterministic: true}` marks a call that the manifest must
  allow with `capabilities: %{nondeterminism: true}`.

## Secrets and vars live in binding state

A Worker reads secrets from `env.API_TOKEN`. In Hyperlang, secrets go in the
binding's `state`. State goes to `call/3` and never reaches the guest.

<!-- hyperlang:example run -->
```elixir
defmodule Readme.Signer do
  @behaviour Hyperlang.Binding

  @impl true
  def exports, do: [sign: 1]

  @impl true
  def call(%{token: token}, :sign, [payload]),
    do: :crypto.mac(:hmac, :sha256, token, payload) |> Base.encode16(case: :lower)
end

{:ok, program} =
  Hyperlang.program(%{
    entry: "signed.erl",
    files: %{"signed.erl" => "-module(signed).\n-export([result/1]).\nresult(P) -> signer:sign(P).\n"},
    manifest: %{bindings: %{"signer" => Readme.Signer}, terms: %{public: :erlang}}
  })

spec = %{bindings: %{"signer" => {Readme.Signer, %{token: "s3cret"}}}}
{:ok, signature, _meta} = Hyperlang.run(spec, program, :entry, ["payload"])
64 = byte_size(signature)
```

## `console.log` and Tail Workers are `io:format` and `meta.stdout`

Guest `io:format` output is captured, sanitized, bounded and returned with
the result. A host can forward it to its own logger, as a Tail Worker does.

<!-- hyperlang:example run -->
```elixir
{:ok, program} =
  Hyperlang.program(%{
    entry: "price.erl",
    files: %{
      "price.erl" => ~S"""
      -module(price).
      -export([result/1]).
      result(Sku) -> io:format("pricing ~s~n", [Sku]), 42.
      """
    },
    manifest: %{terms: %{public: :erlang}}
  })

{:ok, 42, %{stdout: ["pricing A1\n"], reductions: reductions}} =
  Hyperlang.run(%{}, program, :entry, ["A1"])

true = reductions > 0
```

## CPU and memory limits are reductions, heap, and wall time

Workers cap CPU time and memory per request. Hyperlang caps reductions
(`max_reductions`), heap words (`heap_words`) and wall time (`wall_ms`) per
run, set in `spec.policy`. A run that crosses a limit returns a sanitized
error with a fixed category.

<!-- hyperlang:example run -->
```elixir
{:ok, program} =
  Hyperlang.program(%{
    entry: "work.erl",
    files: %{
      "work.erl" => """
      -module(work).
      -export([result/1]).
      result(<<"spin">>) -> spin();
      result(N) -> N.
      spin() -> spin().
      """
    }
  })

{:error, %{category: :reduction_watchdog}} =
  Hyperlang.run(%{policy: %{max_reductions: 100_000}}, program, :entry, ["spin"])

{:error, %{category: :timeout}} =
  Hyperlang.run(%{policy: %{max_reductions: nil, wall_ms: 50}}, program, :entry, ["spin"])

{:ok, 7, _meta} = Hyperlang.run(%{policy: %{heap_words: 200_000}}, program, :entry, [7])
```

Limits count reductions, so the same program and input hit the same limit on
every run.

Compilation is metered the same way. The manifest limit
`max_compile_reductions` caps the reductions of the compile worker (parse,
verification, code generation and the OTP compiler). `max_compile_ms` is a
wall-clock backstop for work that does not execute reductions. A source is
admitted or rejected the same way on an idle host and on a loaded host.

## Worker Loader `LOADER.get` is `Hyperlang.program(key, loader)`

The Worker Loader API fetches a dynamic Worker by id and calls a factory only
on a miss. `Hyperlang.program/2` does the same with a caller-owned key.

```js
const worker = env.LOADER.get("tenant-acme-v3", async () => ({
  mainModule: "main.js",
  modules: { "main.js": await fetchSource("acme") },
}));
```

<!-- hyperlang:example run -->
```elixir
loader = fn ->
  %{entry: "acme.erl", files: %{"acme.erl" => "-module(acme).\n-export([result/1]).\nresult(N) -> N * 2.\n"}}
end

{:ok, program} = Hyperlang.program({:tenant, "acme", 3}, loader)
{:ok, ^program} = Hyperlang.program({:tenant, "acme", 3}, fn -> raise "not called on a hit" end)
{:ok, 10, _meta} = Hyperlang.run(%{}, program, :entry, [5])
```

Programs are content-addressed. The same source and manifest always produce
an equal program value.

## A Durable Object is a callback actor plus a storage binding

A Durable Object is a single-threaded object with durable storage. Hyperlang
builds the same shape from existing parts:

- **Input gate:** `GenServer.start(Hyperlang.Actor, {spec, program, arg})`
  starts a confined actor. The actor runs one callback at a time.
- **Output gate:** storage is an ordinary binding passed in the spec, for
  example `{MyHost.Storage, %{ns: actor_id}}`. Binding calls are synchronous
  inside the callback, so a write-through storage binding returns only after
  the write is durable.
- **`blockConcurrencyWhile`:** in-memory state is a cache that `init/1`
  reloads from storage. An actor that stops or crashes restarts with the
  state its storage holds.
- **Limits:** `spec.policy` applies to every callback with no host wiring:
  `wall_ms` and `max_reductions` per callback, `rate` and `ceiling` for the
  actor's lifetime.

<!-- hyperlang:example run -->
```elixir
defmodule Readme.Storage do
  @behaviour Hyperlang.Binding

  @impl true
  def exports, do: [get: 2, put: 2]

  @impl true
  def call(%{table: table, ns: ns}, :get, [key, default]) do
    case :ets.lookup(table, {ns, key}) do
      [{_key, value}] -> value
      [] -> default
    end
  end

  def call(%{table: table, ns: ns}, :put, [key, value]) do
    true = :ets.insert(table, {{ns, key}, value})
    :ok
  end
end

{:ok, program} =
  Hyperlang.program(%{
    entry: "counter.erl",
    files: %{
      "counter.erl" => ~S"""
      -module(counter).
      -behaviour(gen_server).
      -export([init/1, handle_call/3]).

      init(_Id) -> {ok, storage:get(<<"n">>, 0)}.

      handle_call(<<"inc">>, _From, N) ->
          ok = storage:put(<<"n">>, N + 1),
          {reply, N + 1, N + 1}.
      """
    },
    manifest: %{
      result: %{name: "init", arity: 1},
      terms: %{public: :erlang, allowed_atoms: [:ok]},
      bindings: %{"storage" => Readme.Storage}
    }
  })

table = :ets.new(:readme_storage, [:public])
spec = %{bindings: %{"storage" => {Readme.Storage, %{table: table, ns: "counter-1"}}}}

{:ok, pid} = GenServer.start(Hyperlang.Actor, {spec, program, "counter-1"})
1 = GenServer.call(pid, "inc")
2 = GenServer.call(pid, "inc")
:ok = GenServer.stop(pid)

# A new actor for the same id reloads from storage in init/1.
{:ok, pid} = GenServer.start(Hyperlang.Actor, {spec, program, "counter-1"})
3 = GenServer.call(pid, "inc")
:ok = GenServer.stop(pid)
```

The host owns the id-to-process registry (`idFromName`), when actors start
and stop, and where storage lives. An alarm is another binding. The guest
asks the host to record one, and the host delivers it later as a message. The
default guest profile has no timers.

## `vitest-pool-workers` is `Hyperlang.Test`

`Hyperlang.Test` compiles guests, fakes bindings, runs exports and starts
actors through the public door only. A fake binding is a map of functions,
which the kit backs with a generated `Hyperlang.Binding` module.

```js
// vitest.config.ts declares bindings; tests import from "cloudflare:test"
import { env, SELF } from "cloudflare:test";
it("prices an item", async () => {
  const res = await SELF.fetch("https://example.com/?sku=A1");
  expect(await res.text()).toBe("42");
});
```

<!-- hyperlang:example run -->
```elixir
import Hyperlang.Test

source = "-module(shop).\n-export([result/1]).\nresult(Sku) -> io:format(\"sku~n\"), catalog:price(Sku).\n"
catalog = %{"catalog" => %{price: fn "A1" -> 42 end}}
manifest = %{terms: %{public: :erlang}}

42 = run!(source, :entry, ["A1"], bindings: catalog, manifest: manifest)

{:ok, 42, meta} = run(source, :entry, ["A1"], bindings: catalog, manifest: manifest)
assert_stdout(meta, "sku\n")

program = program!(source, Map.put(manifest, :bindings, catalog))
{:ok, 42, _meta} = run(program, :entry, ["A1"], bindings: catalog)
```

`start_actor!/3` starts a callback actor with `bindings:` and `policy:`.

## Where Hyperlang deliberately differs

- **No async/await, no `ctx.waitUntil`.** Binding calls block inside the
  metered call, so nothing interleaves and no input-gate machinery is needed.
  Background work belongs to the host: record a durable intent, or have the
  actor cast to itself.
- **No ambient `fetch` or outbound network.** A guest has network access only
  through a binding, which does its own checks host-side.
- **No `env` value in the guest.** Bindings are static calls such as
  `kv:get(K)`. The guest cannot store, pass or dynamically call them. The
  verifier rejects dynamic `M:F(...)` calls.
- **No persisted live capability stubs.** A guest cannot save a binding and
  redeem it later. The host re-supplies authority on every run.
- **Reductions instead of CPU milliseconds.** Reduction limits are
  deterministic enough to test exactly.
- **Allowlisted atoms.** The program declares a bounded atom set
  (`terms.allowed_atoms`). A run's `policy.atoms` may narrow it and never
  widen it. Workers have no atom table to protect; the BEAM does.
- **No WebSocket hibernation.** BEAM processes are cheap. An idle actor can
  be stopped and restarted from storage.
- **Child processes and programs go through host hooks.** A guest's `spawn`,
  `spawn_link` and `spawn_monitor` work only when the host installs a spawn
  hook. The child runs the same program's code, is metered as part of the
  run, and dies with it unless the hook takes over metering. A guest starts
  another program only through an exec hook or binding the host grants, as
  hyperbob_os does for `exec`. The host chooses the program and its
  authority. Only host code loads programs.

## Standard library calls

Hyperlang admits a frozen allowlist of Erlang/OTP stdlib functions. Allowed
calls run the real OTP functions behind argument and result sanitization.

<!-- hyperlang:example run -->
```elixir
{:ok, program} =
  Hyperlang.program(%{
    entry: "std.erl",
    files: %{
      "std.erl" => ~S"""
      -module(std).
      -export([result/1]).
      result(_) ->
          {lists:sum([1, 2, 3]),
           maps:get(<<"x">>, #{<<"x">> => 7}),
           re:replace(<<"banana">>, <<"a">>, <<"x">>, [global, {return, binary}])}.
      """
    },
    manifest: %{terms: %{public: :erlang}}
  })

{:ok, {6, 7, "bxnxnx"}, _meta} = Hyperlang.run(%{}, program, :entry, [nil])
```

Live clocks and entropy require `capabilities: %{nondeterminism: true}`:
`erlang:system_time/0,1`, `erlang:monotonic_time/0,1`,
`calendar:universal_time/0`, `rand:mwc59_seed/0`, `sys:millisec/0` and
local-time-zone conversions. The compiler rejects ambient authority: `os:*`,
raw `file:*`, ports, ETS, code loading, dynamic `apply` and NIF loading.

`io:format/*`, `io_lib:format/*` and float formatting run vendored, pinned
OTP formatting code behind Hyperlang wrappers. Output stays bounded, cannot
mint atoms and never renders a fun. Raw OTP JSON encoders are rejected. A
host that needs JSON provides it as a binding.

## Filesystem capability

A manifest can enable a mediated virtual filesystem. Guest code uses standard
`file:*` and `filelib:*` calls on virtual paths. No filesystem module is
visible to the guest. The test suite runs these examples against a manifest
with a readable `/data` mount and a writable `/work` mount:

<!-- hyperlang:example compile -->
```erlang
result(_) ->
    {ok, Bin} = file:read_file("/data/input.txt"),
    ok = file:write_file("/work/output.txt", Bin),
    #{<<"copied">> => Bin}.
```

<!-- hyperlang:example compile -->
```erlang
result(_) ->
    {ok, Names} = file:list_dir("/data"),
    lists:sort(Names).
```

The supported `file:*` subset is sequential and uses virtual paths:

- `read_file/1`, `write_file/2,3`, `list_dir/1`, `make_dir/1`, `del_dir/1`,
  `delete/1`, `rename/2`, `read_file_info/1`, `read_link_info/1`.
- With handle compatibility enabled: `open/2`, `read/2`, `write/2`,
  `close/1`. Handles are opaque guest terms.

Every call enforces mount permissions, byte limits and entry limits. A host
can instead supply a Plan 9 style syscall facade through `sys:*` with
`spec.syscall`.

Existing symlinks in host-backed mounts follow host semantics. Guests cannot
create links. Do not mount a host directory whose symlinks point to paths the
guest must not read. Use memory or snapshot mounts for strict fixtures.

## Run the tests

```bash
mix test
```

[`CONTRIBUTING.md`](CONTRIBUTING.md) describes the opt-in isolation stress
probes.

## License

Apache License, Version 2.0. See [`LICENSE`](LICENSE) and
[`NOTICE`](NOTICE), which credits the vendored Erlang/OTP sources.
