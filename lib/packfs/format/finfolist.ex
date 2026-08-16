defmodule Packfs.Format.Finfolist do
  @moduledoc "Codec for `finfolist.bin`."

  alias Packfs.Format.Error
  alias Packfs.Format.IntegrityRecord

  @header_size 4
  @record_size 88

  @enforce_keys [:records, :raw]
  defstruct @enforce_keys

  @type t :: %__MODULE__{records: [IntegrityRecord.t()], raw: binary()}

  @spec decode(binary()) :: {:ok, t()} | {:error, Error.t()}
  def decode(<<count::little-unsigned-32, rest::binary>> = binary) do
    expected = count * @record_size

    if byte_size(rest) == expected do
      {:ok, %__MODULE__{records: decode_records(rest, 0, []), raw: binary}}
    else
      {:error,
       %Error{
         message: "expected #{expected} record bytes, got #{byte_size(rest)}",
         context: "finfolist.bin",
         offset: @header_size
       }}
    end
  end

  def decode(_binary) do
    {:error,
     %Error{message: "header is shorter than 4 bytes", context: "finfolist.bin", offset: 0}}
  end

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{records: records}) do
    body = IO.iodata_to_binary(Enum.map(records, &encode_record/1))
    <<length(records)::little-unsigned-32, body::binary>>
  end

  ###
  ### Helpers
  ###

  defp decode_records(<<>>, _index, records), do: Enum.reverse(records)

  defp decode_records(
         <<path_field::bytes-64, size::little-unsigned-32, md5::bytes-16,
           group::little-unsigned-32, rest::binary>>,
         index,
         records
       ) do
    path = path_field |> :binary.split(<<0>>) |> hd()
    record = %IntegrityRecord{index: index, path: path, size: size, md5: md5, group: group}
    decode_records(rest, index + 1, [record | records])
  end

  defp encode_record(%IntegrityRecord{} = record) do
    path = record.path
    padding = 64 - byte_size(path)

    if padding < 1 do
      raise ArgumentError, "finfolist path must fit in 63 bytes"
    end

    <<path::binary, 0::size(padding)-unit(8), record.size::little-unsigned-32,
      record.md5::bytes-16, record.group::little-unsigned-32>>
  end
end
