defmodule Packfs.Format.Verifier do
  @moduledoc "Structural and digest verification for packed data sets."

  alias Packfs.Format.Archive
  alias Packfs.Format.DataSet
  alias Packfs.Format.PackInfo
  alias Packfs.Format.Validation
  alias Packfs.Shared.Md5

  @spec verify(DataSet.t(), MapSet.t(non_neg_integer()), keyword()) :: Validation.t()
  def verify(%DataSet{} = data_set, selected, options \\ []) do
    structural = structural(data_set, selected)
    archive_result = verify_archives(data_set, selected, options[:archives] == true)
    file_result = verify_files(data_set, selected, options[:files] == true, options[:cipher])

    structural
    |> Validation.merge(archive_result)
    |> Validation.merge(file_result)
    |> Validation.finish()
  end

  @spec structural(DataSet.t(), MapSet.t(non_neg_integer())) :: Validation.t()
  def structural(%DataSet{} = data_set, selected) do
    validation =
      %Validation{}
      |> validate_record_order(data_set)
      |> validate_archive_ids(data_set)
      |> validate_finfolist_presence(data_set)

    records_by_archive = PackInfo.records_by_archive(data_set.pack_info)

    Enum.reduce(selected, validation, fn archive_id, result ->
      records = Map.get(records_by_archive, archive_id, [])
      validate_archive_structure(result, data_set, archive_id, records)
    end)
  end

  ###
  ### Helpers
  ###

  defp validate_record_order(validation, data_set) do
    keys = Enum.map(data_set.pack_info.records, &{&1.crc32, &1.crc16})

    cond do
      keys != Enum.sort(keys) ->
        Validation.error(validation, "file record table is not hash-sorted")

      length(keys) != MapSet.size(MapSet.new(keys)) ->
        Validation.error(validation, "file record table contains duplicate hash pairs")

      true ->
        validation
    end
  end

  defp validate_archive_ids(validation, data_set) do
    count = data_set.pack_info.archive_count

    Enum.reduce(data_set.pack_info.records, validation, fn record, result ->
      if record.archive_id < count do
        result
      else
        Validation.error(
          result,
          "record #{record.index}: archive #{record.archive_id} is outside the archive table"
        )
      end
    end)
  end

  defp validate_finfolist_presence(validation, %DataSet{finfolist: nil}) do
    Validation.warning(validation, "finfolist.bin is absent")
  end

  defp validate_finfolist_presence(validation, _data_set), do: validation

  defp validate_archive_structure(validation, data_set, archive_id, records) do
    path = Archive.path(data_set.root, archive_id)

    case File.stat(path) do
      {:ok, stat} ->
        validate_archive_file(validation, data_set, archive_id, records, path, stat)

      {:error, reason} ->
        Validation.error(validation, "archive #{archive_id}: #{:file.format_error(reason)}")
    end
  end

  defp validate_archive_file(validation, data_set, archive_id, records, path, stat) do
    reader = fn stream ->
      validation
      |> validate_offsets(stream, archive_id, records)
      |> validate_archive_size(archive_id, records, stat.size)
      |> validate_integrity_record(data_set, archive_id, stat.size)
    end

    case File.open(path, [:read, :binary, :raw], reader) do
      {:ok, result} ->
        result

      {:error, reason} ->
        Validation.error(validation, "archive #{archive_id}: #{:file.format_error(reason)}")
    end
  end

  defp validate_offsets(validation, stream, archive_id, records) do
    {result, _end} =
      Enum.reduce(records, {validation, 0}, fn record, {current, previous_end} ->
        expected = Archive.align(previous_end)

        current =
          if record.offset == expected do
            validate_padding(
              current,
              stream,
              archive_id,
              previous_end,
              record.offset - previous_end
            )
          else
            Validation.error(
              current,
              "record #{record.index}: offset #{record.offset}, expected #{expected}"
            )
          end

        {current, max(previous_end, record.offset + record.size)}
      end)

    result
  end

  defp validate_padding(validation, stream, archive_id, offset, size) do
    case Archive.padding_valid?(stream, offset, size) do
      {:ok, true} ->
        validation

      {:ok, false} ->
        Validation.error(validation, "archive #{archive_id}: non-0x20 padding at #{offset}")

      {:error, reason} ->
        Validation.error(
          validation,
          "archive #{archive_id}: cannot read padding: #{inspect(reason)}"
        )
    end
  end

  defp validate_archive_size(validation, archive_id, records, actual_size) do
    expected_size =
      records
      |> List.last()
      |> case do
        nil -> 0
        record -> record.offset + record.size
      end

    if expected_size == actual_size do
      validation
    else
      Validation.error(
        validation,
        "archive #{archive_id}: indexed end #{expected_size}, physical size #{actual_size}"
      )
    end
  end

  defp validate_integrity_record(validation, %DataSet{finfolist: nil}, _archive_id, _size) do
    validation
  end

  defp validate_integrity_record(validation, data_set, archive_id, size) do
    path = Archive.virtual_path(archive_id)
    matching = Enum.filter(data_set.finfolist.records, &(&1.path == path))
    expected_md5 = Enum.at(data_set.pack_info.archive_md5s, archive_id)

    case matching do
      [record] ->
        validation
        |> Validation.check(record.size == size, "archive #{archive_id}: finfolist size differs")
        |> Validation.check(
          record.md5 == expected_md5,
          "archive #{archive_id}: index MD5 values differ"
        )

      [] ->
        Validation.error(validation, "archive #{archive_id}: absent from finfolist.bin")

      _records ->
        Validation.error(validation, "archive #{archive_id}: duplicate finfolist records")
    end
  end

  defp verify_archives(_data_set, _selected, false), do: %Validation{}

  defp verify_archives(data_set, selected, true) do
    Enum.reduce(selected, %Validation{}, fn archive_id, validation ->
      path = Archive.path(data_set.root, archive_id)
      expected = Enum.at(data_set.pack_info.archive_md5s, archive_id)

      case Md5.file(path) do
        {:ok, ^expected, _size} ->
          validation

        {:ok, actual, _size} ->
          Validation.error(
            validation,
            "archive #{archive_id}: MD5 mismatch, expected #{hex(expected)}, got #{hex(actual)}"
          )

        {:error, reason} ->
          Validation.error(validation, "archive #{archive_id}: #{:file.format_error(reason)}")
      end
    end)
  end

  defp verify_files(_data_set, _selected, false, _cipher), do: %Validation{}

  defp verify_files(data_set, selected, true, requested_cipher) do
    case DataSet.cipher_mode(data_set, requested_cipher || :auto) do
      {:ok, mode} ->
        data_set.pack_info
        |> PackInfo.selected_records(selected)
        |> Enum.reduce(%Validation{}, fn record, validation ->
          verify_payload(validation, data_set, record, mode)
        end)

      {:error, error} ->
        Validation.error(%Validation{}, Exception.message(error))
    end
  end

  defp verify_payload(validation, data_set, record, mode) do
    case Archive.payload_digest(data_set.root, record, mode) do
      {:ok, digest} when digest == record.md5 ->
        validation

      {:ok, digest} ->
        Validation.error(
          validation,
          "record #{record.index}: plaintext MD5 mismatch, expected #{hex(record.md5)}, " <>
            "got #{hex(digest)}"
        )

      {:error, reason} ->
        Validation.error(
          validation,
          "record #{record.index}: cannot read payload: #{inspect(reason)}"
        )
    end
  end

  defp hex(digest), do: Base.encode16(digest, case: :lower)
end
