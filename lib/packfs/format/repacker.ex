defmodule Packfs.Format.Repacker do
  @moduledoc "Rebuilds archive overlays from extraction workspaces."

  alias Packfs.Format.Archive
  alias Packfs.Format.Error
  alias Packfs.Format.Finfolist
  alias Packfs.Format.IntegrityRecord
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

  @max_u32 0xFFFFFFFF
  @context "repack"

  @spec run(Workspace.t(), Path.t(), keyword()) ::
          {:ok, RepackResult.t()} | {:error, Error.t()}
  def run(%Workspace{} = workspace, output, options \\ []) do
    expanded_output = Path.expand(output)

    with :ok <- ensure_valid_workspace(workspace),
         :ok <- FileOps.prepare_output(expanded_output, options[:force] == true, @context),
         {:ok, state} <- rebuild_archives(workspace, expanded_output, options),
         :ok <- write_indexes(state) do
      {:ok, result(state)}
    end
  end

  ###
  ### Helpers
  ###

  defp ensure_valid_workspace(workspace) do
    workspace
    |> WorkspaceVerifier.structural()
    |> Validation.finish()
    |> ensure_valid()
  end

  defp ensure_valid(%Validation{errors: []}), do: :ok

  defp ensure_valid(%Validation{errors: errors}) do
    {:error, error("workspace validation failed: #{Enum.join(errors, "; ")}")}
  end

  defp rebuild_archives(workspace, output, options) do
    state = initial_state(workspace, output, options)
    grouped = PackInfo.records_by_archive(workspace.pack_info)

    result =
      workspace.manifest.packs
      |> Enum.sort()
      |> Enum.reduce_while(state, fn archive_id, current ->
        reduce_archive(archive_id, Map.get(grouped, archive_id, []), current)
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

  defp initial_state(workspace, output, options) do
    %State{
      workspace: workspace,
      output: output,
      force: options[:force] == true,
      on_progress: options[:on_progress] || fn _record -> :ok end,
      entries: Map.new(workspace.manifest.files, &{&1.record, &1}),
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
      workspace: state.workspace,
      entries: state.entries,
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
    entry = Map.fetch!(state.entries, record.index)

    with {:ok, padded_md5} <- Archive.write_padding(state.stream, padding_size, state.md5),
         {:ok, source_path} <- safe_source(state.workspace.root, entry.stored_path),
         {:ok, payload_md5, size, archive_md5} <-
           write_payload(source_path, state.stream, record, state.cipher_mode, padded_md5),
         :ok <- validate_size(record.index, size) do
      updated_record = %{
        record
        | offset: offset,
          size: size,
          md5: indexed_md5(entry.extracted_md5, payload_md5, record.md5)
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

  defp safe_source(root, stored_path) do
    case PathGuard.join(root, stored_path) do
      {:ok, path} -> {:ok, path}
      {:error, message} -> {:error, error(message)}
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

  defp indexed_md5(extracted_md5, extracted_md5, indexed_md5), do: indexed_md5
  defp indexed_md5(_extracted_md5, payload_md5, _indexed_md5), do: payload_md5

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
    records = Enum.map(state.workspace.pack_info.records, &Map.get(state.records, &1.index, &1))

    archive_md5s =
      state.workspace.pack_info.archive_md5s
      |> Enum.with_index()
      |> Enum.map(fn {md5, archive_id} -> Map.get(state.archive_md5s, archive_id, md5) end)

    %{state.workspace.pack_info | records: records, archive_md5s: archive_md5s}
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
