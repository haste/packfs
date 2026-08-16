defmodule Packfs.Format.ArchiveTest do
  use ExUnit.Case, async: true

  alias Packfs.Format.Archive
  alias Packfs.Format.Cipher
  alias Packfs.Format.FileRecord

  @chunk_size 1_048_576

  @tag :tmp_dir
  test "streams XOR payloads across chunk boundaries", %{tmp_dir: temporary} do
    contents = :binary.copy(<<0, 1, 2, 3>>, div(@chunk_size, 4)) <> <<4, 5, 6>>
    record = record(byte_size(contents))
    cipher = Cipher.initial_state(record.crc32, record.crc16)
    {stored, _cipher} = Cipher.transform(contents, record.crc16, cipher)
    archive_path = Archive.path(temporary, 0)
    source_path = Path.join(temporary, "source.bin")
    extracted_path = Path.join(temporary, "extracted.bin")

    File.mkdir_p!(Path.dirname(archive_path))
    File.write!(source_path, contents)

    source = File.open!(source_path, [:read, :binary, :raw])
    archive = File.open!(archive_path, [:write, :binary, :raw])

    assert {:ok, payload_md5, size, archive_md5} =
             Archive.write_plaintext(source, archive, record, :xor, Archive.md5())

    File.close(source)
    File.close(archive)

    assert payload_md5 == :crypto.hash(:md5, contents)
    assert size == byte_size(contents)
    assert :crypto.hash_final(archive_md5) == :crypto.hash(:md5, stored)
    assert File.read!(archive_path) == stored

    assert {:ok, raw_md5, xor_md5} = Archive.payload_digests(temporary, record)
    assert raw_md5 == :crypto.hash(:md5, stored)
    assert xor_md5 == :crypto.hash(:md5, contents)

    archive = File.open!(archive_path, [:read, :binary, :raw])
    extracted = File.open!(extracted_path, [:write, :binary, :raw])
    assert {:ok, ^payload_md5} = Archive.extract(archive, extracted, record, :xor)
    File.close(archive)
    File.close(extracted)

    assert File.read!(extracted_path) == contents
  end

  @tag :tmp_dir
  test "hashes archive padding and stored payload while extracting", %{tmp_dir: temporary} do
    contents = "decoded payload"
    padding = "pad"
    record = %{record(byte_size(contents)) | offset: byte_size(padding)}
    cipher = Cipher.initial_state(record.crc32, record.crc16)
    {stored, _cipher} = Cipher.transform(contents, record.crc16, cipher)
    archive_contents = padding <> stored
    archive_path = Archive.path(temporary, 0)
    extracted_path = Path.join(temporary, "extracted.bin")

    File.mkdir_p!(Path.dirname(archive_path))
    File.write!(archive_path, archive_contents)

    archive = File.open!(archive_path, [:read, :binary, :raw])
    extracted = File.open!(extracted_path, [:write, :binary, :raw])

    assert {:ok, payload_md5, archive_md5, position} =
             Archive.extract_and_hash(archive, extracted, record, :xor, Archive.md5(), 0)

    File.close(archive)
    File.close(extracted)

    assert payload_md5 == :crypto.hash(:md5, contents)
    assert :crypto.hash_final(archive_md5) == :crypto.hash(:md5, archive_contents)
    assert position == byte_size(archive_contents)
    assert File.read!(extracted_path) == contents
  end

  @tag :tmp_dir
  test "reports short payload reads without writing partial output", %{tmp_dir: temporary} do
    archive_path = Archive.path(temporary, 0)
    extracted_path = Path.join(temporary, "extracted.bin")
    File.mkdir_p!(Path.dirname(archive_path))
    File.write!(archive_path, "abc")
    record = record(5)

    assert {:error, {:short_read, 5, 3}} = Archive.payload_digest(temporary, record, :raw)

    archive = File.open!(archive_path, [:read, :binary, :raw])
    extracted = File.open!(extracted_path, [:write, :binary, :raw])
    assert {:error, {:short_read, 5, 3}} = Archive.extract(archive, extracted, record, :raw)
    File.close(archive)
    File.close(extracted)

    assert File.read!(extracted_path) == ""
  end

  @tag :tmp_dir
  test "returns destination write errors", %{tmp_dir: temporary} do
    archive_path = Archive.path(temporary, 0)
    destination_path = Path.join(temporary, "destination.bin")
    File.mkdir_p!(Path.dirname(archive_path))
    File.write!(archive_path, "abc")
    File.write!(destination_path, "")

    archive = File.open!(archive_path, [:read, :binary, :raw])
    destination = File.open!(destination_path, [:read, :binary, :raw])
    assert {:error, :ebadf} = Archive.extract(archive, destination, record(3), :raw)
    File.close(archive)
    File.close(destination)
  end

  defp record(size) do
    %FileRecord{
      index: 0,
      md5: :crypto.hash(:md5, ""),
      crc32: 0x6CDF6A53,
      crc16: 0x90DD,
      archive_id: 0,
      offset: 0,
      size: size
    }
  end
end
