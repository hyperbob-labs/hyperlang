defmodule Hyperlang.Scope.Runtime do
  @moduledoc false
  @compile {:inline, [next: 4, wake: 2]}
  import Bitwise
  @slots :hyperlang_runtime_slots
  @active 1
  @paused 2
  @closed 4
  @waiting 8
  @dirty 16
  @flags 31

  # Slot insertion atomically records both capacity and its owner. There is no
  # separate count to repair if a process dies before committing its local state.
  def init do
    :ets.new(@slots, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])
  end

  def new(limit) do
    gate = :atomics.new(2, signed: false)
    :atomics.put(gate, 2, limit)
    gate
  end

  def limit(gate), do: :atomics.get(gate, 2)

  def slot(limit) do
    step = layout_step(limit, 32)
    {:atomics.new(1, signed: false), step - 32, step}
  end

  defp layout_step(0, step), do: step
  defp layout_step(limit, step), do: layout_step(limit >>> 1, step <<< 1)
  def control, do: :atomics.new(1, signed: false)
  def flags({cell, _, _}), do: band(:atomics.get(cell, 1), @flags)
  def active?(cell), do: band(flags(cell), @active) != 0
  def waiting?(cell), do: band(flags(cell), @waiting) != 0

  def counts(_gate) do
    :ets.foldl(
      fn {_, _, _, background?}, {total, background} ->
        {total + 1, background + if(background?, do: 1, else: 0)}
      end,
      {0, 0},
      @slots
    )
  end

  def close(cell), do: update(cell, &bor(&1, @closed))
  def pause(cell), do: update(cell, &bor(&1, @paused))
  def unpause(cell), do: update(cell, &band(&1, bnot(@paused)))
  def end_wait(cell), do: update(cell, &band(&1, bnot(@waiting)))
  def wait(cell), do: update(cell, &bor(&1, @waiting))

  def block({token, gate, cell, _, background?, server, _}) do
    release(gate, cell, token, background?, server, @waiting)
  end

  def release(gate, {cell, mask, _} = state, token, background?, server, extra) do
    old = :atomics.get(cell, 1)
    index = band(old, mask) >>> 5

    if band(old, @dirty) == 0 do
      # A clean state's entire word is its reservation identity. A pause can
      # invalidate this deletion but cannot make it delete a newer grant.
      :ets.delete_object(@slots, {index, token, old, background?})
    else
      :ets.match_delete(@slots, {:_, token, :_, :_})
    end

    new = next(state, old, bor(band(old, bnot(@active)), extra), index)

    case :atomics.compare_exchange(cell, 1, old, new) do
      :ok -> wake(gate, server)
      _ -> release(gate, state, token, background?, server, extra)
    end
  end

  # The owner is physically suspended. Retain its lifetime record: its stopped
  # instruction may still insert a slot after resumption, but the versioned
  # local commit will fail. DOWN recovery can reclaim that late insertion too.
  def suspend(gate, cell, token, server) do
    update(cell, &band(&1, bnot(@active)))
    :ets.match_delete(@slots, {:_, token, :_, :_})
    wake(gate, server)
  end

  def reclaim(gate, cell, token, server) do
    :ets.match_delete(@slots, {:_, token, :_, :_})
    update(cell, &band(&1, bnot(@active)))
    wake(gate, server)
  end

  # The registered name tells whether the token's Scope server is still the
  # live one. `Process.alive?/1` would wait for the server to handle a signal
  # whenever it has unprocessed messages, which puts a hidden server round trip
  # on every local resume while Scope is busy.
  def valid?({_, _, cell, control, _, server, _}) do
    flags(cell) == @active and :atomics.get(control, 1) == 0 and current_server?(server)
  end

  def try_resume({token, gate, {cell, _, _} = state, control, background?, server, limit}) do
    old = :atomics.get(cell, 1)

    cond do
      not current_server?(server) ->
        :slow

      band(old, @active) != 0 ->
        :ok

      band(old, @paused + @closed) != 0 ->
        :slow

      :atomics.get(gate, 1) != 0 ->
        :slow

      true ->
        case reserve(state, token, background?, limit, old) do
          {:ok, row, new} ->
            if :atomics.get(gate, 1) == 0 and :atomics.get(control, 1) == 0 and
                 :atomics.compare_exchange(cell, 1, old, new) == :ok do
              :ok
            else
              :ets.delete_object(@slots, row)
              wake(gate, server)
              :slow
            end

          :full ->
            :slow
        end
    end
  end

  def grant(gate, {cell, _, _} = state, token, background?) do
    old = :atomics.get(cell, 1)

    case reserve(state, token, background?, limit(gate), old) do
      {:ok, _row, new} ->
        :atomics.put(cell, 1, new)
        :ok

      :full ->
        :full
    end
  end

  defp reserve({_, mask, _} = state, token, background?, limit, old) do
    capacity = limit - if(background?, do: 1, else: 0)
    hint = band(old, mask) >>> 5

    start =
      if hint >= 1 and hint <= capacity,
        do: hint,
        else: if(background?, do: :erlang.phash2(token, capacity) + 1, else: capacity)

    flags = bor(band(old, @closed), @active)
    claim(state, token, background?, old, flags, start, capacity, capacity)
  end

  defp claim(_state, _token, _background?, _old, _flags, _index, _capacity, 0), do: :full

  defp claim(state, token, background?, old, flags, index, capacity, left) do
    new = next(state, old, flags, index)
    row = {index, token, new, background?}

    if :ets.insert_new(@slots, row) do
      {:ok, row, new}
    else
      claim(
        state,
        token,
        background?,
        old,
        flags,
        if(index == capacity, do: 1, else: index + 1),
        capacity,
        left - 1
      )
    end
  end

  defp current_server?(server), do: Process.whereis(Hyperlang.Scope) == server

  defp wake(gate, server) do
    if :atomics.get(gate, 1) != 0, do: send(server, :runtime_ready)
    :ok
  end

  defp next({_, _, step}, old, flags, index) do
    band(old, bnot(step - 1)) + step + (index <<< 5) + band(flags, @flags)
  end

  # Administrative transitions mark the state dirty: the existing slot still
  # has its original identity. Only this cold path needs a token-wide deletion.
  defp update({cell, mask, _} = state, fun) do
    old = :atomics.get(cell, 1)
    new = next(state, old, bor(fun.(old), @dirty), band(old, mask) >>> 5)

    case :atomics.compare_exchange(cell, 1, old, new) do
      :ok -> :ok
      _ -> update(state, fun)
    end
  end
end
