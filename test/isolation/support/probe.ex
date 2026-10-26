Code.require_file("contention.ex", __DIR__)
Code.require_file("native.ex", __DIR__)

defmodule Hyperlang.Isolation.Peer do
  @moduledoc false
  @cap_kib 4 * 1024 * 1024

  # standard_io uses no distribution, epmd, or network listener. Each child has
  # four schedulers, one dirty CPU scheduler, and its own capped OS watchdog.
  # Elixir 1.20 starts ExUnit.async_run before compiling test files, so a
  # late ExUnit.configure/1 alone cannot protect default runs. Compile a skip
  # tag unless the caller explicitly opted in or selected this file by line.
  def stress_enabled?(file) do
    Enum.any?(ExUnit.configuration()[:include] || [], fn
      key when key in [:isolation_stress, :isolation_finding] -> true
      {key, _} when key in [:isolation_stress, :isolation_finding] -> true
      {:location, {path, _line}} -> Path.expand(path) == Path.expand(file)
      _ -> false
    end)
  end

  def start(opts \\ []) do
    schedulers = Keyword.get(opts, :schedulers, 4)
    args = String.to_charlist("+S #{schedulers}:#{schedulers}") |> :string.lexemes(~c" ")
    args = args ++ ~w( +SDcpu 1 +SDio 1 +A 1 +hmax 134217728 +hmaxel false +hmaxk true)c
    paths = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])

    {:ok, peer, _} =
      :peer.start_link(%{connection: :standard_io, args: args ++ paths, wait_boot: 30_000})

    os_pid = :peer.call(peer, :os, :getpid, [], 30_000) |> List.to_string()
    session = %{peer: peer, os_pid: os_pid}

    bootstrap(session, fn ->
      :peer.call(peer, :application, :ensure_all_started, [:elixir], 30_000)
      :peer.call(peer, :application, :ensure_all_started, [:hyperlang], 30_000)
      :peer.call(peer, Code, :require_file, [__ENV__.file], 30_000)
      :peer.call(peer, Logger, :configure, [[level: :emergency]], 30_000)
      :peer.call(peer, Hyperlang.Isolation.Probe, :warm, [], 30_000)
      :ok
    end)

    session
  end

  def bootstrap(session, fun) do
    owner = self()
    ref = make_ref()
    {runner, mon} = spawn_monitor(fn -> send(owner, {ref, fun.()}) end)

    case watch(session, ref, mon, runner, System.monotonic_time(:millisecond), 0) do
      %{result: _} ->
        :ok

      failure ->
        stop(session)
        raise "peer bootstrap failed: #{inspect(failure)}"
    end
  end

  def stop(%{peer: peer}) do
    try do
      :peer.stop(peer)
    catch
      :exit, _ -> :ok
    end
  end

  def run(name, args \\ []) do
    session = start()

    try do
      call(session, name, args)
    after
      stop(session)
    end
  end

  def call(session, name, args \\ []) do
    owner = self()
    ref = make_ref()

    {runner, mon} =
      spawn_monitor(fn ->
        result = :peer.call(session.peer, Hyperlang.Isolation.Probe, name, args, 29_000)
        send(owner, {ref, result})
      end)

    started = System.monotonic_time(:millisecond)
    result = watch(session, ref, mon, runner, started, 0)
    record(name, result)
    result
  end

  defp watch(session, ref, mon, runner, started, peak) do
    rss =
      case System.cmd("ps", ["-o", "rss=", "-p", session.os_pid]) do
        {out, 0} ->
          case Integer.parse(String.trim(out)) do
            {n, _} -> n
            _ -> 0
          end

        _ ->
          0
      end

    peak = max(peak, rss)
    elapsed = System.monotonic_time(:millisecond) - started

    cond do
      rss > @cap_kib or elapsed >= 30_000 ->
        System.cmd("kill", ["-KILL", session.os_pid])
        Process.exit(runner, :kill)
        Process.demonitor(mon, [:flush])

        %{
          watchdog:
            if(rss > @cap_kib, do: :rss_limit_not_enforced, else: :wall_limit_not_enforced),
          elapsed_ms: elapsed,
          peak_rss_kib: peak
        }

      true ->
        receive do
          {^ref, result} ->
            Process.demonitor(mon, [:flush])

            %{
              result: result,
              elapsed_ms: System.monotonic_time(:millisecond) - started,
              peak_rss_kib: peak
            }

          {:DOWN, ^mon, :process, ^runner, reason} ->
            %{peer_failure: inspect(reason), elapsed_ms: elapsed, peak_rss_kib: peak}
        after
          40 -> watch(session, ref, mon, runner, started, peak)
        end
    end
  end

  defp record(name, data) do
    if dir = System.get_env("ISOLATION_EVIDENCE_DIR") do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "#{name}.etf"), :erlang.term_to_binary(data))

      File.write!(
        Path.join(dir, "evidence.log"),
        inspect({name, data}, limit: :infinity, printable_limit: 8_000, width: 140) <> "\n",
        [:append]
      )
    end
  end
end

defmodule Hyperlang.Isolation.Probe do
  @moduledoc false
  alias Hyperlang.Test, as: Kit

  def manifest(extra \\ %{}), do: Map.merge(%{terms: %{public: :erlang}}, extra)
  def program(body, extra \\ %{}), do: Kit.program!(body, manifest(extra))

  def run(body, extra \\ %{}, policy \\ %{}),
    do: Kit.run(program(body, extra), :entry, [nil], policy: policy)

  def warm do
    p = program("result(X) -> X.")
    Kit.run(p, :entry, [1])
    snapshot()
    :ok
  end

  def snapshot do
    # lsof -Ff returns one f record per descriptor (including cwd/txt/mem).
    # We count numeric descriptors only, so this is open FDs, not mappings.
    pid = :os.getpid() |> List.to_string()

    {fds, status} =
      System.cmd("/usr/sbin/lsof", ["-nP", "-a", "-p", pid, "-Ff"], stderr_to_stdout: true)

    fd_count =
      if status == 0, do: length(Regex.scan(~r/^f\d+/m, fds)), else: {:unavailable, status}

    %{
      atoms: :erlang.system_info(:atom_count),
      processes: :erlang.system_info(:process_count),
      ets: length(:ets.all()),
      ports: :erlang.system_info(:port_count),
      memory: Map.new(:erlang.memory()),
      fds: fd_count,
      groups: map_size(:sys.get_state(Hyperlang.Limits).groups)
    }
  end

  def measured(label, fun) do
    before = snapshot()

    {us, observed} =
      :timer.tc(fn ->
        try do
          fun.()
        rescue
          e -> %{raised: Exception.message(e)}
        catch
          k, v -> %{caught: {k, inspect(v)}}
        end
      end)

    Process.sleep(35)
    :erlang.garbage_collect()
    after_ = snapshot()

    %{
      attack: label,
      before: before,
      after: after_,
      time_us: us,
      observed: observed,
      delta:
        Map.new([:atoms, :processes, :ets, :ports, :fds, :groups], fn k ->
          {k,
           if(is_integer(before[k]) and is_integer(after_[k]),
             do: after_[k] - before[k],
             else: :unavailable
           )}
        end),
      memory_delta: Map.new(before.memory, fn {k, v} -> {k, after_.memory[k] - v} end)
    }
  end

  def native_interruptions, do: Hyperlang.Isolation.Native.interruptions()
  def wall_precision, do: Hyperlang.Isolation.Contention.wall()

  def contention(mode, n, enabled, single_scope \\ false),
    do: Hyperlang.Isolation.Contention.noisy(mode, n, enabled, single_scope)

  def category({:ok, _, _}), do: :ok
  def category({:error, [%{category: c} | _]}), do: c
  def category({:error, %{category: c}}), do: c
  def category(other), do: other

  def compile_case(body, extra \\ %{}) do
    case Kit.program(body, manifest(extra)) do
      {:ok, p} -> %{compile: :ok, run: Kit.run(p, :entry, [nil])}
      {:error, errors} -> %{compile: :error, diagnostics: errors}
    end
  end

  def limits do
    cases = [
      {"tail_cpu", "result(_) -> loop(). loop() -> loop().", %{},
       %{max_reductions: 100_000, wall_ms: 200}},
      {"wall", "result(_) -> loop(). loop() -> loop().", %{},
       %{max_reductions: nil, wall_ms: 40}},
      {"non_tail", "result(_) -> loop(0). loop(N) -> [N | loop(N+1)].", %{},
       %{heap_words: 100_000}},
      {"bignum_shift", "result(N) -> X = 1 bsl N, X band 1.", %{},
       %{heap_words: 100_000, wall_ms: 100}},
      {"bignum_multiply", "result(N) -> X = 1 bsl N, Y = X * X, Y band 1.", %{},
       %{heap_words: 100_000, wall_ms: 100}},
      {"refc_binary", "result(N) -> B = <<0:N>>, byte_size(B).", %{},
       %{heap_words: 100_000, wall_ms: 100}},
      {"subbinary",
       "result(N) -> B = <<0:N>>, binary:referenced_byte_size(binary:part(B,0,100)).", %{},
       %{heap_words: 100_000, wall_ms: 100}},
      {"binary_retention",
       "result(_) -> grow(1, []). grow(N,L) -> B = <<N:80000>>, grow(N+1,[B|L]).", %{},
       %{max_reductions: nil, heap_words: 100_000}},
      {"list_size", "result(_) -> lists:duplicate(1000000000, 1).", %{}, %{}},
      {"binary_size", "result(_) -> binary:copy(<<0>>, 1000000000).", %{}, %{}},
      {"map_growth", "result(_) -> grow(0, \#{}). grow(N, M) -> grow(N+1, M\#{N => N}).", %{},
       %{heap_words: 100_000}},
      {"tuple_growth", "result(_) -> grow({}). grow(T) -> grow(erlang:append_element(T, 1)).",
       %{}, %{heap_words: 100_000}},
      {"deep_nesting",
       "result(_) -> nest(10000, 1). nest(0, X) -> X; nest(N, X) -> nest(N-1, {X}).", %{}, %{}},
      {"stdout_flood", "result(_) -> flood(). flood() -> io:format(\"abc~n\"), flood().",
       %{limits: %{max_stdout_bytes: 128, max_stdout_chunks: 16}}, %{}},
      {"stdout_bytes", "result(_) -> flood(). flood() -> io:format(\"abc~n\"), flood().",
       %{limits: %{max_stdout_bytes: 64}}, %{}},
      {"stdout_chunk", "result(_) -> io:format(\"abcdefghijklmnop\").",
       %{limits: %{max_stdout_chunk_bytes: 8}}, %{}},
      {"output_bytes", "result(_) -> <<0:200>>.", %{limits: %{max_output_bytes: 16}}, %{}},
      {"format_width", "result(_) -> io_lib:format(\"~1000000000c\", [65]).", %{},
       %{heap_words: 100_000, wall_ms: 100}},
      {"binary_matches", "result(_) -> binary:matches(<<0:8000000>>, <<0>>).", %{}, %{}},
      {"regex",
       "result(_) -> re:run(<<\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa!\">>, <<\"^(a+)+$\">>, [{match_limit, 1000000000}]).",
       %{}, %{}},
      {"phash2", "result(_) -> erlang:phash2(lists:duplicate(9999, 1)).", %{}, %{}},
      {"term_to_binary", "result(_) -> erlang:term_to_binary(lists:duplicate(9999, 1)).", %{},
       %{}},
      {"unicode", "result(_) -> unicode:characters_to_binary(lists:duplicate(9999, 16#10ffff)).",
       %{}, %{}},
      {"string",
       "result(_) -> string:replace(lists:duplicate(9999, 97), \"a\", \"aaaaaaaa\", all).", %{},
       %{}}
    ]

    Enum.map(cases, fn {name, src, extra, policy} ->
      compiled = Kit.program(src, manifest(extra))

      input =
        case name do
          "bignum_shift" -> 100_000_000
          "bignum_multiply" -> 1_000_000
          "refc_binary" -> 800_000_000
          "subbinary" -> 80_000_000
          _ -> nil
        end

      measured(name, fn ->
        case compiled do
          {:ok, p} ->
            Task.async(fn -> Kit.run(p, :entry, [input], policy: policy) end) |> Task.await(2_000)

          other ->
            other
        end
      end)
    end)
  end

  def pooled_budget do
    measured("pooled reduction budget across distinct programs", fn ->
      binding = %{
        "pause" => %{
          wait: fn ->
            Process.sleep(40)
            1
          end
        }
      }

      p =
        program("result(N) -> loop(N), pause:wait(). loop(0) -> 1; loop(N) -> loop(N-1).", %{
          bindings: binding
        })

      q =
        program("result(N) -> loop(N), pause:wait(), 2. loop(0) -> 2; loop(N) -> loop(N-1).", %{
          bindings: binding
        })

      policy = [bindings: binding, policy: %{max_reductions: 200_000, wall_ms: 500}]
      results = for _ <- 1..16, do: Kit.run(p, :entry, [80_000], policy)
      victim = Kit.run(q, :entry, [80_000], policy)
      clean = Task.async(fn -> Kit.run(q, :entry, [80_000], policy) end) |> Task.await()

      %{
        categories: Enum.map(results, &category/1),
        victim: victim,
        clean: clean,
        groups:
          Enum.map(:sys.get_state(Hyperlang.Limits).groups, fn {_, g} ->
            Map.take(g, [:usage_reductions, :limits])
          end)
      }
    end)
  end

  def child_lifetime do
    measured("guest child survives released group", fn ->
      owner = self()

      Application.put_env(:hyperlang, :guest_spawn_hook, fn fun, _ ->
        pid = spawn(fun)
        send(owner, {:child, pid})
        {:ok, 7, %{pid: pid}}
      end)

      p = program("result(_) -> spawn(fun() -> spin() end), 1. spin() -> spin().")
      result = Kit.run(p, :entry, [nil], policy: %{max_reductions: 200_000, wall_ms: 60})

      receive do
        {:child, pid} ->
          Process.sleep(100)
          a = Process.info(pid, [:reductions, :status, :message_queue_data])
          Process.sleep(100)
          b = Process.info(pid, [:reductions, :status, :message_queue_data])

          group_members =
            for {_, g} <- :sys.get_state(Hyperlang.Limits).groups, do: Map.keys(g.members)

          Process.exit(pid, :kill)
          %{run: result, after_100ms: a, after_200ms: b, members: group_members}
      after
        1_000 -> :missing_child
      end
    end)
  end

  def timers do
    measured("same program tenant timer quota and cross-run cancellation", fn ->
      sink = spawn(fn -> Process.sleep(:infinity) end)

      Application.put_env(:hyperlang, :guest_msg_resolver, fn _, _ ->
        {:ok, sink, %{sender_ctx: 1}}
      end)

      Application.put_env(:hyperlang, :guest_timer_max_outstanding, 2)

      p =
        program(
          "result(0) -> erlang:send_after(60000, 1, <<\"secret\">>); result(Id) -> erlang:cancel_timer(Id)."
        )

      scope_a = make_ref()
      scope_b = make_ref()
      :ok = Hyperlang.Scope.configure(scope_a, %{})
      :ok = Hyperlang.Scope.configure(scope_b, %{})

      a =
        Task.async(fn ->
          for _ <- 1..3, do: Kit.run(p, :entry, [0], policy: %{scope: scope_a})
        end)
        |> Task.await()

      b = Task.async(fn -> Kit.run(p, :entry, [0], policy: %{scope: scope_b}) end) |> Task.await()
      {:ok, id, _} = hd(a)
      cancel = Kit.run(p, :entry, [id], policy: %{scope: scope_b})
      reader = program("result(Id) -> erlang:read_timer(Id).")
      read = Kit.run(reader, :entry, [id], policy: %{scope: scope_b})
      own_cancel = Kit.run(p, :entry, [id], policy: %{scope: scope_a})
      after_cancel = Kit.run(p, :entry, [0], policy: %{scope: scope_a})
      :ok = Hyperlang.Scope.close(scope_a)
      :ok = Hyperlang.Scope.close(scope_b)
      Process.exit(sink, :kill)

      %{
        tenant_a: a,
        tenant_b: b,
        cancellation_from_b: cancel,
        read_from_b: read,
        own_cancel: own_cancel,
        after_cancel: after_cancel
      }
    end)
  end

  def queue_flag do
    measured("actual worker mailbox storage", fn ->
      binding = %{
        "inspectq" => %{
          get: fn -> Process.info(self(), [:message_queue_data, :max_heap_size]) |> inspect() end
        }
      }

      p = program("result(_) -> inspectq:get().", %{bindings: binding})

      %{
        default: Kit.run(p, :entry, [nil], bindings: binding),
        explicit: Kit.run(p, :entry, [nil], bindings: binding, policy: %{max_heap_words: 200_000})
      }
    end)
  end

  def startchans do
    measured("start channel table lifetime", fn ->
      owner = self()

      a =
        spawn(fn ->
          p = program("result(_) -> sys:startchan().", %{sys: %{enabled: true}})
          handle = Kit.run(p, :entry, [nil], policy: %{run_in_caller?: true})

          receive do
            :hold -> :ok
          after
            100 -> :ok
          end

          send(owner, {:a, self(), handle})

          receive do
            :stop -> :ok
          end
        end)

      receive do
        {:a, ^a, first} ->
          p = program("result(_) -> sys:startchan().", %{sys: %{enabled: true}})
          {:ok, second, _} = Kit.run(p, :entry, [nil], policy: %{run_in_caller?: true})
          table_owner = :ets.info(:hyperlang_startchans, :owner)
          live_handles = :ets.info(:hyperlang_startchans, :size)
          Process.exit(a, :kill)
          Process.sleep(40)

          {:ok, first_handle, _} = first
          first_rows = :ets.lookup(:hyperlang_startchans, first_handle)
          sender = spawn(fn -> Hyperlang.Chan.startchan_send(second, 7) end)
          received = Hyperlang.Chan.startchan_recv(second)
          Process.monitor(sender)

          %{
            first_rows_after_exit: first_rows,
            rows_after_receive: :ets.info(:hyperlang_startchans, :size),
            first: first,
            second: second,
            owned_by_first: table_owner == a,
            live_handles_before_exit: live_handles,
            table_after_owner_exit: :ets.whereis(:hyperlang_startchans),
            second_receive: received
          }
      after
        1_000 -> :missing_owner
      end
    end)
  end

  def actor do
    measured("default actor callback is metered", fn ->
      src =
        "init(_) -> {ok, 0}. handle_call(<<\"spin\">>, _, S) -> spin(), {reply, 1, S}; handle_call(_, _, S) -> {reply, 1, S}. handle_info(_, S) -> {noreply,S}. spin() -> spin()."

      p =
        program(src, %{
          result: %{name: "init", arity: 1},
          terms: %{public: :erlang, allowed_atoms: [:ok, :reply, :noreply]}
        })

      actor = Kit.start_actor!(p, nil)
      mon = Process.monitor(actor)
      start = System.monotonic_time(:microsecond)

      spawn(fn ->
        try do
          GenServer.call(actor, "spin", 2_000)
        catch
          _, _ -> :ok
        end
      end)

      down =
        receive do
          {:DOWN, ^mon, :process, ^actor, reason} ->
            %{reason: inspect(reason), time_us: System.monotonic_time(:microsecond) - start}
        after
          2_000 ->
            Process.exit(actor, :kill)
            :unmetered
        end

      messages =
        for term <- [self(), make_ref(), fn -> :ok end] do
          a = Kit.start_actor!(p, nil)
          m = Process.monitor(a)
          send(a, term)

          receive do
            {:DOWN, ^m, :process, ^a, why} -> inspect(why)
          after
            1_000 ->
              Process.exit(a, :kill)
              :accepted
          end
        end

      %{spin: down, hostile_messages: messages}
    end)
  end

  def cache_isolation do
    measured("concurrent manifest and binding state separation", fn ->
      src = "result(_) -> value:get()."
      binding = %{"value" => %{get: fn -> "compile" end}}
      a = program(src, %{bindings: binding})
      b = program(src, %{bindings: binding, limits: %{max_binary_bytes: 32}})

      results =
        1..40
        |> Enum.map(fn i ->
          Task.async(fn ->
            Kit.run(if(rem(i, 2) == 0, do: a, else: b), :entry, [nil],
              bindings: %{"value" => %{get: fn -> Integer.to_string(i) end}}
            )
          end)
        end)
        |> Enum.map(&Task.await/1)

      key = {:isolation_cache, 1}

      {:ok, cached} =
        Hyperlang.program(key, fn ->
          %{entry: "main.erl", files: %{"main.erl" => "result(_) -> 11."}}
        end)

      {:ok, collision} = Hyperlang.program(key, fn -> raise "loader should not run" end)

      %{
        different_manifests_differ: a.content_hash != b.content_hash,
        per_tenant_values:
          Enum.map(results, fn
            {:ok, v, _} -> v
            other -> other
          end),
        cache_key_is_caller_owned: cached == collision
      }
    end)
  end

  def atoms do
    measured("independent source atom universes", fn ->
      source_atoms =
        for i <- 1..100 do
          run("result(_) -> atom_to_binary('fresh_source_name_#{i}').")
        end

      %{
        all_source_names_projected:
          Enum.with_index(source_atoms, 1)
          |> Enum.all?(fn {r, i} ->
            match?({:ok, _, _}, r) and elem(r, 1) == "fresh_source_name_#{i}"
          end),
        host_atom_exists:
          try do
            String.to_existing_atom("fresh_source_name_100")
            true
          rescue
            ArgumentError -> false
          end,
        configured_source_slots: Hyperlang.GeneratedAtoms.max_source_atoms(),
        universes: map_size(:sys.get_state(Hyperlang.AtomUniverse).universes)
      }
    end)
  end

  def allocation_floods do
    scope = make_ref()
    Application.put_env(:hyperlang, :guest_channel_scope, fn -> scope end)
    sink = spawn(fn -> Process.sleep(:infinity) end)

    Application.put_env(:hyperlang, :guest_msg_resolver, fn _, _ ->
      {:ok, sink, %{max_mailbox: 8, sender_ctx: 1}}
    end)

    cases = [
      {"mailbox_quota", "result(_) -> fill(20). fill(0) -> 1; fill(N) -> 1 ! N, fill(N-1).", %{}},
      {"channel_flood",
       "result(_) -> fill(2000, 0). fill(0, C) -> C; fill(N, C) -> case sys:newchan(1) of nil -> C; _ -> fill(N-1, C+1) end.",
       %{sys: %{enabled: true}}},
      {"table_flood",
       "result(_) -> fill(2000). fill(0) -> 1; fill(N) -> hyperlang_table:new(set), fill(N-1).",
       %{tables: %{enabled: true}}},
      {"startchan_flood",
       "result(_) -> fill(2000, 0). fill(0, C) -> C; fill(N, C) -> case sys:startchan() of nil -> C; _ -> fill(N-1, C+1) end.",
       %{sys: %{enabled: true}}}
    ]

    try do
      Enum.map(cases, fn {label, src, m} -> measured(label, fn -> compile_case(src, m) end) end)
    after
      Process.exit(sink, :kill)
      Hyperlang.Chan.close_scope(scope)
    end
  end

  def leaks_chunk(mode, count) do
    {src, policy} =
      case mode do
        :normal ->
          {"result(_) -> 1.", %{max_reductions: nil}}

        :wall ->
          {"result(_) -> spin(). spin() -> spin().", %{max_reductions: nil, wall_ms: 1}}

        :reductions ->
          {"result(_) -> spin(). spin() -> spin().", %{max_reductions: 10_000, wall_ms: 500}}

        :heap ->
          {"result(_) -> grow([]). grow(L) -> grow([1|L]).",
           %{heap_words: 100_000, max_reductions: nil}}
      end

    p = program(src)

    measured("#{count} fresh caller #{mode} runs", fn ->
      results =
        for _ <- 1..count do
          Task.async(fn -> Kit.run(p, :entry, [nil], policy: policy) end) |> Task.await()
        end

      %{count: count, mode: mode, outcomes: Enum.frequencies_by(results, &category/1)}
    end)
  end

  def noisy(mode, count) do
    p = program("result(N) -> loop(N). loop(0) -> 1; loop(N) -> loop(N-1).")
    cpu = program("result(_) -> spin(). spin() -> spin().")
    memory = program("result(_) -> grow([]). grow(L) -> grow([<<0:80000>>|L]).")

    atom_src = fn i ->
      "result(_) -> [" <> Enum.map_join(1..150, ",", &"'noise_#{i}_#{&1}'") <> "]."
    end

    for _ <- 1..20, do: Kit.run(p, :entry, [500])

    measured("victim under #{count} #{mode} attackers", fn ->
      owner = self()
      end_at = System.monotonic_time(:millisecond) + 1_000

      attackers =
        if count == 0 do
          []
        else
          for i <- 1..count do
            spawn(fn ->
              send(owner, {:attacker_ready, self()})
              noise_loop(mode, cpu, memory, atom_src, i, end_at)
            end)
          end
        end

      Enum.each(attackers, fn a ->
        receive do
          {:attacker_ready, ^a} -> :ok
        after
          100 -> :ok
        end
      end)

      Process.sleep(if(count == 0, do: 0, else: 40))

      samples =
        for _ <- 1..300 do
          {us, result} =
            :timer.tc(fn -> Kit.run(p, :entry, [500], policy: %{max_reductions: nil}) end)

          {us, category(result)}
        end

      Enum.each(attackers, &Process.exit(&1, :kill))
      Process.sleep(60)
      times = Enum.map(samples, &elem(&1, 0)) |> Enum.sort()

      %{
        mode: mode,
        attackers: count,
        samples: length(times),
        p50_us: Enum.at(times, 149),
        p99_us: Enum.at(times, 296),
        outcomes: Enum.frequencies_by(samples, &elem(&1, 1))
      }
    end)
  end

  defp noise_loop(mode, cpu, memory, atom_src, i, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      case mode do
        :cpu ->
          Kit.run(cpu, :entry, [nil], policy: %{max_reductions: nil, wall_ms: 1_000})

        :memory ->
          Kit.run(memory, :entry, [nil],
            policy: %{max_reductions: nil, heap_words: 100_000, wall_ms: 100}
          )

        :atoms ->
          Kit.program(atom_src.(i + System.unique_integer([:positive])), manifest())
      end

      noise_loop(mode, cpu, memory, atom_src, i, deadline)
    end
  end

  def fun_admission do
    measured("local fun execution and public fun rejection", fn ->
      id = program("result(X) -> X.")
      bindings = %{"funs" => %{get: fn -> &String.length/1 end}}
      p = program("result(_) -> F = funs:get(), F(<<\"abc\">>).", %{bindings: bindings})

      %{
        local: run("result(_) -> F = fun(X) -> X+1 end, F(2)."),
        internal_external: rejected_fun(&String.length/1),
        internal_local: rejected_fun(fn x -> String.length(x) end),
        internal_spoofed:
          rejected_fun(fn x -> String.length(x) end, %{
            slot_module: __MODULE__,
            slot_version: 1,
            token: 1,
            limits: %{},
            terms: %{}
          }),
        external_input: Kit.run(id, :entry, [&String.length/1]),
        external_import: Kit.run(p, :entry, [nil], bindings: bindings)
      }
    end)
  end

  defp rejected_fun(fun, ctx \\ %{}) do
    try do
      Hyperlang.Runtime.apply_guest_fun(ctx, fun, ["abc"])
    catch
      :error, reason -> {:rejected, reason}
    end
  end

  def handles do
    fs = %{
      enabled: true,
      file_compat: true,
      handle_compat: true,
      mounts: [
        %{
          virtual: "/data",
          backend: "memory",
          mode: :memory,
          allow: [:read],
          files: [%{path: "/data/a", content: "tenant data"}]
        }
      ]
    }

    measured("file and table handles across runs", fn ->
      p =
        program("result(0) -> file:open(\"/data/a\", [read]); result(H) -> file:read(H, 10).", %{
          filesystem: fs
        })

      first = Kit.run(p, :entry, [0])

      second =
        case first do
          {:ok, {:ok, h}, _} -> Kit.run(p, :entry, [h])
          other -> other
        end

      t =
        program(
          "result(0) -> hyperlang_table:new(set); result(T) -> hyperlang_table:lookup(T, 1).",
          %{
            tables: %{enabled: true}
          }
        )

      table = Kit.run(t, :entry, [0])

      next =
        case table do
          {:ok, h, _} -> Kit.run(t, :entry, [h])
          other -> other
        end

      %{
        file_open: first,
        file_next_run: second,
        file_internal:
          run("result(_) -> {ok,H} = file:open(\"/data/a\", [read]), file:read(H,10).", %{
            filesystem: fs
          }),
        table_open: table,
        table_next_run: next
      }
    end)
  end

  def compile_limits do
    cases = [
      {"source_bytes", "result(_) -> \"" <> String.duplicate("a", 51_000) <> "\".", %{}},
      {"nesting",
       "result(_) -> " <> String.duplicate("{", 400) <> "1" <> String.duplicate("}", 400) <> ".",
       %{}},
      {"integer_digits", "result(_) -> " <> String.duplicate("9", 5000) <> ".", %{}},
      # A trivial program compiles in about a millisecond, so the deadline
      # case needs one that does not: an OTP-compile guard bomb (seconds).
      {"compile_deadline", compile_guard_bomb(400), %{limits: %{max_compile_ms: 1}}},
      # The front end of a trivial program takes 10,000 to 20,000 reductions.
      {"compile_reductions", "result(X) -> lists:reverse(X).",
       %{limits: %{max_compile_reductions: 2_000}}}
    ]

    Enum.map(cases, fn {label, src, m} ->
      measured(label, fn ->
        case Kit.program(src, manifest(m)) do
          {:ok, _} -> :compiled
          other -> other
        end
      end)
    end)
  end

  defp compile_guard_bomb(terms) do
    guard = Enum.map_join(1..terms, " orelse ", &"(X =:= #{&1} andalso Y > #{&1})")
    "f(X, Y) when #{guard} -> 1; f(_, _) -> 0.\nresult({X, Y}) -> f(X, Y)."
  end

  def actor_hygiene do
    :logger.add_handler(:isolation_capture, Hyperlang.Isolation.LogCapture, %{
      level: :all,
      config: %{pid: self()}
    })

    :logger.set_primary_config(:level, :debug)
    secret = "BINDING_SECRET_7f941c_ISOLATION"

    try do
      for {explicit_status, verbose} <- [{false, false}, {false, true}, {true, false}] do
        Application.put_env(
          :logger,
          :translator_inspect_opts,
          if(verbose, do: [limit: :infinity, printable_limit: :infinity], else: [])
        )

        measured("actor status and crash with format_status=#{explicit_status}", fn ->
          source =
            "init(_) -> put(saved, fun() -> secret:ping() end), {ok, 0}. handle_call(_, _, S) -> {reply, 1, S}. handle_info(_, S) -> {noreply, S}."

          source = if explicit_status, do: source <> " format_status(S) -> S.", else: source

          p =
            program(source, %{
              result: %{name: "init", arity: 1},
              terms: %{public: :erlang, allowed_atoms: [:ok, :reply, :noreply]},
              bindings: %{"secret" => Hyperlang.Isolation.SecretBinding}
            })

          a =
            Kit.start_actor!(p, nil,
              bindings: %{
                "secret" =>
                  {Hyperlang.Isolation.SecretBinding, %{api_token: secret, tenant: "tenant-a"}}
              },
              policy: %{policy_secret: secret}
            )

          status_term = :sys.get_status(a)
          status = inspect(status_term, limit: :infinity, printable_limit: :infinity)
          monitor = Process.monitor(a)
          # Invalid host input exercises the normal fail-closed actor shutdown.
          send(a, self())

          down =
            receive do
              {:DOWN, ^monitor, :process, ^a, reason} -> inspect(reason)
            after
              1_000 ->
                Process.exit(a, :kill)
                :not_stopped
            end

          Logger.flush()
          events = collect_logs([])
          raw = inspect(events, limit: :infinity, printable_limit: :infinity)

          formatted =
            Enum.map_join(events, "\n", fn e ->
              try do
                :logger_formatter.format(e, %{
                  single_line: false,
                  depth: 1000,
                  max_size: 1_000_000
                })
                |> IO.iodata_to_binary()
              rescue
                _ -> inspect(e, limit: :infinity)
              end
            end)

          %{
            explicit_format_status: explicit_status,
            verbose_logger: verbose,
            stopped: down,
            log_events: length(events),
            status_contains_secret: contains_secret?(status_term, secret),
            status_secret_path: secret_path(status_term, secret),
            raw_event_contains_secret: contains_secret?(events, secret),
            formatted_log_contains_secret: String.contains?(formatted, secret),
            formatted_log_contains_spec: String.contains?(formatted, "bindings"),
            formatter_failed:
              String.contains?(raw <> formatted <> status, "did not return a map"),
            formatted_log_excerpt:
              if(String.contains?(formatted, secret),
                do: excerpt(formatted, secret),
                else: String.slice(formatted, 0, 300)
              )
          }
        end)
      end
    after
      Application.delete_env(:logger, :translator_inspect_opts)
      :logger.remove_handler(:isolation_capture)
      :logger.set_primary_config(:level, :emergency)
    end
  end

  def idle_limits do
    service = Process.whereis(Hyperlang.Limits)
    {:reductions, before} = Process.info(service, :reductions)
    Process.sleep(250)
    {:reductions, after_} = Process.info(service, :reductions)

    %{
      groups: map_size(:sys.get_state(service).groups),
      idle_window_ms: 250,
      service_reductions: after_ - before
    }
  end

  def channel_handles do
    a = make_ref()
    b = make_ref()

    p =
      program("result(<<\"new\">>) -> sys:newchan(1); result(H) -> sys:csend(H, 9).", %{
        sys: %{enabled: true}
      })

    try do
      measured("channel handle is namespace scoped", fn ->
        Application.put_env(:hyperlang, :guest_channel_scope, fn -> a end)
        {:ok, handle, _} = Kit.run(p, :entry, ["new"])
        Application.put_env(:hyperlang, :guest_channel_scope, fn -> b end)
        other_scope = Kit.run(p, :entry, [handle])
        Application.put_env(:hyperlang, :guest_channel_scope, fn -> a end)
        own_scope = Kit.run(p, :entry, [handle])
        %{handle: handle, own_scope: own_scope, other_scope: other_scope}
      end)
    after
      Hyperlang.Chan.close_scope(a)
      Hyperlang.Chan.close_scope(b)
    end
  end

  def spawn_quota do
    measured("max_procs is enforced at guest spawn", fn ->
      owner = self()

      Application.put_env(:hyperlang, :guest_spawn_hook, fn fun, _ ->
        pid = spawn(fun)
        send(owner, {:quota_child, pid})
        {:ok, 7, %{pid: pid}}
      end)

      p =
        program(
          "result(_) -> fill(3). fill(0) -> 1; fill(N) -> spawn(fun() -> receive after 1000 -> 1 end end), fill(N-1)."
        )

      result = Kit.run(p, :entry, [nil], policy: %{max_procs: 2})
      children = collect_quota_children([])
      Enum.each(children, &Process.exit(&1, :kill))
      %{result: result, admitted_children: length(children)}
    end)
  end

  defp collect_quota_children(acc) do
    receive do
      {:quota_child, pid} -> collect_quota_children([pid | acc])
    after
      20 -> acc
    end
  end

  def atom_capacity do
    measured("bounded shared atom universe and independent capacity", fn ->
      source = fn prefix ->
        names = Enum.map_join(1..2500, ",", &"#{prefix}#{&1}")
        "result(_) -> length([#{names}])."
      end

      shared = %{atom_universe: {:isolation_pool, 1}, limits: %{max_atom_count: 4096}}
      first = Kit.program(source.("poola"), manifest(shared))
      second = Kit.program(source.("poolb"), manifest(shared))
      independent = Kit.program(source.("poolc"), manifest(%{limits: %{max_atom_count: 4096}}))

      result = fn
        {:ok, p} -> Kit.run(p, :entry, [nil])
        other -> other
      end

      %{
        first: result.(first),
        second: result.(second),
        independent: result.(independent),
        fixed_slots: Hyperlang.GeneratedAtoms.max_source_atoms()
      }
    end)
  end

  # Structured status/events must also be safe when a logger walks fun
  # environments, rather than relying on Inspect's opaque fun rendering.
  defp contains_secret?(term, secret, seen \\ MapSet.new())

  defp contains_secret?(term, secret, _seen) when is_binary(term),
    do: String.contains?(term, secret)

  defp contains_secret?(term, secret, seen) when is_function(term) do
    if MapSet.member?(seen, term),
      do: false,
      else:
        contains_secret?(elem(:erlang.fun_info(term, :env), 1), secret, MapSet.put(seen, term))
  end

  defp contains_secret?(term, secret, seen) when is_map(term),
    do: contains_secret?(Map.to_list(term), secret, seen)

  defp contains_secret?(term, secret, seen) when is_tuple(term),
    do: contains_secret?(Tuple.to_list(term), secret, seen)

  defp contains_secret?([h | t], secret, seen),
    do: contains_secret?(h, secret, seen) or contains_secret?(t, secret, seen)

  defp contains_secret?(_, _, _), do: false

  defp secret_path(term, secret, path \\ [], seen \\ MapSet.new())

  defp secret_path(term, secret, path, _) when is_binary(term),
    do: if(String.contains?(term, secret), do: Enum.reverse(path))

  defp secret_path(term, secret, path, seen) when is_function(term) do
    if not MapSet.member?(seen, term),
      do:
        secret_path(
          elem(:erlang.fun_info(term, :env), 1),
          secret,
          [:fun_env | path],
          MapSet.put(seen, term)
        )
  end

  defp secret_path(term, secret, path, seen) when is_map(term),
    do:
      Enum.find_value(Map.to_list(term), fn {k, v} ->
        secret_path(v, secret, [inspect(k) | path], seen)
      end)

  defp secret_path(term, secret, path, seen) when is_tuple(term),
    do: secret_path(Tuple.to_list(term), secret, [:tuple | path], seen)

  defp secret_path(term, secret, path, seen) when is_list(term),
    do:
      term
      |> Enum.with_index()
      |> Enum.find_value(fn {v, i} -> secret_path(v, secret, [i | path], seen) end)

  defp secret_path(_, _, _, _), do: nil

  defp excerpt(s, needle) do
    {at, _} = :binary.match(s, needle)
    binary_part(s, max(0, at - 100), min(byte_size(s) - max(0, at - 100), 300))
  end

  defp collect_logs(acc) do
    receive do
      {:isolation_log, event} -> collect_logs([event | acc])
    after
      80 -> Enum.reverse(acc)
    end
  end
end

defmodule Hyperlang.Isolation.SecretBinding do
  @behaviour Hyperlang.Binding
  def exports, do: [ping: 0]
  def call(_state, :ping, []), do: 1
end

defmodule Hyperlang.Isolation.LogCapture do
  def adding_handler(config), do: {:ok, config}
  def removing_handler(_config), do: :ok
  def changing_config(_op, _old, new), do: {:ok, new}
  def log(event, %{config: %{pid: pid}}), do: send(pid, {:isolation_log, event})
end
