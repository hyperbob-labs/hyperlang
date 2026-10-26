defmodule RereviewAdversarialTest do
  use ExUnit.Case, async: false

  defp erlang_public(manifest \\ %{}) do
    Map.update(manifest, :terms, %{public: :erlang}, &Map.put(&1, :public, :erlang))
  end

  defp run(source, manifest) do
    with {:ok, program} <- Hyperlang.Test.program(source, manifest) do
      Hyperlang.Test.run(program, :entry, [nil])
    end
  end

  defp blocked?(source, manifest) do
    case Hyperlang.Test.program(source, manifest) do
      {:error, _} ->
        true

      {:ok, _program} ->
        false
    end
  end

  defp export_spec(function, arity) do
    %{
      function: function,
      arity: arity,
      input: %{profile: :safe_term},
      output: %{profile: :safe_term}
    }
  end

  defp export_manifest(functions, extra \\ %{}) do
    extra
    |> Map.put(:exports, %{functions: functions})
    |> erlang_public()
  end

  defp export_blocked?(body) do
    source = "public() -> #{body}."
    manifest = export_manifest(%{"public" => export_spec("public", 0)})
    blocked?(source, manifest)
  end

  defp error_reason(error), do: get_in(error, [:details, "reason"])

  describe "classic escape battery (must stay blocked)" do
    test "dynamic apply / computed M:F" do
      assert blocked?("apply(erlang, abs, [-1]).", erlang_public())
      assert blocked?("erlang:apply(erlang, abs, [-1]).", erlang_public())
      assert blocked?("M = erlang, M:abs(-1).", erlang_public())
      assert blocked?("F = abs, erlang:F(-1).", erlang_public())
    end

    test "process authority ops stay blocked while native spawn and receive are admitted" do
      refute blocked?("spawn(fun() -> ok end).", erlang_public())
      assert {:error, error} = run("spawn(fun() -> ok end).", erlang_public())
      assert inspect(error_reason(error)) =~ "no_spawn_policy"

      assert blocked?("self().", erlang_public())
      assert blocked?("self() ! hello.", erlang_public())
      assert blocked?("erlang:send(self(), x).", erlang_public())
      refute blocked?("receive after 0 -> ok end.", erlang_public())
    end

    test "term and atom smuggling" do
      assert blocked?("binary_to_term(<<131,100,0,3,102,111,111>>).", erlang_public())
      assert blocked?("erlang:binary_to_term(<<>>).", erlang_public())
      assert blocked?("list_to_atom(\"evil\").", erlang_public())
      assert blocked?("binary_to_atom(<<\"evil\">>).", erlang_public())
      assert blocked?("list_to_existing_atom(\"ok\").", erlang_public())
      assert blocked?("binary_to_existing_atom(<<\"ok\">>).", erlang_public())
    end

    test "authority modules" do
      assert blocked?("ets:new(t, []).", erlang_public())
      assert blocked?("persistent_term:get(k).", erlang_public())
      assert blocked?("code:load_file(m).", erlang_public())
      assert blocked?("os:getenv(\"PATH\").", erlang_public())
      assert blocked?("file:read_file(\"/etc/passwd\").", erlang_public())
      assert blocked?("erlang:halt(0).", erlang_public())
      assert blocked?("halt(0).", erlang_public())
    end

    test "build a fun and call it (allowed) but cannot escape" do
      # building+calling a local fun is fine and pure
      assert {:ok, 3, _} = run("F = fun(X) -> X + 1 end, F(2).", erlang_public())
      # external fun capture rejected
      assert blocked?("F = fun erlang:abs/1, F(-1).", erlang_public())
      assert blocked?("fun maps:get/2.", erlang_public())
    end

    test "module_info / external funs" do
      assert blocked?("module_info().", erlang_public())
      assert blocked?("erlang:make_fun(erlang, abs, 1).", erlang_public())
    end
  end

  describe "export entry adversarial battery" do
    test "classic blocked forms stay blocked when declared as manifest exports" do
      for body <- [
            "apply(erlang, abs, [-1])",
            "erlang:apply(erlang, abs, [-1])",
            "M = erlang, M:abs(-1)",
            "F = abs, erlang:F(-1)",
            "self()",
            "erlang:send(self(), x)",
            "binary_to_term(<<131,100,0,3,102,111,111>>)",
            "list_to_atom(\"evil\")",
            "binary_to_existing_atom(<<\"ok\">>)",
            "ets:new(t, [])",
            "persistent_term:get(k)",
            "code:load_file(m)",
            "os:getenv(\"PATH\")",
            "file:read_file(\"/etc/passwd\")",
            "module_info()",
            "erlang:make_fun(erlang, abs, 1)",
            "fun maps:get/2"
          ] do
        assert export_blocked?(body), body
      end

      refute export_blocked?("spawn(fun() -> ok end)")
    end
  end

  describe "NEW nondeterminism gate: fail-closed" do
    test "clock reads blocked without capability, allowed with" do
      assert blocked?("erlang:monotonic_time().", erlang_public())

      assert {:ok, true, _} =
               run(
                 "is_integer(erlang:monotonic_time()).",
                 erlang_public(%{capabilities: [:nondeterminism]})
               )
    end

    test "FINDING: capability enabled by non-boolean truthy values (string/int coercion)" do
      # These SHOULD remain blocked (only strict `true` should enable) but do NOT.
      # Demonstrates manifest truthy? coercion bypass.
      assert blocked?(
               "erlang:monotonic_time().",
               erlang_public(%{capabilities: %{"nondeterminism" => "yes"}})
             ),
             "non-recognized string correctly stays off"

      # The bypass: string "true" and integer 1 ENABLE nondeterminism.
      refute blocked?(
               "erlang:monotonic_time().",
               erlang_public(%{capabilities: %{nondeterminism: "true"}})
             ),
             "EXPECTED BLOCKED but string \"true\" enabled the capability"

      refute blocked?(
               "erlang:monotonic_time().",
               erlang_public(%{capabilities: %{nondeterminism: 1}})
             ),
             "EXPECTED BLOCKED but integer 1 enabled the capability"
    end

    test "rand:seed_s rejected even WITH capability (no safe PRNG wrapper)" do
      m = erlang_public(%{capabilities: [:nondeterminism], terms: %{allowed_atoms: [:exsss]}})
      assert blocked?("rand:seed_s(exsss).", m)
      assert blocked?("rand:seed_s(exsss, {1,2,3}).", m)
    end

    test "rand:uniform (live PRNG read) still blocked - not in any allowlist" do
      m = erlang_public(%{capabilities: [:nondeterminism]})
      assert blocked?("rand:uniform().", m)
      assert blocked?("rand:uniform(10).", m)
    end

    test "nondeterministic call via local-call form (erlang implicit) also gated" do
      # date/0 is an erlang BIF callable unqualified
      assert blocked?("date().", erlang_public())

      assert {:ok, true, _} =
               run(
                 "tuple_size(date()) == 3.",
                 erlang_public(%{capabilities: [:nondeterminism]})
               )
    end
  end

  describe "NEW atom_to_binary wrapper" do
    test "atom_to_binary of a pooled (guest) atom yields source name, not pool atom" do
      # 'foo' is a guest atom -> goes to pool; atom_to_binary must return <<\"foo\">>
      assert {:ok, "foo", _} = run("atom_to_binary(foo).", erlang_public())
      assert {:ok, "foo", _} = run("atom_to_binary(foo, utf8).", erlang_public())
      assert {:ok, "foo", _} = run("erlang:atom_to_binary(foo, latin1).", erlang_public())
    end

    test "atom_to_binary cannot be used to leak internal pool atom name" do
      {:ok, r, _} = run("atom_to_binary(some_guest_atom).", erlang_public())
      refute r =~ "hyperlang_atom"
      refute r =~ "hyperlang"
    end
  end

  describe "NEW try-of support (regression)" do
    test "try ... of ... catch evaluates of-branch" do
      src = "try 1 + 1 of X when X =:= 2 -> ok; _ -> other catch _:_ -> caught end."
      assert {:ok, :ok, _} = run(src, erlang_public())
    end

    test "try-of catch only protects pre-of body, of-clause body errors propagate" do
      # of-clause body raises (div by zero); catch must NOT catch it (Erlang semantics)
      src = "try 1 of 1 -> 1 div 0 catch _:_ -> caught end."

      assert match?({:error, _}, run(src, erlang_public())) or
               match?({:ok, r, _} when r != :caught, run(src, erlang_public()))
    end

    test "catch stack var sanitized to []" do
      src = "try 1 div 0 catch _:_:S -> S end."
      assert {:ok, [], _} = run(src, erlang_public())
    end

    test "try-after still unsupported" do
      assert blocked?("try 1 after ok end.", erlang_public())
    end

    test "alias pattern in match still safe / no atom leak" do
      assert {:ok, {1, 2}, _} =
               run("X = {A, B} = {1, 2}, {A, B} = X.", erlang_public())
    end
  end

  defmodule Clock do
    @behaviour Hyperlang.Binding
    @impl true
    def exports, do: [{:now, 0, nondeterministic: true}]
    @impl true
    def call(_state, :now, []), do: 1
  end

  describe "module shadowing / reserved binding" do
    test "cannot declare a binding shadowing a reserved stdlib module" do
      m = erlang_public(%{bindings: %{"erlang" => %{monotonic_time: fn -> 1 end}}})
      # binding a reserved module name must be rejected at manifest or verify
      assert blocked?("erlang:monotonic_time().", m)
    end

    test "nondeterministic binding export requires capability" do
      assert {:error, _} = Hyperlang.Manifest.normalize(%{bindings: %{"clock" => Clock}})

      assert {:ok, _} =
               Hyperlang.Manifest.normalize(%{
                 bindings: %{"clock" => Clock},
                 capabilities: %{nondeterminism: true}
               })
    end
  end
end
