defmodule Packfs.Shared.FileOps do
  @moduledoc "Common filesystem operations with PackFS error handling."

  alias Packfs.Format.Error
  alias Packfs.Shared.AtomicFile
  alias Packfs.Shared.OutputDirectory

  @spec read(Path.t(), String.t()) :: {:ok, binary()} | {:error, Error.t()}
  def read(path, context) do
    case File.read(path) do
      {:ok, binary} ->
        {:ok, binary}

      {:error, reason} ->
        {:error, error(context, "cannot read #{path}: #{format_reason(reason)}")}
    end
  end

  @spec read_optional(Path.t(), (binary() -> {:ok, value} | {:error, Error.t()}), String.t()) ::
          {:ok, value | nil} | {:error, Error.t()}
        when value: term()
  def read_optional(path, decoder, context) do
    case File.read(path) do
      {:ok, binary} ->
        decoder.(binary)

      {:error, :enoent} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, error(context, "cannot read #{path}: #{format_reason(reason)}")}
    end
  end

  @spec prepare_output(Path.t(), boolean(), String.t()) :: :ok | {:error, Error.t()}
  def prepare_output(path, force, context) do
    case OutputDirectory.prepare(path, force) do
      :ok ->
        :ok

      {:error, :enotempty} ->
        {:error, error(context, "output directory is not empty: #{path}")}

      {:error, reason} ->
        {:error, error(context, "cannot prepare #{path}: #{format_reason(reason)}")}
    end
  end

  @spec write_bytes(Path.t(), iodata(), boolean(), String.t()) :: :ok | {:error, Error.t()}
  def write_bytes(path, contents, force, context) do
    case AtomicFile.write_bytes(path, contents, force) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, error(context, "cannot write #{path}: #{format_reason(reason)}")}
    end
  end

  @spec format_reason(term()) :: String.t()
  def format_reason(%Error{} = reason), do: Exception.message(reason)

  def format_reason(reason) when is_atom(reason),
    do: reason |> :file.format_error() |> to_string()

  def format_reason(reason), do: inspect(reason)

  defp error(context, message), do: %Error{message: message, context: context}
end
