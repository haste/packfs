defmodule Packfs.Shared.Md5 do
  @moduledoc "Streaming MD5 helpers for large PackFS files."

  @chunk_size 1_048_576

  @spec file(Path.t()) :: {:ok, binary(), non_neg_integer()} | {:error, File.posix()}
  def file(path) do
    case File.open(path, [:read, :binary, :raw], &io/1) do
      {:ok, {digest, size}} -> {:ok, digest, size}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec io(File.io_device()) :: {binary(), non_neg_integer()}
  def io(stream) do
    read(stream, :crypto.hash_init(:md5), 0)
  end

  ###
  ### Helpers
  ###

  defp read(stream, state, size) do
    case IO.binread(stream, @chunk_size) do
      :eof ->
        {:crypto.hash_final(state), size}

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read", path: "stream"

      binary ->
        read(stream, :crypto.hash_update(state, binary), size + byte_size(binary))
    end
  end
end
