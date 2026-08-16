defmodule Packfs.Shared.OutputDirectory do
  @moduledoc "Prepares output directories without overwriting existing contents implicitly."

  @spec prepare(Path.t(), boolean()) :: :ok | {:error, File.posix()}
  def prepare(path, true) do
    File.mkdir_p(path)
  end

  def prepare(path, false) do
    case File.ls(path) do
      {:ok, []} -> :ok
      {:ok, _entries} -> {:error, :enotempty}
      {:error, :enoent} -> File.mkdir_p(path)
      {:error, reason} -> {:error, reason}
    end
  end
end
