defmodule Packfs.Format.Repacker do
  @moduledoc "Rebuilds archive overlays from extraction workspaces."

  alias Packfs.Format.Archive
  alias Packfs.Format.Error
  alias Packfs.Format.FileRecord
  alias Packfs.Format.Finfolist
  alias Packfs.Format.IntegrityRecord
  alias Packfs.Format.Manifest.Addition
  alias Packfs.Format.PackInfo
  alias Packfs.Format.Repacker.ArchiveState
  alias Packfs.Format.Repacker.State
  alias Packfs.Format.RepackResult
  alias Packfs.Format.Validation
  alias Packfs.Format.Workspace
  alias Packfs.Format.WorkspaceVerifier
  alias Packfs.Shared.AtomicFile
  alias Packfs.Shared.FileOps
  alias Packfs.Shared.PathGuard

  @max_u16 0xFFFF
  @max_u32 0xFFFFFFFF
  @context "repack"

  @spec run(Workspace.t(), Path.t(), keyword()) ::
          {:ok, RepackResult.t()} | {:error, Error.t()}
  def run(%Workspace{} = workspace, output, options \\ []) do
    expanded_output = Path.expand(output)

    with :ok <- ensure_valid_workspace(workspace),
         {:ok, plan} <- plan(workspace),
         :ok <- FileOps.prepare_output(expanded_output, options[:force] == true, @context),
         {:ok, state} <- rebuild_archives(workspace, expanded_output, options, plan),
         :ok <- write_indexes(state) do
      {:ok, result(state)}
    end
  end

  ###
  ### Helpers
  ###

  defp ensure_valid_workspace(workspace) do
    workspace
    |> WorkspaceVerifier.structural(allow_missing: true, files: false)
    |> Validation.finish()
    |> ensure_valid()
  end

  defp ensure_valid(%Validation{errors: []}), do: :ok

  defp ensure_valid(%Validation{errors: errors}) do
    {:error, error("workspace validation failed: #{Enum.join(errors, "; ")}")}
  end

  defp plan(workspace) do
    entries = Map.new(workspace.manifest.files, &{&1.record, &1})

    with {:ok, originals} <- original_payloads(workspace, entries),
         {:ok, additions} <- added_payloads(workspace),
         payloads = originals ++ additions,
         :ok <- validate_file_count(length(payloads)),
         :ok <- validate_hashes(payloads) do
      {:ok, assemble_plan(workspace, payloads)}
    end
  end

  defp original_payloads(workspace, entries) do
    selected = MapSet.new(workspace.manifest.packs)

    collect_payloads(
      workspace.pack_info.records,
      &original_payload(workspace, entries, selected, &1)
    )
  end

  defp original_payload(workspace, entries, selected, record) do
    if MapSet.member?(selected, record.archive_id) do
      entry = Map.fetch!(entries, record.index)

      if_present(workspace.root, entry.stored_path, fn path, _stat ->
        source = %{
          path: path,
          extracted_md5: entry.extracted_md5,
          indexed_md5: entry.indexed_md5
        }

        {:ok, payload(record, source, {0, record.offset, record.index})}
      end)
    else
      {:ok, payload(record, nil, {0, record.offset, record.index})}
    end
  end

  defp added_payloads(workspace) do
    workspace.manifest.additions
    |> Enum.with_index()
    |> collect_payloads(&added_payload(workspace, &1))
  end

  defp added_payload(workspace, {%Addition{} = addition, index}) do
    with :ok <- validate_archive(addition, workspace.manifest.packs) do
      if_present(workspace.root, addition.stored_path, fn path, stat ->
        build_added_payload(path, stat.size, addition, {1, index, 0})
      end)
    end
  end

  defp collect_payloads(enumerable, builder) do
    Enum.reduce_while(enumerable, {:ok, []}, fn item, {:ok, payloads} ->
      case builder.(item) do
        {:ok, nil} -> {:cont, {:ok, payloads}}
        {:ok, payload} -> {:cont, {:ok, [payload | payloads]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, payloads} -> {:ok, Enum.reverse(payloads)}
      error -> error
    end
  end

  defp if_present(root, stored_path, builder) do
    with {:ok, path} <- safe_source(root, stored_path) do
      case File.stat(path) do
        {:ok, %File.Stat{type: :regular} = stat} ->
          builder.(path, stat)

        {:error, :enoent} ->
          {:ok, nil}

        {:ok, %File.Stat{type: type}} ->
          {:error, error("#{path} is #{type}, not a file")}

        {:error, reason} ->
          {:error, error("cannot inspect #{path}: #{FileOps.format_reason(reason)}")}
      end
    end
  end

  defp safe_source(root, stored_path) do
    case PathGuard.join(root, stored_path) do
      {:ok, path} -> {:ok, path}
      {:error, message} -> {:error, error(message)}
    end
  end

  defp validate_archive(addition, selected) do
    if addition.archive_id in selected do
      :ok
    else
      {:error,
       error(
         "addition #{inspect(addition.stored_path)} references unselected archive #{addition.archive_id}"
       )}
    end
  end

  defp build_added_payload(source_path, size, addition, order) do
    with :ok <- validate_size(addition.stored_path, size) do
      record = %FileRecord{
        index: 0,
        md5: <<0::128>>,
        crc32: addition.crc32,
        crc16: addition.crc16,
        archive_id: addition.archive_id,
        offset: 0,
        size: size
      }

      {:ok, payload(record, %{path: source_path}, order)}
    end
  end

  defp payload(record, source, order), do: %{record: record, source: source, order: order}

  defp validate_file_count(count) when count <= @max_u16, do: :ok
  defp validate_file_count(count), do: {:error, error("file count #{count} exceeds u16")}

  defp validate_hashes(payloads) do
    hashes = Enum.map(payloads, &hash_pair(&1.record))

    if length(hashes) == MapSet.size(MapSet.new(hashes)) do
      :ok
    else
      {:error, error("file table contains colliding CRC keys")}
    end
  end

  defp assemble_plan(workspace, payloads) do
    payloads =
      payloads
      |> Enum.sort_by(&hash_pair(&1.record))
      |> Enum.with_index()
      |> Enum.map(fn {payload, index} -> reindex(payload, index) end)

    records = Enum.map(payloads, & &1.record)

    sources =
      payloads
      |> Enum.reject(&is_nil(&1.source))
      |> Map.new(&{&1.record.index, &1.source})

    archives =
      payloads
      |> Enum.group_by(& &1.record.archive_id)
      |> Map.new(fn {archive_id, items} ->
        records = items |> Enum.sort_by(& &1.order) |> Enum.map(& &1.record)
        {archive_id, records}
      end)

    pack_info = %{workspace.pack_info | records: records, file_count: length(records)}
    %{pack_info: pack_info, sources: sources, archives: archives}
  end

  defp reindex(payload, index) do
    %{payload | record: %{payload.record | index: index}}
  end

  defp hash_pair(record), do: {record.crc32, record.crc16}

  defp rebuild_archives(workspace, output, options, plan) do
    state = initial_state(workspace, output, options, plan)

    result =
      workspace.manifest.packs
      |> Enum.sort()
      |> Enum.reduce_while(state, fn archive_id, current ->
        reduce_archive(archive_id, Map.get(plan.archives, archive_id, []), current)
      end)

    case result do
      {:error, reason} -> {:error, reason}
      rebuilt -> {:ok, rebuilt}
    end
  end

  defp reduce_archive(archive_id, records, state) do
    case rebuild_archive(archive_id, records, state) do
      {:ok, updated} -> {:cont, updated}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp initial_state(workspace, output, options, plan) do
    %State{
      workspace: workspace,
      output: output,
      force: options[:force] == true,
      on_progress: options[:on_progress] || fn _record -> :ok end,
      pack_info: plan.pack_info,
      sources: plan.sources,
      records: %{},
      archive_md5s: %{},
      archive_sizes: %{}
    }
  end

  defp rebuild_archive(archive_id, records, state) do
    output_path = Archive.path(state.output, archive_id)

    writer = fn stream ->
      rebuild_records(records, archive_state(stream, state))
    end

    case AtomicFile.write(output_path, state.force, writer) do
      {:ok, {updated_records, archive_md5, size}} ->
        updated = merge_archive(state, archive_id, updated_records, archive_md5, size)
        {:ok, updated}

      {:error, reason} ->
        {:error, error("archive #{archive_id}: #{FileOps.format_reason(reason)}")}
    end
  end

  defp archive_state(stream, state) do
    %ArchiveState{
      stream: stream,
      sources: state.sources,
      cipher_mode: state.workspace.manifest.cipher_mode,
      position: 0,
      md5: Archive.md5(),
      records: []
    }
  end

  defp rebuild_records(records, state) do
    case Enum.reduce_while(records, state, &reduce_record/2) do
      {:error, reason} -> {:error, reason}
      rebuilt -> complete_archive(rebuilt)
    end
  end

  defp reduce_record(record, state) do
    case rebuild_record(record, state) do
      {:ok, updated} -> {:cont, updated}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp rebuild_record(record, state) do
    offset = Archive.align(state.position)
    padding_size = offset - state.position
    source = Map.fetch!(state.sources, record.index)

    with {:ok, padded_md5} <- Archive.write_padding(state.stream, padding_size, state.md5),
         {:ok, payload_md5, size, archive_md5} <-
           write_payload(source.path, state.stream, record, state.cipher_mode, padded_md5),
         :ok <- validate_size(record.index, size) do
      updated_record = %{
        record
        | offset: offset,
          size: size,
          md5: indexed_md5(source, payload_md5)
      }

      updated_state = %{
        state
        | position: offset + size,
          md5: archive_md5,
          records: [updated_record | state.records]
      }

      {:ok, updated_state}
    end
  end

  defp write_payload(path, archive, record, cipher_mode, archive_md5) do
    writer = fn source ->
      Archive.write_plaintext(source, archive, record, cipher_mode, archive_md5)
    end

    case File.open(path, [:read, :binary, :raw], writer) do
      {:ok, result} -> result
      {:error, reason} -> {:error, error("cannot read #{path}: #{FileOps.format_reason(reason)}")}
    end
  end

  defp validate_size(_record_index, size) when size <= @max_u32, do: :ok

  defp validate_size(record_index, size) do
    {:error, error("record #{record_index}: payload size #{size} exceeds u32")}
  end

  defp indexed_md5(%{extracted_md5: digest, indexed_md5: indexed_md5}, digest),
    do: indexed_md5

  defp indexed_md5(_source, payload_md5), do: payload_md5

  defp complete_archive(state) do
    digest = :crypto.hash_final(state.md5)
    {:ok, {Enum.reverse(state.records), digest, state.position}}
  end

  defp merge_archive(state, archive_id, records, md5, size) do
    state.on_progress.(archive_id)

    updated_records = Enum.reduce(records, state.records, &Map.put(&2, &1.index, &1))

    %{
      state
      | records: updated_records,
        archive_md5s: Map.put(state.archive_md5s, archive_id, md5),
        archive_sizes: Map.put(state.archive_sizes, archive_id, size)
    }
  end

  defp write_indexes(state) do
    pack_info = updated_pack_info(state)

    with :ok <- write_pack_info(state, pack_info) do
      write_finfolist(state)
    end
  end

  defp updated_pack_info(state) do
    records = Enum.map(state.pack_info.records, &Map.get(state.records, &1.index, &1))

    archive_md5s =
      state.pack_info.archive_md5s
      |> Enum.with_index()
      |> Enum.map(fn {md5, archive_id} -> Map.get(state.archive_md5s, archive_id, md5) end)

    %{state.pack_info | records: records, archive_md5s: archive_md5s}
  end

  defp write_pack_info(state, pack_info) do
    path = Path.join([state.output, "pack", "packinfo.bin"])
    FileOps.write_bytes(path, PackInfo.encode(pack_info), state.force, @context)
  end

  defp write_finfolist(%{workspace: %{finfolist: nil}}), do: :ok

  defp write_finfolist(state) do
    records = Enum.map(state.workspace.finfolist.records, &update_integrity_record(&1, state))
    path = Path.join(state.output, "finfolist.bin")

    FileOps.write_bytes(
      path,
      Finfolist.encode(%{state.workspace.finfolist | records: records}),
      state.force,
      @context
    )
  end

  defp update_integrity_record(%IntegrityRecord{} = record, state) do
    archive_lookup =
      state.workspace.manifest.packs
      |> Enum.map(&{Archive.virtual_path(&1), &1})
      |> Map.new()

    case Map.fetch(archive_lookup, record.path) do
      {:ok, archive_id} ->
        %{
          record
          | size: Map.fetch!(state.archive_sizes, archive_id),
            md5: Map.fetch!(state.archive_md5s, archive_id)
        }

      :error ->
        record
    end
  end

  defp result(state) do
    %RepackResult{
      archives: length(state.workspace.manifest.packs),
      files: map_size(state.records),
      bytes: state.archive_sizes |> Map.values() |> Enum.sum(),
      cipher_mode: state.workspace.manifest.cipher_mode
    }
  end

  defp error(message), do: %Error{message: message, context: @context}
end
