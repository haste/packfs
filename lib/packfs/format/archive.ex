defmodule Packfs.Format.Archive do
  @moduledoc "Streaming access to headerless PackFS archive payloads."

  import Bitwise

  alias Packfs.Format.Cipher
  alias Packfs.Format.FileRecord

  @alignment 512
  @chunk_size 1_048_576
  @padding_byte 0x20

  @spec path(Path.t(), non_neg_integer()) :: Path.t()
  def path(data_root, archive_id) do
    directory = archive_id |> div(30) |> pad(3)
    filename = pad(archive_id, 4)
    Path.join([data_root, "pack", "d#{directory}", "pack#{filename}.pak"])
  end

  @spec virtual_path(non_neg_integer()) :: String.t()
  def virtual_path(archive_id) do
    directory = archive_id |> div(30) |> pad(3)
    filename = pad(archive_id, 4)
    "/data/pack/d#{directory}/pack#{filename}.pak"
  end

  @spec align(non_neg_integer()) :: non_neg_integer()
  def align(value), do: band(value + @alignment - 1, -@alignment)

  @spec padding(non_neg_integer()) :: binary()
  def padding(size), do: :binary.copy(<<@padding_byte>>, size)

  @spec padding_valid?(File.io_device(), non_neg_integer(), non_neg_integer()) ::
          {:ok, boolean()} | {:error, term()}
  def padding_valid?(_stream, _offset, 0), do: {:ok, true}

  def padding_valid?(stream, offset, size) do
    with {:ok, ^offset} <- :file.position(stream, offset),
         data when is_binary(data) <- IO.binread(stream, size) do
      {:ok, data == padding(size)}
    else
      :eof -> {:error, :unexpected_eof}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec payload_digests(Path.t(), FileRecord.t()) ::
          {:ok, binary(), binary()} | {:error, term()}
  def payload_digests(data_root, %FileRecord{} = record) do
    archive_path = path(data_root, record.archive_id)

    case File.open(archive_path, [:read, :binary, :raw], &digest_open_payload(&1, record)) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @spec payload_digest(Path.t(), FileRecord.t(), :raw | :xor) ::
          {:ok, binary()} | {:error, term()}
  def payload_digest(data_root, %FileRecord{} = record, mode) do
    case payload_digests(data_root, record) do
      {:ok, raw, _xor} when mode == :raw -> {:ok, raw}
      {:ok, _raw, xor} when mode == :xor -> {:ok, xor}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec extract(File.io_device(), File.io_device(), FileRecord.t(), :raw | :xor) ::
          {:ok, binary()} | {:error, term()}
  def extract(archive, destination, %FileRecord{} = record, mode) do
    initial = {Cipher.initial_state(record.crc32, record.crc16), md5()}

    with :ok <- seek(archive, record.offset),
         {:ok, {_cipher, payload_md5}} <-
           reduce_exact(archive, record.size, initial, fn data, state ->
             copy_data(data, state, destination, record.crc16, mode)
           end) do
      {:ok, :crypto.hash_final(payload_md5)}
    end
  end

  @spec write_plaintext(
          File.io_device(),
          File.io_device(),
          FileRecord.t(),
          :raw | :xor,
          term()
        ) :: {:ok, binary(), non_neg_integer(), term()} | {:error, term()}
  def write_plaintext(source, archive, %FileRecord{} = record, mode, archive_md5) do
    initial = {Cipher.initial_state(record.crc32, record.crc16), md5(), archive_md5, 0}

    with {:ok, {_cipher, payload_md5, updated_archive_md5, size}} <-
           reduce_to_eof(source, initial, fn data, state ->
             write_plaintext_data(data, state, archive, record.crc16, mode)
           end) do
      {:ok, :crypto.hash_final(payload_md5), size, updated_archive_md5}
    end
  end

  @spec write_padding(File.io_device(), non_neg_integer(), term()) ::
          {:ok, term()} | {:error, term()}
  def write_padding(_archive, 0, archive_md5), do: {:ok, archive_md5}

  def write_padding(archive, size, archive_md5) do
    data = padding(size)

    case :file.write(archive, data) do
      :ok -> {:ok, :crypto.hash_update(archive_md5, data)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec md5() :: term()
  def md5, do: :crypto.hash_init(:md5)

  ###
  ### Helpers
  ###

  defp digest_open_payload(stream, record) do
    initial = {Cipher.initial_state(record.crc32, record.crc16), md5(), md5()}

    with :ok <- seek(stream, record.offset),
         {:ok, {_cipher, raw_md5, xor_md5}} <-
           reduce_exact(stream, record.size, initial, fn data, state ->
             digest_data(data, state, record.crc16)
           end) do
      {:ok, :crypto.hash_final(raw_md5), :crypto.hash_final(xor_md5)}
    end
  end

  defp digest_data(data, {cipher, raw_md5, xor_md5}, crc16) do
    {decoded, next_cipher} = Cipher.transform(data, crc16, cipher)

    {:ok,
     {next_cipher, :crypto.hash_update(raw_md5, data), :crypto.hash_update(xor_md5, decoded)}}
  end

  defp copy_data(data, {cipher, payload_md5}, destination, crc16, mode) do
    {output, next_cipher} = transform(data, crc16, cipher, mode)

    case :file.write(destination, output) do
      :ok -> {:ok, {next_cipher, :crypto.hash_update(payload_md5, output)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_plaintext_data(
         data,
         {cipher, payload_md5, archive_md5, size},
         archive,
         crc16,
         mode
       ) do
    {output, next_cipher} = transform(data, crc16, cipher, mode)

    case :file.write(archive, output) do
      :ok ->
        {:ok,
         {next_cipher, :crypto.hash_update(payload_md5, data),
          :crypto.hash_update(archive_md5, output), size + byte_size(data)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reduce_exact(_stream, 0, state, _reducer), do: {:ok, state}

  defp reduce_exact(stream, remaining, state, reducer) do
    amount = min(remaining, @chunk_size)

    case IO.binread(stream, amount) do
      data when is_binary(data) and byte_size(data) == amount ->
        with {:ok, updated} <- reducer.(data, state) do
          reduce_exact(stream, remaining - amount, updated, reducer)
        end

      :eof ->
        {:error, :unexpected_eof}

      {:error, reason} ->
        {:error, reason}

      data when is_binary(data) ->
        {:error, {:short_read, amount, byte_size(data)}}
    end
  end

  defp reduce_to_eof(stream, state, reducer) do
    case IO.binread(stream, @chunk_size) do
      :eof ->
        {:ok, state}

      {:error, reason} ->
        {:error, reason}

      data when is_binary(data) ->
        with {:ok, updated} <- reducer.(data, state) do
          reduce_to_eof(stream, updated, reducer)
        end
    end
  end

  defp seek(stream, offset) do
    case :file.position(stream, offset) do
      {:ok, ^offset} -> :ok
      {:ok, actual} -> {:error, {:unexpected_position, offset, actual}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp transform(data, _crc16, state, :raw), do: {data, state}
  defp transform(data, crc16, state, :xor), do: Cipher.transform(data, crc16, state)

  defp pad(value, width) do
    value |> Integer.to_string() |> String.pad_leading(width, "0")
  end
end
