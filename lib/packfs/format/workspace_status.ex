defmodule Packfs.Format.WorkspaceStatus do
  @moduledoc "Describes registered filesystem mutations in an extraction workspace."

  alias Packfs.Format.Workspace
  alias Packfs.Shared.FileOps
  alias Packfs.Shared.Md5
  alias Packfs.Shared.PathGuard

  @enforce_keys [:modified, :deleted, :added, :errors]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          modified: [String.t()],
          deleted: [String.t()],
          added: [String.t()],
          errors: [String.t()]
        }

  @spec run(Workspace.t()) :: {:ok, t()}
  def run(%Workspace{} = workspace) do
    status =
      workspace.manifest.files
      |> Enum.reduce(empty(), &track_existing(&1, &2, workspace.root))
      |> track_additions(workspace.manifest.additions, workspace.root)
      |> sort_fields()

    {:ok, status}
  end

  @spec clean?(t()) :: boolean()
  def clean?(%__MODULE__{} = status) do
    status.modified == [] and status.deleted == [] and status.added == [] and
      status.errors == []
  end

  defp empty do
    %__MODULE__{modified: [], deleted: [], added: [], errors: []}
  end

  defp track_existing(entry, status, root) do
    case digest(root, entry.stored_path) do
      {:ok, digest} when digest == entry.extracted_md5 -> status
      {:ok, _digest} -> %{status | modified: [entry.stored_path | status.modified]}
      :missing -> %{status | deleted: [entry.stored_path | status.deleted]}
      {:error, message} -> %{status | errors: [message | status.errors]}
    end
  end

  defp track_additions(status, additions, root) do
    Enum.reduce(additions, status, fn addition, result ->
      case digest(root, addition.stored_path) do
        {:ok, _digest} -> %{result | added: [addition.stored_path | result.added]}
        :missing -> %{result | deleted: [addition.stored_path | result.deleted]}
        {:error, message} -> %{result | errors: [message | result.errors]}
      end
    end)
  end

  defp digest(root, stored_path) do
    with {:ok, path} <- PathGuard.join(root, stored_path),
         {:ok, digest, _size} <- Md5.file(path) do
      {:ok, digest}
    else
      {:error, :enoent} -> :missing
      {:error, reason} -> {:error, "#{stored_path}: #{format_reason(reason)}"}
    end
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: FileOps.format_reason(reason)

  defp sort_fields(status) do
    %{
      status
      | modified: Enum.sort(status.modified),
        deleted: Enum.sort(status.deleted),
        added: Enum.sort(status.added),
        errors: Enum.sort(status.errors)
    }
  end
end
