defmodule Hyperlang.Terms do
  @moduledoc false

  # ===========================================================================
  # Opaque opaque round-trip box (host export state fast path).
  #
  # A long-lived serving host threads one guest State value through exported
  # `handle/2` calls. The State leaves the guest after a fully validated output
  # walk and re-enters the same instance on the next input crossing unchanged.
  # The host never inspects it. Re-walking it each op is pure waste.
  #
  # `%Opaque{}` is the opaque carrier that lets the host hold an
  # ALREADY-VALIDATED State and normally pass it back un-walked:
  #
  #   * On the trusted-state RETURN crossing, AFTER the return value is fully
  #     walked (so every atom in it — the State included — has already passed the
  #     atom-pool defense), the State element is wrapped in a `%Opaque{}` whose
  #     `token` is the per-instance `ctx.token`. The host (webstyx) stores this
  #     box whole; it does not look inside.
  #   * On the next trusted-state ARG crossing, the host hands the SAME box back.
  #     The arg walk recognizes `%Opaque{token: t}`; iff `t` equals the live
  #     `ctx.token` it unwraps the inner term and returns it UN-WALKED.
  #
  # SECURITY ARGUMENT (atom-exhaustion defense stays provably intact):
  #
  #   1. The box is MINTED ONLY by the host-side return sanitizer, and only AFTER
  #      a full walk validated the wrapped term against `allowed_atoms`/the pool.
  #      So nothing ever skips its FIRST crossing — a brand-new/forbidden atom in
  #      a reply or in a freshly-produced State is still rejected the first time
  #      it crosses out (the return walk runs unconditionally, see below).
  #   2. The token is a per-instance `:erlang.unique_integer` held in the worker's
  #      ctx/runtime. Guest code can neither read it (it is in no guest-visible
  #      term; `Process.get` etc. are verifier-rejected) nor construct the
  #      `%Opaque{}` struct (its module atom `Hyperlang.Terms.Opaque` is not in
  #      any guest pool, so a guest-emitted struct with that tag is rejected as
  #      `:atom_not_allowed`). A guest CANNOT forge a box.
  #   3. The unwrap is gated on an EXACT integer token match against the LIVE
  #      ctx. A box minted for one instance/token cannot be replayed into another.
  #      A guest-supplied value that is not a `%Opaque{}` (or whose token does
  #      not match) falls through to the ordinary `walk`, so any atom it carries
  #      is validated normally.
  #   4. Only the host (webstyx) is on the trusted side; it sets the
  #      trusted-state directive on the SAME-process `run_in_caller?` call and
  #      holds the box opaquely. The guest never sees the directive or the box.
  #
  # Net: the trusted fast path can ONLY skip re-walking a term that THIS sanitizer
  # already fully validated on a prior crossing and that has been held opaquely
  # host-side since. The defense is unchanged for every other term and for the
  # first crossing of every term.
  # ===========================================================================
  defmodule Opaque do
    @moduledoc false
    @enforce_keys [:token, :term]
    defstruct [:token, :term]
  end

  @public_walk_categories MapSet.new([:import_args, :output, :error])
  @error_limits %{
    max_term_depth: 16,
    max_binary_bytes: 4_096,
    max_integer_bits: 4_096,
    max_tuple_size: 64,
    max_list_length: 128,
    max_map_size: 64,
    max_total_words: 2_048
  }
  @error_terms %{
    allowed_atoms: MapSet.new([true, false, nil]),
    nil: nil,
    allow_tuples: false,
    allow_atoms: false,
    allow_improper_lists: false,
    public: :json,
    atom_public: :binary,
    tuple_public: :list,
    binary_public: :binary,
    improper_list_public: :reject
  }
  @sys_fd_key "$sys_fd"

  # ===========================================================================
  # validate_runtime memoization (validate-at-introduction, not per-crossing).
  #
  # `validate_runtime` scans the HOST-built `token`/`limits`/`terms` for forbidden
  # primitives (pid/port/ref). Those three slots are constructed once by the host
  # when a run is prepared, are immutable BEAM terms, and are NEVER mutated by any
  # call-path code: `do_sandbox_call` rebuilds the per-call runtime with
  # `Map.put(:call_id, ...)` + the `:syscall`/`:opaque_state`
  # opts, none of which touch `:token`/`:limits`/`:terms`. So re-scanning them on
  # every crossing (~143 full `contains_forbidden?` recursions / deep GET) is pure
  # redundant work — the result can only ever be the same.
  #
  # `@validated_stamp` is a private module atom written into the runtime ONLY by
  # this validator, AFTER a full scan passed, bound to the exact validated
  # `{token, limits, terms}` triple. On a later crossing the stamp is honored iff
  # those three slots are PHYSICALLY the same terms that were stamped (an `===`
  # identity check, free for the structurally-shared immutable terms carried
  # straight through from `stored.runtime`). Any runtime whose token/limits/terms
  # differ from the stamped triple — or that carries no stamp, or a forged
  # `:__hyperlang_runtime_validated__` value a guest could never set (the runtime
  # map is host-only; no guest term reaches it) — falls through to the full scan.
  # So the defense is unchanged: a forbidden primitive in token/limits/terms is
  # still rejected; only an already-validated, host-held, identical triple skips
  # the re-scan.
  # ===========================================================================
  @validated_stamp :__hyperlang_runtime_validated__

  def validate_runtime(runtime) when is_map(runtime) do
    case runtime do
      %{@validated_stamp => {token, limits, terms}}
      when token === :erlang.map_get(:token, runtime) and
             limits === :erlang.map_get(:limits, runtime) and
             terms === :erlang.map_get(:terms, runtime) ->
        :ok

      _other ->
        full_validate_runtime(runtime)
    end
  end

  # Validate and return the runtime stamped with the validated identity triple, so
  # later crossings of the SAME host-built token/limits/terms skip the re-scan.
  # Called once by the host when a run is prepared. Raises (like validate_runtime) on
  # a forbidden primitive, so a bad runtime is never stamped.
  def stamp_validated_runtime(runtime) when is_map(runtime) do
    :ok = validate_runtime(runtime)

    put_validated_stamp(runtime)
  end

  @doc false
  def stamp_prevalidated_runtime(runtime) when is_map(runtime) do
    put_validated_stamp(runtime)
  end

  defp put_validated_stamp(runtime) do
    Map.put(
      runtime,
      @validated_stamp,
      {Map.fetch!(runtime, :token), Map.fetch!(runtime, :limits), Map.fetch!(runtime, :terms)}
    )
  end

  defp full_validate_runtime(runtime) do
    cond do
      contains_forbidden?(runtime.token) ->
        raise ArgumentError, "runtime token contains forbidden term"

      contains_forbidden?(runtime.limits) ->
        raise ArgumentError, "runtime limits contain forbidden term"

      contains_forbidden?(runtime.terms) ->
        raise ArgumentError, "runtime term policy contains forbidden term"

      true ->
        :ok
    end
  end

  def atom_source(atom, ctx_or_terms_or_pool) when is_atom(atom) do
    local_atom_source(atom, atom_source_pool(ctx_or_terms_or_pool)) ||
      universe_atom_source(atom, atom_source_universe(ctx_or_terms_or_pool)) ||
      Hyperlang.KernelAtomPool.source(atom)
  end

  def atom_source(_value, _ctx_or_terms_or_pool), do: nil

  defp atom_source_pool(%{atom_pool: pool}) when is_map(pool), do: pool
  defp atom_source_pool(%{terms: %{atom_pool: pool}}) when is_map(pool), do: pool
  defp atom_source_pool(%{terms: terms}) when is_map(terms), do: Map.get(terms, :atom_pool, %{})
  defp atom_source_pool(pool) when is_map(pool), do: pool
  defp atom_source_pool(_value), do: %{}

  defp local_atom_source(atom, atom_pool) when is_map(atom_pool), do: Map.get(atom_pool, atom)

  defp atom_source_universe(%{atom_universe: universe}), do: universe

  defp atom_source_universe(%{terms: terms}) when is_map(terms),
    do: Map.get(terms, :atom_universe)

  defp atom_source_universe(_value), do: nil

  defp universe_atom_source(_atom, nil), do: nil

  defp universe_atom_source(atom, universe) when is_atom(atom) do
    if Hyperlang.GeneratedAtoms.source_atom?(atom) do
      Hyperlang.AtomUniverse.source_for_atom(universe, atom)
    end
  end

  def sanitize_input(input, ctx), do: sanitize(input, ctx, :input)

  def sanitize_output(output, ctx) do
    case sanitize(output, ctx, :output) do
      {:ok, safe} -> maybe_box_return_state(safe, ctx)
      error -> error
    end
  end

  # The single reply sanitizer for both execution shapes: the worker envelope
  # (worker.ex) and the in-runtime export envelope (runtime.ex). `carry` decides
  # which opaque envelope fields survive sanitization — the worker carries the
  # trusted host-state/exit-status slots, the runtime carries nothing extra.
  # A `module_entry` context has already crossed the caller -> callee boundary
  # in ModuleLoader, so its result is passed through untouched.
  def sanitize_reply(reply, ctx, carry) when is_function(carry, 2) do
    case reply do
      {:ok, %{result: result, stdout: stdout} = envelope} ->
        with {:ok, result} <- sanitize_reply_result(result, ctx),
             {:ok, stdout} <- sanitize_stdout(stdout, ctx) do
          {:ok, carry.(%{result: result, stdout: stdout}, envelope)}
        else
          {:error, %{category: _category} = reason} -> {:error, sanitize_error(reason, ctx)}
        end

      {:ok, value} ->
        {:error,
         sanitize_error(%{category: :runtime, reason: {:malformed_success_reply, value}}, ctx)}

      {:error, error} ->
        {:error, sanitize_error(error, ctx)}

      other ->
        {:error, sanitize_error(%{category: :runtime, reason: other}, ctx)}
    end
  end

  defp sanitize_reply_result(result, %{module_entry: true}), do: {:ok, result}
  defp sanitize_reply_result(result, ctx), do: sanitize_output(result, ctx)

  def sanitize_import_args(args, ctx, import_meta),
    do: sanitize_with_limits(args, ctx, import_meta[:limits] || %{}, :import_args)

  def sanitize_import_return(value, ctx, import_meta),
    do: sanitize_with_limits(value, ctx, import_meta[:limits] || %{}, :import_return)

  def sanitize_filesystem_args(args, ctx), do: sanitize(args, ctx, :filesystem_args)
  def sanitize_filesystem_return(value, ctx), do: sanitize(value, ctx, :filesystem_return)
  def sanitize_stdlib_args(args, ctx), do: sanitize(args, ctx, :stdlib_args)
  def sanitize_stdlib_return(value, ctx), do: sanitize(value, ctx, :stdlib_return)

  # The `:docs` category: replies of the
  # `code:` surface. `max_bytes` is `modules.max_doc_chunk_bytes`, applied
  # only to `code:get_doc/1` replies; `nil` skips the chunk cap.
  def sanitize_docs(value, ctx, nil), do: sanitize(value, ctx, :docs)

  def sanitize_docs(value, ctx, max_bytes) when is_integer(max_bytes),
    do: sanitize_with_limits(value, ctx, %{max_docs_bytes: max_bytes}, :docs)

  # Module term boundary: args cross caller -> library with the library pool as the
  # translation target; returns cross library -> caller with the caller pool
  # as the target. Canonical artifacts in one AtomUniverse share identities;
  # a bounded process-local kernel pool carries names only when two artifacts
  # genuinely do not share a universe.
  def sanitize_module_args(args, ctx, library) when is_list(args),
    do: sanitize_module_boundary(args, ctx, module_pool(ctx), module_pool(library), :module_args)

  def sanitize_module_return(value, ctx, library) do
    sanitize_module_boundary(
      value,
      ctx,
      module_pool(library),
      module_pool(ctx),
      :module_return
    )
  end

  defp module_pool(%{atom_pool: pool, atom_universe: universe}) when is_map(pool),
    do: %{pool: pool, universe: universe}

  defp module_pool(%{terms: terms} = value) when is_map(terms) do
    %{
      pool: Map.get(value, :atom_pool, Map.get(terms, :atom_pool, %{})),
      universe: Map.get(value, :atom_universe, Map.get(terms, :atom_universe))
    }
  end

  defp module_pool(pool) when is_map(pool), do: %{pool: pool, universe: nil}

  defp sanitize_module_boundary(value, ctx, source, target, category) do
    target_by_source = Map.new(target.pool, fn {atom, name} -> {name, atom} end)

    ctx =
      ctx
      |> Map.put(:atom_pool, source.pool)
      |> Map.put(:atom_universe, source.universe)
      |> Map.update!(:terms, fn terms ->
        terms
        |> Map.put(:module_target_pool, target_by_source)
        |> Map.put(:module_target_universe, target.universe)
      end)

    sanitize(value, ctx, category)
  end

  def opaque_box(term, %{token: token}), do: %Opaque{token: token, term: term}

  def opaque_term(%Opaque{token: token, term: term}, %{token: token}), do: {:ok, term}
  def opaque_term(_value, _ctx), do: :error

  # The trusted-state directive (set by a long-lived serving host through call
  # opts): `%{return_state: elem}` names the return-tuple State
  # element to mint a `%Opaque{}` box for. Absent => no fast path. The ARG side
  # is token-checked by `walk` and may unwrap only when this directive is active.
  # After the return value is FULLY validated by the output walk, re-box the
  # State element so the host can hold it opaquely and pass it back
  # un-walked next op. The box is minted ONLY here — post-validation — and
  # stamped with the live `ctx.token`. A guest can never produce an accepted box
  # (it can neither learn the per-instance token nor name the `Opaque` struct),
  # so nothing skips its first crossing; only an already-validated, host-held
  # State is ever passed back un-walked. The boxed term is the SAME term the full
  # walk just validated (a verified fixed point of the round-trip), so unwrapping
  # it later is observationally identical to re-walking it.
  defp maybe_box_return_state(safe, %{opaque_state: %{return_state: elem}} = ctx)
       when is_integer(elem) and elem >= 0 and is_tuple(safe) and tuple_size(safe) > elem do
    {:ok, put_elem(safe, elem, opaque_box(elem(safe, elem), ctx))}
  end

  defp maybe_box_return_state(_safe, %{opaque_state: %{return_state: elem}})
       when is_integer(elem) and elem >= 0,
       do: {:error, %{category: :output, reason: :opaque_state_return}}

  defp maybe_box_return_state(safe, _ctx), do: {:ok, safe}

  def sanitize_stdout([], _ctx), do: {:ok, []}

  def sanitize_stdout(stdout, ctx) when is_list(stdout) do
    stricter = %{
      max_binary_bytes: ctx.limits.max_stdout_chunk_bytes,
      max_list_length: ctx.limits.max_stdout_chunks
    }

    with {:ok, safe} <- sanitize_with_limits(stdout, ctx, stricter, :stdout),
         :ok <- check_stdout_bytes(safe, ctx.limits) do
      {:ok, safe}
    end
  end

  def sanitize(value, ctx, category) do
    sanitize_with_limits(value, ctx, %{}, category)
  end

  # ONE structural error contract on the door. `program/1` errors are built by
  # `Hyperlang.Error.normalize/1`; `run/4` errors are built here. Both are
  # `%{category:, message:, span:, details:}`. Only the VALUES differ, and they
  # must: everything a run/4 error carries has crossed the term walk, so guest
  # atoms arrive as their pooled source strings and every structured remainder
  # (reason, class, exception, stack) lands in `details`.
  def sanitize_error(error, ctx_or_runtime \\ nil) do
    ctx = error_context(ctx_or_runtime)
    terms = terms_with_atom_pool(ctx)
    error = normalize_error_term(error, terms)

    case sanitize_with_limits(error, ctx, %{}, :error) do
      {:ok, safe} ->
        door_error(safe)

      {:error, reason} ->
        door_error(%{
          "category" => "internal",
          "reason" => "error_sanitizer_failed",
          "details" => inspect(reason, limit: 10, printable_limit: 200)
        })
    end
  end

  defp door_error(%{} = safe) do
    {category, safe} = Map.pop(safe, "category")
    {message, safe} = Map.pop(safe, "message")
    {span, safe} = Map.pop(safe, "span")
    {details, safe} = Map.pop(safe, "details")

    %{
      category: Hyperlang.Fault.public_category(category),
      message: error_message(message, safe),
      span: span,
      details: error_details(details, safe)
    }
  end

  defp error_message(message, _rest) when is_binary(message), do: message
  defp error_message(_message, %{"reason" => reason}) when is_binary(reason), do: reason

  defp error_message(_message, %{"reason" => reason}),
    do: inspect(reason, limit: 10, printable_limit: 200)

  defp error_message(_message, _rest), do: ""

  defp error_details(nil, rest), do: rest
  defp error_details(details, rest) when is_map(details), do: Map.merge(details, rest)
  defp error_details(details, rest), do: Map.put(rest, "details", details)

  def sanitize_with_limits(value, ctx, stricter, category) do
    limits =
      Map.merge(ctx.limits, stricter || %{}, fn _, base, strict ->
        if is_integer(strict), do: min(base, strict), else: base
      end)

    public? = MapSet.member?(@public_walk_categories, category)
    terms = terms_with_atom_pool(ctx)

    case walk(value, terms, limits, 0, %{words: 0, bytes: 0, max_depth: 0}, public?, category) do
      {:ok, safe, stats} -> {:ok, safe, stats}
      {:error, reason} -> {:error, %{category: category, reason: reason}}
    end
    |> case do
      {:ok, safe, stats} ->
        with :ok <- check_category_byte_limit(category, stats, limits) do
          {:ok, safe}
        end

      error ->
        error
    end
  end

  defp terms_with_atom_pool(ctx) do
    pool = Map.get(ctx, :atom_pool, Map.get(ctx.terms, :atom_pool, %{}))

    ctx.terms
    |> Map.put(:atom_pool, pool)
    |> Map.put(:atom_universe, Map.get(ctx, :atom_universe, Map.get(ctx.terms, :atom_universe)))
    |> Map.put(:kernel_atom_limit, Map.get(ctx.limits, :max_atom_count, 0))
    |> Map.put(:safe_fun_module, Map.get(ctx, :slot_module))
    # The per-instance boundary token authorizes the Opaque opaque round-trip
    # fast path in `walk`. It is carried into `terms` so every walk of an
    # instance's terms can recognize a box THIS instance minted. A box is only
    # ever produced when the trusted-state directive is set (a serving host), and
    # never by a guest; cross-instance replay fails because the token differs.
    |> Map.put(:boundary_token, Map.get(ctx, :token))
    |> Map.put(:opaque_state, Map.get(ctx, :opaque_state))
  end

  defp sys_guest_fd?(%{@sys_fd_key => fd}) when is_integer(fd) and fd >= 0, do: true
  defp sys_guest_fd?(_value), do: false

  defp walk(value, terms, limits, depth, stats, public?, category) do
    stats = %{stats | max_depth: max(stats.max_depth, depth)}

    cond do
      depth > limits.max_term_depth ->
        {:error, :term_depth}

      is_struct(value, Opaque) ->
        # Opaque opaque round-trip fast path. A `%Opaque{}` box is minted ONLY
        # by `maybe_box_return_state` AFTER a full walk already validated its
        # inner term, and is stamped with the per-instance `ctx.token`. It is
        # held opaquely host-side and fed back through the SAME library on the
        # next op. While it is token-valid it is NEVER re-walked:
        #
        #   * on the host-entry boundary (`:input`) the inner,
        #     already-validated term is UNWRAPPED and handed back to the same
        #     guest instance un-walked;
        #   * on every other crossing (notably the host-facing `:output` pass the
        #     freshly-minted box rides out on) the box passes through UNCHANGED,
        #     so the host receives and holds the opaque box to feed back next op.
        #
        # SECURITY: a guest cannot forge a box (it can neither learn the token —
        # a per-instance unique integer in no guest-visible term — nor name the
        # `Hyperlang.Terms.Opaque` struct, whose module atom is in no guest pool).
        # A box with a non-matching/absent token (or any guest-emitted struct)
        # FAILS the token guard and falls through to the ordinary struct walk
        # below (`walk_map`), where its atoms face the full atom-pool defense.
        # So the atom-exhaustion guarantee is untouched: only an already-
        # validated, host-minted, token-matching box ever skips a re-walk.
        cond do
          opaque_box?(value, terms) and opaque_input_category?(category, terms) ->
            ok_passthrough(value.term, stats)

          opaque_box?(value, terms) and category == :output ->
            ok_passthrough(value, stats)

          true ->
            {:error, :forged_opaque_term}
        end

      is_integer(value) ->
        if integer_bits(value) <= limits.max_integer_bits,
          do: ok(value, stats),
          else: {:error, :integer_bits}

      is_float(value) or is_boolean(value) or is_nil(value) ->
        ok(value, stats)

      safe_stdlib_fun?(value, terms, category) ->
        ok(value, stats)

      # `:fail` is the hyperbob_os sh control-throw atom (`throw({fail, <status>})`
      # - Context.fail, loop break/continue). It must always be allowed across the
      # term boundary: a guest throw re-raised across a SECOND modcall boundary
      # (deep nesting sh->std->sh->std) re-sanitizes its term, and without this a fatal
      # `${builtin}`/concat fail crossing a 2nd boundary was rejected
      # (`atom_not_allowed`) -> downgraded to `:emodcall` -> the throw was lost and the
      # script kept running past a fatal error (#119). Safe: a single fixed atom.
      value == :fail ->
        ok(value, stats)

      is_atom(value) ->
        cond do
          terms.allow_atoms and MapSet.member?(terms.allowed_atoms, value) ->
            public_atom(value, terms, limits, stats, public?)

          terms.allow_atoms and module_boundary?(category) and pooled_atom?(value, terms) ->
            module_pooled_atom(value, terms, stats)

          terms.allow_atoms and pooled_atom?(value, terms) and pooled_atom_boundary?(category) ->
            public_pooled_atom(value, terms, limits, stats, public?)

          true ->
            {:error, {:atom_not_allowed, value}}
        end

      is_binary(value) ->
        if byte_size(value) <= limits.max_binary_bytes do
          public_binary(value, terms, limits, stats, public?)
        else
          {:error, :binary_bytes}
        end

      is_bitstring(value) ->
        bitstring_bytes = div(bit_size(value) + 7, 8)

        cond do
          public? ->
            {:error, :unsupported_bitstring}

          bitstring_bytes <= limits.max_binary_bytes ->
            ok(value, %{stats | bytes: stats.bytes + bitstring_bytes})

          true ->
            {:error, :binary_bytes}
        end

      is_function(value) ->
        {:error, :forbidden_term}

      is_pid(value) or is_port(value) ->
        {:error, :forbidden_term}

      is_reference(value) ->
        if Hyperlang.Filesystem.guest_handle?(value) do
          file_handle_result(value, stats, category)
        else
          {:error, :forbidden_term}
        end

      is_tuple(value) ->
        cond do
          not terms.allow_tuples ->
            {:error, :tuple_not_allowed}

          tuple_size(value) > limits.max_tuple_size ->
            {:error, :tuple_size}

          true ->
            value
            |> Tuple.to_list()
            |> walk_list(terms, limits, depth + 1, stats, public?, category)
            |> case do
              {:ok, list, stats} -> public_tuple(list, terms, stats, public?)
              error -> error
            end
        end

      is_list(value) ->
        if proper_list?(value) do
          if length(value) <= limits.max_list_length do
            walk_list(value, terms, limits, depth + 1, stats, public?, category)
          else
            {:error, :list_length}
          end
        else
          {:error, :improper_list}
        end

      true ->
        cond do
          sys_guest_fd?(value) -> file_handle_result(value, stats, category)
          native_record?(value) -> {:error, :native_record}
          true -> walk_map(value, terms, limits, depth, stats, public?, category)
        end
    end
  end

  defp file_handle_result(value, stats, category) do
    cond do
      filesystem_boundary?(category) -> ok(value, stats)
      true -> {:error, :forbidden_file_handle}
    end
  end

  defp walk_map(value, terms, limits, depth, stats, public?, category) do
    if map_size(value) <= limits.max_map_size do
      Enum.reduce_while(value, {:ok, %{}, stats}, fn {k, v}, {:ok, acc, stats} ->
        with {:ok, k, stats} <-
               walk_map_key(k, terms, limits, depth + 1, stats, public?, category),
             {:ok, v, stats} <-
               walk(v, terms, limits, depth + 1, stats, public?, category) do
          {:cont, {:ok, Map.put(acc, k, v), stats}}
        else
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, map, stats} -> ok(map, stats)
        error -> error
      end
    else
      {:error, :map_size}
    end
  rescue
    BadMapError -> {:error, :unsupported_term}
  end

  defp native_record?(value) do
    :records.get_module(value)
    true
  rescue
    _ -> false
  end

  defp check_category_byte_limit(:input, stats, limits),
    do: check_byte_limit(stats, limits.max_input_bytes, :input_bytes)

  defp check_category_byte_limit(:output, stats, limits),
    do: check_byte_limit(stats, limits.max_output_bytes, :output_bytes)

  defp check_category_byte_limit(:stdout, stats, limits),
    do: check_byte_limit(stats, limits.max_stdout_bytes, :stdout_bytes)

  defp check_category_byte_limit(:docs, stats, limits),
    do: check_byte_limit(stats, Map.get(limits, :max_docs_bytes), :docs_bytes)

  defp check_category_byte_limit(_category, _stats, _limits), do: :ok

  defp check_byte_limit(stats, limit, reason) when is_integer(limit) do
    if stats.bytes <= limit,
      do: :ok,
      else: {:error, %{category: reason_category(reason), reason: reason}}
  end

  defp check_byte_limit(_stats, _limit, _reason), do: :ok

  defp reason_category(:input_bytes), do: :input
  defp reason_category(:output_bytes), do: :output
  defp reason_category(:stdout_bytes), do: :stdout
  defp reason_category(:docs_bytes), do: :docs

  defp check_stdout_bytes(stdout, limits) do
    bytes = Enum.reduce(stdout, 0, fn chunk, acc -> acc + byte_size(chunk) end)

    cond do
      length(stdout) > limits.max_stdout_chunks ->
        {:error, %{category: :stdout, reason: :stdout_chunks}}

      bytes > limits.max_stdout_bytes ->
        {:error, %{category: :stdout, reason: :stdout_bytes}}

      true ->
        :ok
    end
  end

  defp walk_map_key(value, %{public: :json} = terms, limits, depth, stats, true, category) do
    case walk(value, terms, limits, depth, stats, false, category) do
      {:ok, safe, stats} ->
        public_map_key(safe, terms, limits, stats)

      error ->
        error
    end
  end

  defp walk_map_key(value, terms, limits, depth, stats, true, category),
    do: walk(value, terms, limits, depth, stats, true, category)

  defp walk_map_key(value, terms, limits, depth, stats, false, category),
    do: walk(value, terms, limits, depth, stats, false, category)

  defp public_map_key(value, %{public: :json} = terms, limits, stats) do
    encoded =
      cond do
        is_binary(value) ->
          value

        is_boolean(value) or is_nil(value) ->
          to_string(value)

        is_integer(value) or is_float(value) ->
          to_string(value)

        is_atom(value) ->
          pooled_atom_source(value, terms) || Atom.to_string(value)

        true ->
          value
          |> public_key_value(terms)
          |> inspect(limit: 20, printable_limit: 500)
      end

    if byte_size(encoded) <= limits.max_binary_bytes do
      ok(encoded, %{stats | bytes: stats.bytes + byte_size(encoded)})
    else
      {:error, :binary_bytes}
    end
  end

  defp public_key_value(value, terms) when is_atom(value),
    do: pooled_atom_source(value, terms) || Atom.to_string(value)

  defp public_key_value(value, terms) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&public_key_value(&1, terms))
    |> List.to_tuple()
  end

  defp public_key_value(value, terms) when is_list(value),
    do: Enum.map(value, &public_key_value(&1, terms))

  defp public_key_value(value, terms) when is_map(value) do
    Map.new(value, fn {key, item} ->
      {public_key_value(key, terms), public_key_value(item, terms)}
    end)
  end

  defp public_key_value(value, _terms), do: value

  defp walk_list(list, terms, limits, depth, stats, public?, category) do
    Enum.reduce_while(list, {:ok, [], stats}, fn item, {:ok, acc, stats} ->
      case walk(item, terms, limits, depth, %{stats | words: stats.words + 1}, public?, category) do
        {:ok, item, stats} ->
          if stats.words > limits.max_total_words do
            {:halt, {:error, :total_words}}
          else
            {:cont, {:ok, [item | acc], stats}}
          end

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, acc, stats} -> {:ok, Enum.reverse(acc), stats}
      error -> error
    end
  end

  defp public_atom(value, terms, limits, stats, true) do
    case terms.atom_public do
      :atom ->
        ok(value, stats)

      :binary ->
        encoded = Atom.to_string(value)

        if byte_size(encoded) <= limits.max_binary_bytes do
          ok(encoded, %{stats | bytes: stats.bytes + byte_size(encoded)})
        else
          {:error, :binary_bytes}
        end
    end
  end

  defp public_atom(value, _terms, _limits, stats, false), do: ok(value, stats)

  defp public_pooled_atom(value, _terms, _limits, stats, false), do: ok(value, stats)

  defp public_pooled_atom(value, terms, limits, stats, true) do
    source = pooled_atom_source(value, terms)

    cond do
      not is_binary(source) ->
        {:error, {:atom_not_allowed, value}}

      Hyperlang.Manifest.reserved_internal_name?(source) ->
        {:error, {:atom_not_allowed, value}}

      byte_size(source) <= limits.max_binary_bytes ->
        ok(source, %{stats | bytes: stats.bytes + byte_size(source)})

      true ->
        {:error, :binary_bytes}
    end
  end

  defp module_pooled_atom(value, terms, stats) do
    source = pooled_atom_source(value, terms)

    case Map.fetch(Map.get(terms, :module_target_pool, %{}), source) do
      {:ok, translated} ->
        ok(translated, stats)

      :error ->
        target_universe = Map.get(terms, :module_target_universe)
        source_universe = Map.get(terms, :atom_universe)

        cond do
          target_universe != nil and target_universe == source_universe ->
            ok(value, stats)

          true ->
            kernel_pooled_atom(source, terms, stats)
        end
    end
  end

  defp kernel_pooled_atom(source, terms, stats) when is_binary(source) do
    case Hyperlang.KernelAtomPool.canonical_atom(source, Map.get(terms, :kernel_atom_limit, 0)) do
      {:ok, atom} -> ok(atom, stats)
      {:error, reason} -> {:error, reason}
    end
  end

  defp kernel_pooled_atom(_source, _terms, _stats),
    do: {:error, :kernel_atom_pool_exhausted}

  defp module_boundary?(category), do: category in [:module_args, :module_return]

  # A guest's own closure may cross a stdlib call in both directions: a pure
  # data function such as `maps:merge/2` hands back the guest funs it was given.
  # Only local funs of this program's slot module pass; any other fun is
  # rejected as a forbidden term.
  defp safe_stdlib_fun?(value, terms, category)
       when category in [:stdlib_args, :stdlib_return] and is_function(value) do
    info = :erlang.fun_info(value)

    Keyword.get(info, :type) == :local and
      Keyword.get(info, :module) == Map.get(terms, :safe_fun_module)
  end

  defp safe_stdlib_fun?(_value, _terms, _category), do: false

  defp opaque_box?(%Opaque{token: token}, %{boundary_token: token}) when token != nil, do: true
  defp opaque_box?(_value, _terms), do: false

  defp opaque_input_category?(:input, %{opaque_state: %{return_state: elem}})
       when is_integer(elem) and elem >= 0,
       do: true

  defp opaque_input_category?(_category, _terms), do: false

  defp pooled_atom?(value, terms), do: is_binary(pooled_atom_source(value, terms))

  defp pooled_atom_source(value, terms) when is_atom(value), do: atom_source(value, terms)

  defp pooled_atom_source(_value, _terms), do: nil

  defp pooled_atom_boundary?(category),
    do:
      category in [
        :output,
        :import_args,
        :filesystem_args,
        :filesystem_return,
        :loader_args,
        :loader_return,
        :module_args,
        :module_return,
        :stdlib_args,
        :stdlib_return,
        :table,
        :docs,
        :stdout,
        :error
      ]

  defp filesystem_boundary?(category), do: category in [:filesystem_args, :filesystem_return]

  defp public_binary(value, terms, limits, stats, true) do
    case terms.binary_public do
      :binary ->
        ok(value, %{stats | bytes: stats.bytes + byte_size(value)})

      :base64 ->
        encoded = Base.encode64(value)

        if byte_size(encoded) <= limits.max_binary_bytes do
          ok(%{"$binary" => encoded}, %{stats | bytes: stats.bytes + byte_size(encoded)})
        else
          {:error, :binary_bytes}
        end
    end
  end

  defp public_binary(value, _terms, _limits, stats, false),
    do: ok(value, %{stats | bytes: stats.bytes + byte_size(value)})

  defp public_tuple(list, terms, stats, true) do
    case terms.tuple_public do
      :tuple -> ok(List.to_tuple(list), stats)
      :list -> ok(list, stats)
    end
  end

  defp public_tuple(list, _terms, stats, false), do: ok(List.to_tuple(list), stats)

  defp contains_forbidden?(term) do
    cond do
      is_pid(term) or is_port(term) or is_reference(term) ->
        true

      is_function(term) ->
        false

      is_tuple(term) ->
        term |> Tuple.to_list() |> Enum.any?(&contains_forbidden?/1)

      is_list(term) ->
        proper_list?(term) and Enum.any?(term, &contains_forbidden?/1)

      is_map(term) ->
        Enum.any?(term, fn
          {k, v} -> contains_forbidden?(k) or contains_forbidden?(v)
          other -> contains_forbidden?(other)
        end)

      true ->
        false
    end
  end

  defp proper_list?([]), do: true
  defp proper_list?([_ | rest]), do: proper_list?(rest)
  defp proper_list?(_), do: false

  defp ok(value, stats), do: {:ok, value, %{stats | words: stats.words + 1}}

  # Opaque opaque round-trip: return the already-validated inner term WITHOUT
  # re-walking it. Counted as a single opaque node — the State is trusted,
  # host-held data that already passed the word/byte caps when first produced,
  # so it is not re-metered here (the caps guard guest-produced bloat, which a
  # held box is not).
  defp ok_passthrough(term, stats), do: {:ok, term, %{stats | words: stats.words + 1}}

  defp integer_bits(0), do: 1

  defp integer_bits(value) when is_integer(value) do
    bytes = value |> abs() |> :binary.encode_unsigned()
    <<first, _rest::binary>> = bytes
    byte_size(bytes) * 8 - leading_zero_bits(first)
  end

  defp leading_zero_bits(byte) when byte >= 128, do: 0
  defp leading_zero_bits(byte) when byte >= 64, do: 1
  defp leading_zero_bits(byte) when byte >= 32, do: 2
  defp leading_zero_bits(byte) when byte >= 16, do: 3
  defp leading_zero_bits(byte) when byte >= 8, do: 4
  defp leading_zero_bits(byte) when byte >= 4, do: 5
  defp leading_zero_bits(byte) when byte >= 2, do: 6
  defp leading_zero_bits(_byte), do: 7

  defp error_context(%{limits: limits, terms: terms} = ctx) do
    %{
      token: Map.get(ctx, :token, :hyperlang_error),
      limits: error_limits(limits),
      terms:
        terms
        |> error_terms()
        |> Map.put(:atom_pool, Map.get(ctx, :atom_pool, error_atom_pool(terms)))
    }
  end

  defp error_context(_ctx) do
    %{token: :hyperlang_error, limits: @error_limits, terms: @error_terms}
  end

  defp error_limits(limits) when is_map(limits) do
    Map.merge(@error_limits, limits, fn _key, minimum, configured ->
      if is_integer(configured), do: max(minimum, configured), else: minimum
    end)
  end

  defp error_limits(_), do: @error_limits

  defp error_terms(terms) when is_map(terms),
    do: Map.put(@error_terms, :atom_pool, Map.get(terms, :atom_pool, %{}))

  defp error_terms(_terms), do: @error_terms

  defp error_atom_pool(terms) when is_map(terms), do: Map.get(terms, :atom_pool, %{})
  defp error_atom_pool(_terms), do: %{}

  defp normalize_error_term(%Hyperlang.Error{} = error, terms) do
    error
    |> Hyperlang.Error.normalize()
    |> normalize_error_term(terms)
  end

  defp normalize_error_term(%{} = error, terms) do
    raw_category = error_field(error, :category, "runtime")
    category = Hyperlang.Fault.public_category(raw_category)
    known_category? = Hyperlang.Fault.public_category?(raw_category)
    default_reason = error_field(error, :reason, error_field(error, :message, ""))
    reason = if known_category?, do: default_reason, else: :unknown_fault_category

    %{
      "category" => normalize_error_atom(category, terms),
      "reason" => normalize_error_reason(reason, terms)
    }
    |> maybe_put("class", error_field(error, :class, nil), &normalize_error_atom(&1, terms))
    |> maybe_put(
      "exception",
      error_field(error, :exception, nil),
      &normalize_error_atom(&1, terms)
    )
    |> maybe_put("message", error_field(error, :message, nil), &normalize_error_value(&1, terms))
    |> maybe_put("details", error_field(error, :details, nil), &normalize_error_value(&1, terms))
    |> maybe_put("span", error_field(error, :span, nil), &normalize_error_value(&1, terms))
    |> maybe_put("stack", error_field(error, :stack, nil), &normalize_error_stack(&1, terms))
  end

  defp normalize_error_term(error, terms) do
    %{"category" => "runtime", "reason" => normalize_error_reason(error, terms)}
  end

  defp error_field(map, key, default) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp maybe_put(map, _key, nil, _fun), do: map
  defp maybe_put(map, key, value, fun), do: Map.put(map, key, fun.(value))

  defp normalize_error_stack(stack, terms) when is_list(stack) do
    stack
    |> Enum.take(8)
    |> Enum.map(fn
      {module, function, arity} ->
        %{
          "module" => normalize_error_atom(module, terms),
          "function" => normalize_error_atom(function, terms),
          "arity" => normalize_error_value(arity, terms)
        }

      {module, function, arity, _info} ->
        %{
          "module" => normalize_error_atom(module, terms),
          "function" => normalize_error_atom(function, terms),
          "arity" => normalize_error_value(arity, terms)
        }

      other ->
        normalize_error_value(other, terms)
    end)
  end

  defp normalize_error_stack(stack, terms), do: normalize_error_value(stack, terms)

  defp normalize_error_reason(reason, terms)
       when is_atom(reason) or is_binary(reason) or is_number(reason),
       do: normalize_error_value(reason, terms)

  defp normalize_error_reason(reason, terms),
    do: reason |> normalize_error_value(terms) |> inspect(limit: 20, printable_limit: 500)

  defp normalize_error_value({:atom_not_allowed, _value}, _terms),
    do: ["atom_not_allowed", "redacted"]

  defp normalize_error_value(value, terms) when is_atom(value),
    do: public_error_atom_name(value, terms)

  defp normalize_error_value(value, _terms) when is_binary(value), do: value

  defp normalize_error_value(value, _terms)
       when is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp normalize_error_value(value, terms) when is_map(value) do
    Map.new(value, fn {key, item} ->
      {normalize_error_key(key, terms), normalize_error_value(item, terms)}
    end)
  end

  defp normalize_error_value(value, terms) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&normalize_error_value(&1, terms))
  end

  defp normalize_error_value(value, terms) when is_list(value) do
    if proper_list?(value),
      do: Enum.map(value, &normalize_error_value(&1, terms)),
      else: "improper_error_list"
  end

  defp normalize_error_value(value, _terms)
       when is_pid(value) or is_port(value) or is_reference(value) or is_function(value),
       do: "forbidden_term"

  defp normalize_error_value(value, terms),
    do: value |> public_key_value(terms) |> inspect(limit: 20, printable_limit: 500)

  defp normalize_error_key(key, terms) when is_atom(key),
    do: public_error_atom_name(key, terms)

  defp normalize_error_key(key, _terms) when is_binary(key), do: key

  defp normalize_error_key(key, terms),
    do: key |> public_key_value(terms) |> inspect(limit: 10, printable_limit: 200)

  defp normalize_error_atom(value, terms) when is_atom(value),
    do: public_error_atom_name(value, terms)

  defp normalize_error_atom(value, _terms) when is_binary(value), do: value

  defp normalize_error_atom(value, terms),
    do: value |> public_key_value(terms) |> inspect(limit: 10, printable_limit: 200)

  defp public_error_atom_name(value, terms) when is_atom(value) do
    case pooled_atom_source(value, terms) do
      source when is_binary(source) ->
        if Hyperlang.Manifest.reserved_internal_name?(source), do: "redacted", else: source

      nil ->
        name = Atom.to_string(value)
        if Hyperlang.Manifest.reserved_internal_name?(name), do: "redacted", else: name
    end
  end
end
