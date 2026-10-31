defmodule Hyperlang.Test do
  @moduledoc """
  Helpers for testing Hyperlang guests and the hosts that run them.

  The kit plays the role `vitest-pool-workers` plays for Cloudflare Workers:
  it compiles a guest, supplies fake bindings, runs exports, and starts
  callback actors. It uses only the public door (`Hyperlang.program/1`,
  `Hyperlang.run/4`, `Hyperlang.Actor`), so a test exercises exactly the
  path production code takes.

      import Hyperlang.Test

      test "prices an item" do
        prog =
          program!("-module(shop).\\n-export([result/1]).\\nresult(Sku) -> catalog:price(Sku).\\n",
            bindings: %{"catalog" => %{price: fn _sku -> 42 end}})

        assert {:ok, 42, meta} =
                 run(prog, :entry, ["A1"], bindings: %{"catalog" => %{price: fn _ -> 42 end}})

        assert_stdout meta, []
      end

  ## Fake bindings

  Wherever a binding is expected, the kit accepts a plain map of functions,
  `%{get: fn key -> ... end}`. The function arity is the export arity. A
  value may also be `{fun, opts}` to pass `Hyperlang.Binding` export options
  such as `nondeterministic: true`. The kit backs each distinct export shape
  with a generated `Hyperlang.Binding` module, so the same fake map at
  compile time and at run time names the same module. Real bindings are
  passed as a module (compile time) or `{module, state}` (run time).
  """

  @doc """
  Build a program. `code` is a source binary, or a source map
  `%{entry:, files:, manifest:}` passed to `Hyperlang.program/1` unchanged
  except for fake bindings.

  A binary with a `-module(name)` attribute becomes `name.erl`; any other
  binary (a `result/1` form list or an expression) becomes `main.erl`.
  `manifest` is a manifest map or a keyword list; its `bindings` may hold
  fake binding maps.
  """
  @spec program(binary() | map(), map() | keyword()) ::
          {:ok, Hyperlang.Program.t()} | {:error, [map()]}
  def program(code, manifest \\ %{})

  def program(code, manifest) when is_binary(code) do
    manifest = manifest_bindings(Map.new(manifest))
    entry = entry_file(code)
    Hyperlang.program(%{entry: entry, files: %{entry => code}, manifest: manifest})
  end

  def program(%{} = source, extra) do
    manifest =
      source
      |> Map.get(:manifest, %{})
      |> Map.merge(Map.new(extra))
      |> manifest_bindings()

    Hyperlang.program(Map.put(source, :manifest, manifest))
  end

  @doc "Like `program/2`, but returns the program or raises with the diagnostics."
  @spec program!(binary() | map(), map() | keyword()) :: Hyperlang.Program.t()
  def program!(code, manifest \\ %{}) do
    case program(code, manifest) do
      {:ok, program} -> program
      {:error, errors} -> raise ArgumentError, "Hyperlang program failed: #{inspect(errors)}"
    end
  end

  @doc """
  Run `export` through `Hyperlang.run/4` and return the door result.

  `target` is a program or source code; code is compiled with `program/2`
  using `opts[:manifest]` plus the binding modules named by
  `opts[:bindings]`. Options:

    * `:bindings` — `%{name => fake_map | {module, state}}`
    * `:policy` — the run policy (map or keyword list)
    * `:syscall` — the host syscall door
    * `:manifest` — manifest for code targets
  """
  @spec run(Hyperlang.Program.t() | binary() | map(), atom() | binary(), list(), keyword()) ::
          {:ok, term(), map()} | {:error, term()}
  def run(target, export, args, opts \\ []) do
    bindings = Map.new(Keyword.get(opts, :bindings, %{}), &run_binding/1)

    with {:ok, program} <- target_program(target, bindings, opts) do
      spec =
        %{bindings: bindings, policy: Map.new(Keyword.get(opts, :policy, %{}))}
        |> maybe_put(:syscall, Keyword.get(opts, :syscall))

      Hyperlang.run(spec, program, export, args)
    end
  end

  @doc "Like `run/4`, but returns the value or raises with the error."
  @spec run!(Hyperlang.Program.t() | binary() | map(), atom() | binary(), list(), keyword()) ::
          term()
  def run!(target, export, args, opts \\ []) do
    case run(target, export, args, opts) do
      {:ok, value, _meta} -> value
      {:error, error} -> raise ArgumentError, "Hyperlang run failed: #{inspect(error)}"
    end
  end

  @doc """
  Start the program as an unlinked `Hyperlang.Actor` and return
  its pid. `arg` is the guest `init/1` argument. Options are `:bindings`,
  `:policy`, and `:syscall`, as for `run/4`; they become the actor's spec.
  """
  @spec start_actor!(Hyperlang.Program.t(), term(), keyword()) :: pid()
  def start_actor!(%Hyperlang.Program{} = program, arg, opts \\ []) do
    spec =
      %{
        bindings: Map.new(Keyword.get(opts, :bindings, %{}), &run_binding/1),
        policy: Map.new(Keyword.get(opts, :policy, %{}))
      }
      |> maybe_put(:syscall, Keyword.get(opts, :syscall))

    case GenServer.start(Hyperlang.Actor, {spec, program, arg}) do
      {:ok, pid} -> pid
      other -> raise ArgumentError, "Hyperlang actor failed to start: #{inspect(other)}"
    end
  end

  @doc """
  Assert on guest stdout. `subject` is a `run/4` result or its `meta` map.
  `expected` is the list of chunks, a binary compared against the joined
  chunks, or a regex matched against them.
  """
  defmacro assert_stdout(subject, expected) do
    quote do
      stdout = Hyperlang.Test.stdout(unquote(subject))
      expected = unquote(expected)

      unless Hyperlang.Test.stdout_matches?(stdout, expected) do
        raise ExUnit.AssertionError,
          message: "guest stdout did not match",
          left: stdout,
          right: expected
      end

      stdout
    end
  end

  @doc false
  def stdout_matches?(stdout, %Regex{} = regex), do: Regex.match?(regex, Enum.join(stdout))
  def stdout_matches?(stdout, chunks) when is_list(chunks), do: stdout == chunks
  def stdout_matches?(stdout, text) when is_binary(text), do: Enum.join(stdout) == text

  @doc false
  def stdout({:ok, _value, %{stdout: stdout}}), do: stdout
  def stdout(%{stdout: stdout}), do: stdout

  def stdout(other),
    do: raise(ArgumentError, "expected a Hyperlang.run/4 success, got: #{inspect(other)}")

  defp target_program(%Hyperlang.Program{} = program, _bindings, _opts), do: {:ok, program}

  defp target_program(code, bindings, opts) do
    manifest =
      opts
      |> Keyword.get(:manifest, %{})
      |> Map.new()
      |> Map.put(:bindings, Map.new(bindings, fn {name, {module, _state}} -> {name, module} end))

    program(code, manifest)
  end

  defp manifest_bindings(%{bindings: bindings} = manifest) do
    %{
      manifest
      | bindings: Map.new(bindings, fn {name, value} -> {name, binding_module(value)} end)
    }
  end

  defp manifest_bindings(manifest), do: manifest

  defp binding_module(module) when is_atom(module), do: module
  defp binding_module(%{} = fake), do: fake |> fake_exports() |> fake_module()

  defp run_binding({name, {module, _state} = binding}) when is_atom(module), do: {name, binding}

  defp run_binding({name, %{} = fake}) do
    funs = Map.new(fake, fn {function, value} -> {function, fake_fun(value)} end)
    {name, {fake |> fake_exports() |> fake_module(), funs}}
  end

  defp fake_fun({fun, _opts}) when is_function(fun), do: fun
  defp fake_fun(fun) when is_function(fun), do: fun

  defp fake_exports(fake) do
    fake
    |> Enum.map(fn
      {function, {fun, opts}} when is_atom(function) and is_function(fun) ->
        {function, arity(fun), Map.new(opts)}

      {function, fun} when is_atom(function) and is_function(fun) ->
        {function, arity(fun)}
    end)
    |> Enum.sort()
  end

  defp arity(fun), do: fun |> Function.info(:arity) |> elem(1)

  # One generated module per distinct export list. The module is a real
  # `Hyperlang.Binding`; its state is the fake's function map.
  defp fake_module(exports) do
    hash =
      :crypto.hash(:sha256, :erlang.term_to_binary(exports, [:deterministic]))
      |> Base.encode16()
      |> binary_part(0, 16)

    module = Module.concat(Hyperlang.Test.FakeBinding, "B" <> hash)

    :global.trans({{__MODULE__, module}, self()}, fn ->
      unless Code.ensure_loaded?(module) do
        Module.create(
          module,
          quote do
            @behaviour Hyperlang.Binding
            @impl true
            def exports, do: unquote(Macro.escape(exports))
            @impl true
            def call(funs, function, args), do: apply(Map.fetch!(funs, function), args)
          end,
          Macro.Env.location(__ENV__)
        )
      end
    end)

    module
  end

  defp entry_file(code) do
    case Regex.run(~r/^\s*-module\s*\(\s*'?([a-z][A-Za-z0-9_]*)'?\s*\)/m, code) do
      [_, module] -> module <> ".erl"
      nil -> "main.erl"
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
