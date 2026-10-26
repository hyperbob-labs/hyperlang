defmodule Hyperlang.Filesystem.WildcardBridge do
  # The single `:filelib` callback module. `:filelib.wildcard/2,3`,
  # `:filelib.is_file/2` and `:filelib.is_dir/2` run with OTP-exact semantics
  # against whichever filesystem backend installed the callbacks for the
  # dynamic extent of `with_callbacks/3`.
  #
  # The backend supplies three callbacks — `:stat`, `:lstat` and `:list_dir` —
  # and this module owns everything above them: the process-local context, path
  # normalization, the wildcard depth and enumeration limits, and the OTP
  # `#file_info{}` projection. `read_file_info/1` follows the final symlink and
  # `read_link_info/1` does not, so a backend that distinguishes the two must
  # supply two different callbacks; a backend whose namespace has no symlinks
  # supplies the same one twice, at its own call site, where that decision is
  # visible.
  @moduledoc false

  alias Hyperlang.Filesystem.OtpFacade

  @context_key :"$hyperlang_wildcard_bridge"

  def with_callbacks(callbacks, fun) when is_map(callbacks) and is_function(fun, 0),
    do: with_callbacks(callbacks, nil, fun)

  def with_callbacks(callbacks, limits, fun) when is_map(callbacks) and is_function(fun, 0) do
    previous = Process.get(@context_key, :undefined)
    previous_enumerated = Process.get({@context_key, :enumerated}, :undefined)
    Process.put(@context_key, %{callbacks: callbacks, limits: limits})
    Process.put({@context_key, :enumerated}, 0)

    try do
      {:ok, fun.()}
    after
      restore_context(previous)
      restore_enumerated(previous_enumerated)
    end
  catch
    {:hyperlang_wildcard_error, _reason} = error ->
      throw(error)
  end

  def read_file_info(path), do: info(path, :stat)
  def read_link_info(path), do: info(path, :lstat)

  def list_dir(path) do
    with {:ok, %{callbacks: callbacks, limits: limits}} <- context(),
         :ok <- check_wildcard_depth(path, limits),
         {:ok, path} <- normalize_callback_path(path),
         {:ok, names} <- callbacks.list_dir.(path),
         :ok <- bump_wildcard_enumeration(names, limits) do
      {:ok, Enum.map(names, &String.to_charlist/1)}
    else
      {:error, :enoent} -> {:error, :enoent}
      {:error, :enotdir} -> {:error, :enotdir}
      {:error, reason} -> throw({:hyperlang_wildcard_error, reason})
    end
  end

  defp info(path, callback) do
    with {:ok, %{callbacks: callbacks}} <- context(),
         {:ok, path} <- normalize_callback_path(path),
         {:ok, stat} <- Map.fetch!(callbacks, callback).(path) do
      {:ok, OtpFacade.file_info_tuple(stat)}
    end
  end

  defp context do
    case Process.get(@context_key) do
      %{callbacks: %{stat: _stat, lstat: _lstat, list_dir: _list_dir}} = context -> {:ok, context}
      _other -> {:error, :filesystem_context_missing}
    end
  end

  defp check_wildcard_depth(_path, nil), do: :ok

  defp check_wildcard_depth(path, limits) do
    depth =
      path
      |> path_to_binary()
      |> String.split("/", trim: true)
      |> length()

    if depth <= limits.max_wildcard_depth do
      :ok
    else
      throw({:hyperlang_wildcard_error, :eoverflow})
    end
  end

  defp bump_wildcard_enumeration(_names, nil), do: :ok

  defp bump_wildcard_enumeration(names, limits) do
    current = Process.get({@context_key, :enumerated}, 0)
    next = current + length(names)

    if next <= limits.max_wildcard_matches do
      Process.put({@context_key, :enumerated}, next)
      :ok
    else
      throw({:hyperlang_wildcard_error, :eoverflow})
    end
  end

  defp path_to_binary(path) when is_binary(path), do: path

  defp path_to_binary(path) when is_list(path) do
    case :unicode.characters_to_binary(path) do
      binary when is_binary(binary) -> binary
      {:error, _encoded, _rest} -> raise ArgumentError
      {:incomplete, _encoded, _rest} -> raise ArgumentError
    end
  end

  defp path_to_binary(path), do: inspect(path)

  defp normalize_callback_path(path) do
    path = path_to_binary(path)
    path = String.replace(path, ~r{/+}, "/")

    cond do
      path == "/" -> {:ok, path}
      String.ends_with?(path, "/") -> {:ok, String.trim_trailing(path, "/")}
      String.starts_with?(path, "/") -> {:ok, Path.expand(path)}
      true -> {:ok, path}
    end
  rescue
    ArgumentError -> {:error, :badarg}
  end

  defp restore_context(:undefined), do: Process.delete(@context_key)
  defp restore_context(previous), do: Process.put(@context_key, previous)

  defp restore_enumerated(:undefined), do: Process.delete({@context_key, :enumerated})
  defp restore_enumerated(previous), do: Process.put({@context_key, :enumerated}, previous)
end
