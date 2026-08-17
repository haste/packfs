defmodule Packfs.Format.WorkspaceVerifier do
  @moduledoc "Structural and payload verification for extraction workspaces."

  alias Packfs.Format.PackInfo
  alias Packfs.Format.Path, as: VirtualPath
  alias Packfs.Format.Validation
  alias Packfs.Format.Workspace
  alias Packfs.Shared.Md5
  alias Packfs.Shared.PathGuard

  @spec verify(Workspace.t(), keyword()) :: Validation.t()
  def verify(%Workspace{} = workspace, options \\ []) do
    validation = structural(workspace)

    validation
    |> verify_files(workspace, options[:files] == true)
    |> Validation.finish()
  end

  @spec structural(Workspace.t(), keyword()) :: Validation.t()
  def structural(%Workspace{} = workspace, options \\ []) do
    expected = expected_records(workspace)

    %Validation{}
    |> validate_pack_ids(workspace)
    |> validate_record_set(workspace, expected)
    |> validate_entries(
      workspace,
      options[:allow_missing] == true,
      options[:files] != false
    )
  end

  ###
  ### Helpers
  ###

  defp expected_records(workspace) do
    selected = MapSet.new(workspace.manifest.packs)

    workspace.pack_info
    |> PackInfo.selected_records(selected)
    |> Enum.map(& &1.index)
    |> MapSet.new()
  end

  defp validate_pack_ids(validation, workspace) do
    invalid = Enum.filter(workspace.manifest.packs, &(&1 >= workspace.pack_info.archive_count))

    if invalid == [] do
      validation
    else
      Validation.error(validation, "manifest contains invalid archive IDs: #{inspect(invalid)}")
    end
  end

  defp validate_record_set(validation, workspace, expected) do
    indexes = Enum.map(workspace.manifest.files, & &1.record)
    actual = MapSet.new(indexes)

    validation
    |> Validation.check(
      length(indexes) == MapSet.size(actual),
      "manifest contains duplicate record indexes"
    )
    |> Validation.check(actual == expected, record_set_message(expected, actual))
  end

  defp record_set_message(expected, actual) do
    missing = expected |> MapSet.difference(actual) |> Enum.sort()
    extra = actual |> MapSet.difference(expected) |> Enum.sort()

    "manifest record set differs from selected archives; missing=#{inspect(missing)}, extra=#{inspect(extra)}"
  end

  defp validate_entries(validation, workspace, allow_missing, validate_files) do
    {result, _stored_paths} =
      Enum.reduce(workspace.manifest.files, {validation, MapSet.new()}, fn entry, accumulator ->
        validate_entry(accumulator, workspace, entry, allow_missing, validate_files)
      end)

    result
  end

  defp validate_entry({validation, stored_paths}, workspace, entry, allow_missing, validate_files) do
    record = Enum.at(workspace.pack_info.records, entry.record)

    updated =
      validation
      |> Validation.check(
        not MapSet.member?(stored_paths, entry.stored_path),
        "duplicate stored path #{inspect(entry.stored_path)}"
      )
      |> validate_record(entry, record)
      |> validate_stored_file(workspace, entry, allow_missing, validate_files)

    {updated, MapSet.put(stored_paths, entry.stored_path)}
  end

  defp validate_record(validation, entry, nil) do
    Validation.error(validation, "manifest record #{entry.record} does not exist")
  end

  defp validate_record(validation, entry, record) do
    validation
    |> Validation.check(
      record.md5 == entry.indexed_md5,
      "manifest record #{entry.record} indexed MD5 differs from packinfo.bin"
    )
    |> validate_name_state(entry)
    |> validate_path(entry, record)
  end

  defp validate_name_state(validation, %{update: nil}) do
    validation
  end

  defp validate_name_state(validation, %{update: update, path: path})
       when is_binary(update) and update != "" and is_binary(path) do
    validation
  end

  defp validate_name_state(validation, entry) do
    Validation.error(
      validation,
      "manifest record #{entry.record} has an invalid path or update"
    )
  end

  defp validate_path(validation, %{path: nil}, _record), do: validation

  defp validate_path(validation, %{update: update}, _record) when not is_nil(update),
    do: validation

  defp validate_path(validation, entry, record) do
    expected = {record.crc32, record.crc16}

    Validation.check(
      validation,
      VirtualPath.hash(entry.path) == expected,
      "manifest record #{entry.record} path does not match its hash"
    )
  end

  defp validate_stored_file(validation, _workspace, _entry, _allow_missing, false), do: validation

  defp validate_stored_file(validation, workspace, entry, allow_missing, true) do
    case PathGuard.join(workspace.root, entry.stored_path) do
      {:ok, path} -> validate_regular_file(validation, entry, path, allow_missing)
      {:error, message} -> Validation.error(validation, "record #{entry.record}: #{message}")
    end
  end

  defp validate_regular_file(validation, entry, path, allow_missing) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        validation

      {:ok, %File.Stat{type: type}} ->
        Validation.error(validation, "record #{entry.record} stored path is #{type}, not a file")

      {:error, :enoent} when allow_missing ->
        validation

      {:error, reason} ->
        Validation.error(
          validation,
          "record #{entry.record} cannot read #{path}: #{:file.format_error(reason)}"
        )
    end
  end

  defp verify_files(validation, _workspace, false), do: validation

  defp verify_files(validation, workspace, true) do
    Enum.reduce(workspace.manifest.files, validation, fn entry, result ->
      verify_file(result, workspace, entry)
    end)
  end

  defp verify_file(validation, workspace, entry) do
    case PathGuard.join(workspace.root, entry.stored_path) do
      {:ok, path} -> verify_file_digest(validation, entry, path)
      {:error, message} -> Validation.error(validation, "record #{entry.record}: #{message}")
    end
  end

  defp verify_file_digest(validation, entry, path) do
    case Md5.file(path) do
      {:ok, digest, _size} when digest == entry.extracted_md5 ->
        validation

      {:ok, digest, _size} ->
        Validation.error(
          validation,
          "record #{entry.record}: extracted MD5 changed from #{hex(entry.extracted_md5)} " <>
            "to #{hex(digest)}"
        )

      {:error, reason} ->
        Validation.error(validation, "record #{entry.record}: #{:file.format_error(reason)}")
    end
  end

  defp hex(digest), do: Base.encode16(digest, case: :lower)
end
