defmodule Hyperlang.Filesystem.OtpFacade do
  @moduledoc false

  import Bitwise

  @epoch {{1970, 1, 1}, {0, 0, 0}}

  @spec otp_reply({:ok, term()} | {:error, term()}) :: {:ok, term()} | {:error, term()}
  def otp_reply({:ok, value}), do: {:ok, {:ok, value}}
  def otp_reply({:error, reason}) when is_atom(reason), do: {:ok, {:error, reason}}
  def otp_reply({:error, reason}), do: {:error, reason}

  @spec list_dir_reply({:ok, [binary()]} | {:error, term()}) :: {:ok, term()} | {:error, term()}
  def list_dir_reply({:ok, names}), do: {:ok, {:ok, Enum.map(names, &String.to_charlist/1)}}
  def list_dir_reply({:error, reason}) when is_atom(reason), do: {:ok, {:error, reason}}
  def list_dir_reply({:error, reason}), do: {:error, reason}

  @spec status_reply({:ok, :ok} | {:error, term()}) :: {:ok, term()} | {:error, term()}
  def status_reply({:ok, :ok}), do: {:ok, :ok}
  def status_reply({:error, reason}) when is_atom(reason), do: {:ok, {:error, reason}}
  def status_reply({:error, reason}), do: {:error, reason}

  @spec open_reply({:ok, term()} | {:error, term()}) :: {:ok, term()} | {:error, term()}
  def open_reply(reply), do: otp_reply(reply)

  @spec otp_or_atom_reply({:ok, term()} | {:error, term()}) :: {:ok, term()} | {:error, term()}
  def otp_or_atom_reply({:ok, :eof}), do: {:ok, :eof}
  def otp_or_atom_reply(reply), do: otp_reply(reply)

  @spec file_info_reply({:ok, map()} | {:error, term()}) :: {:ok, term()} | {:error, term()}
  def file_info_reply({:ok, stat}), do: {:ok, {:ok, file_info_tuple(stat)}}
  def file_info_reply({:error, reason}) when is_atom(reason), do: {:ok, {:error, reason}}
  def file_info_reply({:error, reason}), do: {:error, reason}

  @spec file_info_tuple(%{type: atom(), size: non_neg_integer(), mode: term()}) :: tuple()
  def file_info_tuple(%{type: type, size: size, mode: mode}) do
    otp_type = otp_type(type)
    otp_mode = otp_file_mode(otp_type, mode)

    {:file_info, size, otp_type, access_for_mode(mode), @epoch, @epoch, @epoch, otp_mode, 1, 0, 0,
     0, 0, 0}
  end

  @spec write_operation(term()) :: {:ok, :write | :append | :exclusive} | {:error, :badarg}
  def write_operation(modes) when is_list(modes) do
    normalized = Enum.map(modes, &normalize_write_mode/1)

    cond do
      :badarg in normalized -> {:error, :badarg}
      :exclusive in normalized -> {:ok, :exclusive}
      :append in normalized -> {:ok, :append}
      true -> {:ok, :write}
    end
  end

  def write_operation(_modes), do: {:error, :badarg}

  @spec open_operation(term()) ::
          {:ok, %{read: boolean(), write: boolean(), append: boolean(), exclusive: boolean()}}
          | {:error, :badarg}
  def open_operation(modes) when is_list(modes) do
    normalized = Enum.map(modes, &normalize_open_mode/1)

    cond do
      :badarg in normalized ->
        {:error, :badarg}

      :read not in normalized and :write not in normalized and :append not in normalized ->
        {:error, :badarg}

      :append in normalized and :exclusive in normalized ->
        {:ok, %{read: :read in normalized, write: true, append: true, exclusive: true}}

      :append in normalized ->
        {:ok, %{read: :read in normalized, write: true, append: true, exclusive: false}}

      :write in normalized ->
        {:ok,
         %{
           read: :read in normalized,
           write: true,
           append: false,
           exclusive: :exclusive in normalized
         }}

      :read in normalized ->
        {:ok, %{read: true, write: false, append: false, exclusive: false}}
    end
  end

  def open_operation(_modes), do: {:error, :badarg}

  @spec otp_type(atom()) :: :regular | :directory | :symlink
  def otp_type(type) when type in [:file, :regular], do: :regular
  def otp_type(type) when type in [:dir, :directory], do: :directory
  def otp_type(:symlink), do: :symlink
  def otp_type(_type), do: :regular

  @spec access_for_mode(term()) :: :read_write | :read | :write | :none
  def access_for_mode(mode) when is_integer(mode) do
    read? = band(mode, 0o444) != 0
    write? = band(mode, 0o222) != 0

    case {read?, write?} do
      {true, true} -> :read_write
      {true, false} -> :read
      {false, true} -> :write
      {false, false} -> :none
    end
  end

  def access_for_mode(_mode), do: :read_write

  @spec otp_file_mode(atom(), term()) :: non_neg_integer()
  def otp_file_mode(:regular, mode), do: bor(0o100000, safe_permission_mode(mode))
  def otp_file_mode(:directory, mode), do: bor(0o040000, safe_permission_mode(mode))
  def otp_file_mode(:symlink, mode), do: bor(0o120000, safe_permission_mode(mode))
  def otp_file_mode(_type, mode), do: safe_permission_mode(mode)

  # The single permission-mode mask. A mode that is not an integer is a
  # backend defect, so it reports no permissions rather than inventing them.
  @spec safe_permission_mode(term()) :: non_neg_integer()
  def safe_permission_mode(mode) when is_integer(mode), do: band(mode, 0o777)
  def safe_permission_mode(_mode), do: 0

  defp normalize_write_mode(mode)
       when mode in [:write, :raw, :binary, :delayed_write, :read, :sync, :read_ahead],
       do: :write

  defp normalize_write_mode({:delayed_write, size, delay})
       when is_integer(size) and size >= 0 and is_integer(delay) and delay >= 0,
       do: :write

  defp normalize_write_mode({:read_ahead, size}) when is_integer(size) and size >= 0,
    do: :write

  defp normalize_write_mode(:append), do: :append
  defp normalize_write_mode(:exclusive), do: :exclusive
  defp normalize_write_mode(_mode), do: :badarg

  defp normalize_open_mode(mode)
       when mode in [:read, :write, :append, :raw, :binary, :exclusive],
       do: mode

  defp normalize_open_mode(_mode), do: :badarg
end
