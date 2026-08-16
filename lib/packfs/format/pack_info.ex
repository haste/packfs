defmodule Packfs.Format.PackInfo do
  @moduledoc "Codec for `packinfo.bin`."

  alias Packfs.Format.Error
  alias Packfs.Format.FileRecord

  @current_magic 0x20110201
  @legacy_magic 0x20041207
  @header_size 16
  @record_size 32
  @digest_size 16

  @enforce_keys [
    :magic,
    :file_table_offset,
    :archive_table_offset,
    :file_count,
    :archive_count,
    :records,
    :archive_md5s,
    :raw
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          magic: non_neg_integer(),
          file_table_offset: non_neg_integer(),
          archive_table_offset: non_neg_integer(),
          file_count: non_neg_integer(),
          archive_count: non_neg_integer(),
          records: [FileRecord.t()],
          archive_md5s: [<<_::128>>],
          raw: binary()
        }

  @spec decode(binary()) :: {:ok, t()} | {:error, Error.t()}
  def decode(
        <<magic::little-unsigned-32, file_offset::little-unsigned-32,
          archive_offset::little-unsigned-32, file_count::little-unsigned-16,
          archive_count::little-unsigned-16, _rest::binary>> = binary
      ) do
    with :ok <- validate_magic(magic),
         :ok <- validate_tables(binary, file_offset, file_count, archive_offset, archive_count) do
      records = decode_records(binary, file_offset, file_count)
      archive_md5s = decode_archive_md5s(binary, archive_offset, archive_count)

      {:ok,
       %__MODULE__{
         magic: magic,
         file_table_offset: file_offset,
         archive_table_offset: archive_offset,
         file_count: file_count,
         archive_count: archive_count,
         records: records,
         archive_md5s: archive_md5s,
         raw: binary
       }}
    end
  end

  def decode(_binary) do
    {:error, error("header is shorter than 16 bytes", 0)}
  end

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = info) do
    header =
      <<info.magic::little-unsigned-32, info.file_table_offset::little-unsigned-32,
        info.archive_table_offset::little-unsigned-32, length(info.records)::little-unsigned-16,
        length(info.archive_md5s)::little-unsigned-16>>

    records = IO.iodata_to_binary(Enum.map(info.records, &encode_record/1))
    archive_md5s = IO.iodata_to_binary(info.archive_md5s)

    info.raw
    |> replace(0, @header_size, header)
    |> replace(info.file_table_offset, info.file_count * @record_size, records)
    |> replace(info.archive_table_offset, info.archive_count * @digest_size, archive_md5s)
  end

  @spec supported_magic?(non_neg_integer()) :: boolean()
  def supported_magic?(magic), do: magic in [@current_magic, @legacy_magic]

  @spec magic_name(non_neg_integer()) :: String.t()
  def magic_name(@current_magic), do: "GFDM V8"
  def magic_name(@legacy_magic), do: "legacy GFDM/XG1"
  def magic_name(magic), do: "unknown 0x#{Integer.to_string(magic, 16)}"

  @spec selected_records(t(), MapSet.t(non_neg_integer())) :: [FileRecord.t()]
  def selected_records(%__MODULE__{records: records}, selected) do
    Enum.filter(records, &MapSet.member?(selected, &1.archive_id))
  end

  @spec records_by_archive(t()) :: %{non_neg_integer() => [FileRecord.t()]}
  def records_by_archive(%__MODULE__{records: records}) do
    records
    |> Enum.group_by(& &1.archive_id)
    |> Map.new(fn {archive_id, grouped} ->
      {archive_id, Enum.sort_by(grouped, & &1.offset)}
    end)
  end

  ###
  ### Helpers
  ###

  defp validate_magic(magic) do
    if supported_magic?(magic) do
      :ok
    else
      {:error, error("unsupported magic 0x#{Integer.to_string(magic, 16)}", 0)}
    end
  end

  defp validate_tables(binary, file_offset, file_count, archive_offset, archive_count) do
    file_end = file_offset + file_count * @record_size
    archive_end = archive_offset + archive_count * @digest_size

    cond do
      file_offset < @header_size ->
        {:error, error("file table overlaps the header", 4)}

      archive_offset < file_end ->
        {:error, error("archive MD5 table overlaps the file table", 8)}

      file_end > byte_size(binary) ->
        {:error, error("file table extends past end of file", file_offset)}

      archive_end > byte_size(binary) ->
        {:error, error("archive MD5 table extends past end of file", archive_offset)}

      true ->
        :ok
    end
  end

  defp decode_records(binary, offset, count) do
    table = binary_part(binary, offset, count * @record_size)
    do_decode_records(table, 0, [])
  end

  defp do_decode_records(<<>>, _index, records), do: Enum.reverse(records)

  defp do_decode_records(
         <<md5::bytes-16, crc32::little-unsigned-32, crc16::little-unsigned-16,
           archive_id::little-unsigned-16, offset::little-unsigned-32, size::little-unsigned-32,
           rest::binary>>,
         index,
         records
       ) do
    record = %FileRecord{
      index: index,
      md5: md5,
      crc32: crc32,
      crc16: crc16,
      archive_id: archive_id,
      offset: offset,
      size: size
    }

    do_decode_records(rest, index + 1, [record | records])
  end

  defp decode_archive_md5s(binary, offset, count) do
    table = binary_part(binary, offset, count * @digest_size)
    for <<digest::bytes-16 <- table>>, do: digest
  end

  defp encode_record(%FileRecord{} = record) do
    <<record.md5::bytes-16, record.crc32::little-unsigned-32, record.crc16::little-unsigned-16,
      record.archive_id::little-unsigned-16, record.offset::little-unsigned-32,
      record.size::little-unsigned-32>>
  end

  defp replace(binary, offset, old_size, replacement) do
    prefix = binary_part(binary, 0, offset)
    suffix_offset = offset + old_size
    suffix = binary_part(binary, suffix_offset, byte_size(binary) - suffix_offset)
    prefix <> replacement <> suffix
  end

  defp error(message, offset) do
    %Error{message: message, context: "packinfo.bin", offset: offset}
  end
end
