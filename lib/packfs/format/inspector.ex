defmodule Packfs.Format.Inspector do
  @moduledoc "Builds structured inspection reports without presentation concerns."

  alias Packfs.Format.DataSet
  alias Packfs.Format.Inspection
  alias Packfs.Format.Manifest
  alias Packfs.Format.Manifest.Entry
  alias Packfs.Format.PackInfo
  alias Packfs.Format.ResolvedName
  alias Packfs.Format.Target
  alias Packfs.Format.Validation
  alias Packfs.Format.Verifier
  alias Packfs.Format.Workspace
  alias Packfs.Format.WorkspaceVerifier

  @spec inspect(Target.t(), keyword()) :: Inspection.t()
  def inspect(%Target{kind: :packed, data: data_set}, options) do
    selected = Keyword.fetch!(options, :selected)
    names = options[:names] || %{}
    validation = Verifier.structural(data_set, selected)
    {cipher_mode, cipher_warnings} = detect_cipher(data_set, options[:cipher] || :auto)

    selected_records = PackInfo.selected_records(data_set.pack_info, selected)

    summary = %{
      magic: data_set.pack_info.magic,
      archive_count: data_set.pack_info.archive_count,
      selected_archives: MapSet.size(selected),
      file_count: length(selected_records),
      total_file_count: data_set.pack_info.file_count,
      integrity_record_count: integrity_count(data_set),
      resolved: Enum.count(selected_records, &Map.has_key?(names, hash_pair(&1))),
      cipher_mode: cipher_mode
    }

    %Inspection{
      kind: :packed,
      root: data_set.root,
      summary: summary,
      records: packed_records(selected_records, names, options[:records] == true),
      validation:
        validation
        |> add_warnings(options[:warnings] || [])
        |> add_warnings(cipher_warnings)
        |> Validation.finish()
    }
  end

  def inspect(%Target{kind: :workspace, data: workspace}, options) do
    resolved = Enum.count(workspace.manifest.files, &(not is_nil(&1.logical_path)))

    summary = %{
      manifest_format: Manifest.format(),
      archive_count: length(workspace.manifest.packs),
      file_count: length(workspace.manifest.files),
      resolved: resolved,
      unresolved: length(workspace.manifest.files) - resolved,
      cipher_mode: workspace.manifest.cipher_mode
    }

    %Inspection{
      kind: :workspace,
      root: workspace.root,
      summary: summary,
      records: workspace_records(workspace, options[:records] == true),
      validation: workspace |> WorkspaceVerifier.structural() |> Validation.finish()
    }
  end

  ###
  ### Helpers
  ###

  defp detect_cipher(data_set, requested) do
    case DataSet.cipher_mode(data_set, requested) do
      {:ok, mode} -> {mode, []}
      {:error, reason} -> {:unknown, [Exception.message(reason)]}
    end
  end

  defp integrity_count(%DataSet{finfolist: nil}), do: 0
  defp integrity_count(%DataSet{finfolist: finfolist}), do: length(finfolist.records)

  defp packed_records(_records, _names, false), do: []

  defp packed_records(records, names, true) do
    Enum.map(records, fn record ->
      name = resolved_name(Map.get(names, hash_pair(record)))

      %{
        index: record.index,
        crc32: record.crc32,
        crc16: record.crc16,
        archive_id: record.archive_id,
        offset: record.offset,
        size: record.size,
        md5: record.md5,
        virtual_path: runtime_path(name),
        logical_path: logical_path(name),
        update: update(name)
      }
    end)
  end

  defp workspace_records(_workspace, false), do: []

  defp workspace_records(workspace, true) do
    Enum.map(workspace.manifest.files, &workspace_record(&1, workspace))
  end

  defp workspace_record(%Entry{} = entry, %Workspace{} = workspace) do
    record = Enum.at(workspace.pack_info.records, entry.record)

    %{
      index: entry.record,
      crc32: record.crc32,
      crc16: record.crc16,
      archive_id: record.archive_id,
      offset: record.offset,
      size: record.size,
      md5: record.md5,
      virtual_path: entry.virtual_path,
      logical_path: entry.logical_path,
      update: entry.update,
      stored_path: entry.stored_path,
      extracted_md5: entry.extracted_md5
    }
  end

  defp hash_pair(record), do: {record.crc32, record.crc16}

  defp resolved_name(nil), do: nil
  defp resolved_name(path) when is_binary(path), do: %ResolvedName{path: path, update: nil}
  defp resolved_name(%ResolvedName{} = name), do: name

  defp runtime_path(%ResolvedName{path: path, update: nil}), do: path
  defp runtime_path(_name), do: nil

  defp logical_path(%ResolvedName{path: path}), do: path
  defp logical_path(nil), do: nil

  defp update(%ResolvedName{update: update}), do: update
  defp update(nil), do: nil

  defp add_warnings(validation, warnings) do
    Enum.reduce(warnings, validation, &Validation.warning(&2, &1))
  end
end
