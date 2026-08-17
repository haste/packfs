defmodule Packfs.Format.WorkspaceAdder do
  @moduledoc "Copies and registers new payloads in extraction workspaces."

  alias Packfs.Format.Error
  alias Packfs.Format.Manifest
  alias Packfs.Format.Manifest.Addition
  alias Packfs.Format.Path, as: VirtualPath
  alias Packfs.Format.Workspace
  alias Packfs.Shared.FileOps
  alias Packfs.Shared.PathGuard

  @context "add"

  @spec run(Workspace.t(), Path.t(), String.t(), keyword()) ::
          {:ok, Addition.t()} | {:error, Error.t()}
  def run(%Workspace{} = workspace, source, path, options \\ []) do
    source = Path.expand(source)

    with :ok <- regular_source(source),
         {:ok, path} <- virtual_path(path),
         {:ok, archive_id} <- archive_id(workspace, options[:archive_id]),
         {:ok, addition, destination} <-
           prepare_addition(workspace, path, archive_id, options[:update]),
         :ok <- copy_source(source, destination, options[:force] == true),
         :ok <- write_manifest(workspace.root, add_to_manifest(workspace.manifest, addition)) do
      {:ok, addition}
    end
  end

  defp regular_source(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        :ok

      {:ok, %File.Stat{type: type}} ->
        {:error, error("#{path} is #{type}, not a regular file")}

      {:error, reason} ->
        {:error, error("cannot read #{path}: #{FileOps.format_reason(reason)}")}
    end
  end

  defp virtual_path(path) when is_binary(path) and path != "" do
    normalized = VirtualPath.normalize(path)
    parts = normalized |> String.trim_leading("/") |> Path.split()

    if String.valid?(normalized) and parts != [] and
         Enum.all?(parts, &(&1 not in ["", ".", ".."])) do
      {:ok, normalized}
    else
      {:error, error("invalid virtual path #{inspect(path)}")}
    end
  end

  defp virtual_path(path), do: {:error, error("invalid virtual path #{inspect(path)}")}

  defp archive_id(%{manifest: %{packs: [archive_id]}}, nil), do: {:ok, archive_id}

  defp archive_id(%{manifest: %{packs: packs}}, nil) do
    message = if packs == [], do: "workspace has no archives", else: "--pack is required"
    {:error, error(message)}
  end

  defp archive_id(workspace, archive_id) do
    if archive_id in workspace.manifest.packs do
      {:ok, archive_id}
    else
      {:error, error("archive #{inspect(archive_id)} is not selected by this workspace")}
    end
  end

  defp prepare_addition(workspace, path, archive_id, update) do
    stored_path = stored_path(path, update)
    {crc32, crc16} = hash(path, update)

    addition = %Addition{
      stored_path: stored_path,
      path: path,
      archive_id: archive_id,
      crc32: crc32,
      crc16: crc16,
      update: update_name(update)
    }

    occupied =
      Enum.map(workspace.manifest.files ++ workspace.manifest.additions, & &1.stored_path)

    cond do
      stored_path in occupied ->
        {:error, error("workspace path #{inspect(stored_path)} is already registered")}

      stored_path == "files/__unknown__" or
          String.starts_with?(stored_path, "files/__unknown__/") ->
        {:error, error("files/__unknown__ is reserved for unresolved records")}

      true ->
        case PathGuard.join(workspace.root, stored_path) do
          {:ok, destination} -> {:ok, addition, destination}
          {:error, message} -> {:error, error(message)}
        end
    end
  end

  defp stored_path(path, nil), do: rooted("files", path)
  defp stored_path(path, update), do: rooted(Path.join("updates", update.name), path)

  defp rooted(root, path), do: Path.join(root, String.trim_leading(path, "/"))

  defp hash(path, nil), do: VirtualPath.hash(path)

  defp hash(path, update) do
    VirtualPath.hash(path, update.crc32_init, update.crc16_init)
  end

  defp update_name(nil), do: nil
  defp update_name(update), do: update.name

  defp copy_source(source, destination, _force) when source == destination, do: :ok

  defp copy_source(source, destination, force) do
    with :ok <- available_destination(destination, force),
         :ok <- File.mkdir_p(Path.dirname(destination)),
         :ok <- File.cp(source, destination) do
      :ok
    else
      {:error, reason} -> {:error, error("cannot copy file: #{FileOps.format_reason(reason)}")}
    end
  end

  defp available_destination(path, false) do
    if File.exists?(path), do: {:error, :eexist}, else: :ok
  end

  defp available_destination(_path, true), do: :ok

  defp add_to_manifest(manifest, addition) do
    %{manifest | additions: Enum.sort_by([addition | manifest.additions], & &1.stored_path)}
  end

  defp write_manifest(root, manifest) do
    path = Path.join(root, "packfs-manifest.json")
    FileOps.write_bytes(path, Manifest.encode(manifest), true, @context)
  end

  defp error(message), do: %Error{message: message, context: @context}
end
