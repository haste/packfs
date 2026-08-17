defmodule Packfs.Format.Unpacker do
  @moduledoc "Extracts selected PackFS archives into a manifest workspace."

  alias Packfs.Format.Archive
  alias Packfs.Format.DataSet
  alias Packfs.Format.Error
  alias Packfs.Format.Manifest
  alias Packfs.Format.Manifest.Entry
  alias Packfs.Format.PackInfo
  alias Packfs.Format.ResolvedName
  alias Packfs.Format.Unpacker.State
  alias Packfs.Format.UnpackResult
  alias Packfs.Shared.AtomicFile
  alias Packfs.Shared.FileOps
  alias Packfs.Shared.PathGuard

  @context "unpack"
  @default_jobs 4

  @spec run(DataSet.t(), Path.t(), MapSet.t(non_neg_integer()), map(), keyword()) ::
          {:ok, UnpackResult.t()} | {:error, Error.t()}
  def run(%DataSet{} = data_set, output, selected, names, options \\ []) do
    expanded_output = Path.expand(output)

    with {:ok, cipher_mode} <- DataSet.cipher_mode(data_set, options[:cipher] || :auto),
         {:ok, jobs} <- jobs(options[:jobs]),
         :ok <- FileOps.prepare_output(expanded_output, options[:force] == true, @context),
         {:ok, state} <-
           unpack_selected(data_set, expanded_output, selected, names, cipher_mode, jobs, options),
         :ok <- write_workspace(state, selected) do
      {:ok, result(state, selected)}
    end
  end

  ###
  ### Helpers
  ###

  defp unpack_selected(data_set, output, selected, names, cipher_mode, jobs, options) do
    state = initial_state(data_set, output, names, cipher_mode, options)
    grouped = PackInfo.records_by_archive(data_set.pack_info)

    result =
      selected
      |> Enum.sort()
      |> Enum.map(&{&1, Map.get(grouped, &1, [])})
      |> Task.async_stream(&unpack_archive_task(&1, state),
        max_concurrency: jobs,
        ordered: true,
        timeout: :infinity
      )
      |> Enum.reduce_while(state, &merge_archive/2)

    case result do
      {:error, reason} -> {:error, reason}
      unpacked -> {:ok, unpacked}
    end
  end

  defp unpack_archive_task({archive_id, records}, state) do
    initial = %{state | files: [], bytes: 0, warnings: []}

    case unpack_archive(archive_id, records, initial) do
      {:error, reason} ->
        {:error, reason}

      {:ok, unpacked} ->
        {:ok, %{files: unpacked.files, bytes: unpacked.bytes, warnings: unpacked.warnings}}
    end
  end

  defp merge_archive({:ok, {:ok, archive}}, state) do
    updated = %{
      state
      | files: archive.files ++ state.files,
        bytes: state.bytes + archive.bytes,
        warnings: archive.warnings ++ state.warnings
    }

    {:cont, updated}
  end

  defp merge_archive({:ok, {:error, reason}}, _state), do: {:halt, {:error, reason}}
  defp merge_archive({:exit, reason}, _state), do: exit(reason)

  defp initial_state(data_set, output, names, cipher_mode, options) do
    %State{
      data_set: data_set,
      output: output,
      cipher_mode: cipher_mode,
      names: names,
      force: options[:force] == true,
      verify: options[:verify] != false,
      verify_archives: options[:verify_archives] == true,
      allow_bad_md5: options[:allow_bad_md5] == true,
      on_progress: options[:on_progress] || fn _record -> :ok end,
      files: [],
      bytes: 0,
      warnings: [],
      archive_digest: nil
    }
  end

  defp jobs(nil), do: {:ok, min(System.schedulers_online(), @default_jobs)}
  defp jobs(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp jobs(_value), do: {:error, error("jobs must be a positive integer")}

  defp unpack_archive(archive_id, records, state) do
    archive_path = Archive.path(state.data_set.root, archive_id)
    initial = begin_archive(state)

    case File.open(archive_path, [:read, :binary, :raw], &unpack_records(records, &1, initial)) do
      {:ok, {:ok, unpacked}} ->
        finish_archive(archive_id, unpacked)

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, error("archive #{archive_id}: #{:file.format_error(reason)}")}
    end
  end

  defp unpack_records(records, archive, state) do
    case Enum.reduce_while(records, state, &reduce_record(&1, &2, archive)) do
      {:error, reason} -> {:error, reason}
      unpacked -> {:ok, unpacked}
    end
  end

  defp reduce_record(record, state, archive) do
    case unpack_record(record, archive, state) do
      {:ok, updated} -> {:cont, updated}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp unpack_record(record, archive, state) do
    paths = extraction_paths(record, Map.get(state.names, {record.crc32, record.crc16}))

    case PathGuard.join(state.output, paths.stored) do
      {:ok, target} -> write_record(target, record, archive, state, paths)
      {:error, message} -> {:error, error(message)}
    end
  end

  defp write_record(target, record, archive, state, paths) do
    writer = fn destination ->
      extract_record(archive, destination, record, state)
    end

    case AtomicFile.write(target, state.force, writer) do
      {:ok, {digest, archive_digest}} ->
        finish_record(record, digest, %{state | archive_digest: archive_digest}, paths)

      {:error, reason} ->
        {:error, error("record #{record.index}: #{FileOps.format_reason(reason)}")}
    end
  end

  defp extract_record(archive, destination, record, %{archive_digest: nil} = state) do
    case Archive.extract(archive, destination, record, state.cipher_mode) do
      {:ok, digest} -> {:ok, {digest, nil}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_record(archive, destination, record, state) do
    %{md5: archive_md5, position: position} = state.archive_digest

    case Archive.extract_and_hash(
           archive,
           destination,
           record,
           state.cipher_mode,
           archive_md5,
           position
         ) do
      {:ok, digest, updated_md5, updated_position} ->
        {:ok, {digest, %{md5: updated_md5, position: updated_position}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp begin_archive(%{verify_archives: true} = state) do
    %{state | archive_digest: %{md5: Archive.md5(), position: 0}}
  end

  defp begin_archive(state), do: state

  defp finish_archive(_archive_id, %{verify_archives: false} = state), do: {:ok, state}

  defp finish_archive(archive_id, state) do
    digest = :crypto.hash_final(state.archive_digest.md5)
    expected = Enum.at(state.data_set.pack_info.archive_md5s, archive_id)

    if digest == expected do
      {:ok, %{state | archive_digest: nil}}
    else
      {:error,
       error("archive #{archive_id}: MD5 mismatch, expected #{hex(expected)}, got #{hex(digest)}")}
    end
  end

  defp finish_record(record, digest, state, paths) do
    digest_matches? = digest == record.md5

    case enforce_digest(state, record, digest, digest_matches?) do
      {:ok, valid_state} ->
        updated = add_manifest_entry(valid_state, record, digest, paths)

        {:ok, updated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp enforce_digest(state, _record, _digest, true), do: {:ok, state}
  defp enforce_digest(%{verify: false} = state, _record, _digest, false), do: {:ok, state}

  defp enforce_digest(%{allow_bad_md5: true} = state, record, digest, false) do
    warning = digest_mismatch(record, digest)
    {:ok, %{state | warnings: [warning | state.warnings]}}
  end

  defp enforce_digest(_state, record, digest, false) do
    {:error, error(digest_mismatch(record, digest))}
  end

  defp add_manifest_entry(state, record, digest, paths) do
    entry = %Entry{
      record: record.index,
      stored_path: paths.stored,
      path: paths.path,
      update: paths.update,
      extracted_md5: digest,
      indexed_md5: record.md5
    }

    state.on_progress.(record)
    %{state | files: [entry | state.files], bytes: state.bytes + record.size}
  end

  defp write_workspace(state, selected) do
    manifest = %Manifest{
      cipher_mode: state.cipher_mode,
      packs: selected |> Enum.sort(),
      additions: [],
      files: Enum.reverse(state.files)
    }

    with :ok <- write_original_pack_info(state),
         :ok <- write_original_finfolist(state) do
      write_manifest(state, manifest)
    end
  end

  defp write_original_pack_info(state) do
    path = Path.join([state.output, "original", "packinfo.bin"])
    FileOps.write_bytes(path, state.data_set.pack_info.raw, state.force, @context)
  end

  defp write_original_finfolist(%{data_set: %{finfolist: nil}}), do: :ok

  defp write_original_finfolist(state) do
    path = Path.join([state.output, "original", "finfolist.bin"])
    FileOps.write_bytes(path, state.data_set.finfolist.raw, state.force, @context)
  end

  defp write_manifest(state, manifest) do
    path = Path.join(state.output, "packfs-manifest.json")
    FileOps.write_bytes(path, Manifest.encode(manifest), state.force, @context)
  end

  defp result(state, selected) do
    resolved = Enum.count(state.files, &(not is_nil(&1.path)))
    updates = state.files |> Enum.reject(&is_nil(&1.update)) |> Enum.frequencies_by(& &1.update)

    %UnpackResult{
      archives: MapSet.size(selected),
      files: length(state.files),
      bytes: state.bytes,
      resolved: resolved,
      unresolved: length(state.files) - resolved,
      updates: updates,
      warnings: Enum.reverse(state.warnings),
      cipher_mode: state.cipher_mode
    }
  end

  defp extraction_paths(record, nil) do
    hash = "#{hex(record.crc32, 8)}-#{hex(record.crc16, 4)}"
    index = record.index |> to_string() |> String.pad_leading(5, "0")

    %{
      stored: "files/__unknown__/#{hash}-#{index}.bin",
      path: nil,
      update: nil
    }
  end

  defp extraction_paths(record, path) when is_binary(path) do
    extraction_paths(record, %ResolvedName{path: path, update: nil})
  end

  defp extraction_paths(_record, %ResolvedName{path: path, update: nil}) do
    %{stored: rooted("files", path), path: path, update: nil}
  end

  defp extraction_paths(_record, %ResolvedName{path: path, update: update}) do
    %{
      stored: rooted(Path.join("updates", update), path),
      path: path,
      update: update
    }
  end

  defp rooted(root, path), do: Path.join(root, String.trim_leading(path, "/"))

  defp digest_mismatch(record, digest) do
    "record #{record.index}: plaintext MD5 mismatch, expected #{hex(record.md5)}, " <>
      "got #{hex(digest)}"
  end

  defp hex(binary) when is_binary(binary), do: Base.encode16(binary, case: :lower)

  defp hex(integer, width) do
    integer |> Integer.to_string(16) |> String.pad_leading(width, "0")
  end

  defp error(message), do: %Error{message: message, context: @context}
end
