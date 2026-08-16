defmodule Packfs.Shared.AtomicFile do
  @moduledoc "Same-directory temporary writes followed by an atomic rename."

  @type writer_result(value) :: {:ok, value} | {:error, term()}

  @spec write(Path.t(), boolean(), (File.io_device() -> writer_result(value))) ::
          writer_result(value)
        when value: term()
  def write(path, overwrite?, writer) do
    with :ok <- ensure_destination(path, overwrite?),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      temporary = temporary_path(path)
      write_temporary(temporary, path, writer)
    end
  end

  @spec write_bytes(Path.t(), iodata(), boolean()) :: :ok | {:error, term()}
  def write_bytes(path, contents, overwrite?) do
    case write(path, overwrite?, &write_contents(&1, contents)) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  ###
  ### Helpers
  ###

  defp ensure_destination(path, false) do
    if File.exists?(path), do: {:error, :eexist}, else: :ok
  end

  defp ensure_destination(_path, true), do: :ok

  defp write_contents(stream, contents) do
    case :file.write(stream, contents) do
      :ok -> {:ok, :ok}
      {:error, reason} -> {:error, reason}
    end
  end

  defp temporary_path(path) do
    suffix = System.unique_integer([:positive, :monotonic])
    path <> ".packfs-#{suffix}.tmp"
  end

  defp write_temporary(temporary, destination, writer) do
    case File.open(temporary, [:write, :binary, :raw, :exclusive], writer) do
      {:ok, {:ok, value}} -> install(temporary, destination, value)
      {:ok, {:error, reason}} -> cleanup(temporary, reason)
      {:error, reason} -> cleanup(temporary, reason)
    end
  end

  defp install(temporary, destination, value) do
    case File.rename(temporary, destination) do
      :ok -> {:ok, value}
      {:error, reason} -> cleanup(temporary, reason)
    end
  end

  defp cleanup(path, reason) do
    File.rm(path)
    {:error, reason}
  end
end
