defmodule Packfs.TestFixture do
  @moduledoc false

  alias Packfs.Format.Archive
  alias Packfs.Format.Cipher
  alias Packfs.Format.FileRecord
  alias Packfs.Format.Finfolist
  alias Packfs.Format.IntegrityRecord
  alias Packfs.Format.PackInfo
  alias Packfs.Format.Path, as: VirtualPath

  @current_magic 0x20110201

  @spec create_data_set(Path.t(), :raw | :xor) :: map()
  def create_data_set(root, cipher_mode) do
    files = [
      {"/data/test/Case.BIN", "seven!!"},
      {"/data/aep/GF_SAMPLE.BIN", :binary.copy(<<0xA5>>, 519)}
    ]

    sorted = Enum.sort_by(files, fn {path, _contents} -> VirtualPath.hash(path) end)
    {archive, records} = build_archive(sorted, cipher_mode)
    archive_md5 = :crypto.hash(:md5, archive)
    pack_info = pack_info(records, archive_md5)
    finfolist = finfolist(byte_size(archive), archive_md5)

    archive_path = Archive.path(root, 0)
    File.mkdir_p!(Path.dirname(archive_path))
    File.write!(archive_path, archive)
    File.write!(Path.join([root, "pack", "packinfo.bin"]), PackInfo.encode(pack_info))
    File.write!(Path.join(root, "finfolist.bin"), Finfolist.encode(finfolist))

    %{
      root: root,
      files: Map.new(files),
      names: Map.new(records, &{{&1.crc32, &1.crc16}, path_for(&1, sorted)}),
      records: records
    }
  end

  ###
  ### Helpers
  ###

  defp build_archive(files, cipher_mode) do
    initial = %{parts: [], position: 0, records: []}

    final =
      files
      |> Enum.with_index()
      |> Enum.reduce(initial, fn {{path, contents}, index}, state ->
        add_payload(state, path, contents, index, cipher_mode)
      end)

    archive = final.parts |> Enum.reverse() |> IO.iodata_to_binary()
    {archive, Enum.reverse(final.records)}
  end

  defp add_payload(state, path, contents, index, cipher_mode) do
    offset = Archive.align(state.position)
    padding = Archive.padding(offset - state.position)
    {crc32, crc16} = VirtualPath.hash(path)
    stored = stored_payload(contents, crc32, crc16, cipher_mode)

    record = %FileRecord{
      index: index,
      md5: :crypto.hash(:md5, contents),
      crc32: crc32,
      crc16: crc16,
      archive_id: 0,
      offset: offset,
      size: byte_size(contents)
    }

    %{
      parts: [stored, padding | state.parts],
      position: offset + byte_size(contents),
      records: [record | state.records]
    }
  end

  defp stored_payload(contents, _crc32, _crc16, :raw), do: contents

  defp stored_payload(contents, crc32, crc16, :xor) do
    state = Cipher.initial_state(crc32, crc16)
    {stored, _state} = Cipher.transform(contents, crc16, state)
    stored
  end

  defp pack_info(records, archive_md5) do
    file_count = length(records)
    archive_offset = 16 + file_count * 32
    raw = :binary.copy(<<0>>, archive_offset + 16)

    %PackInfo{
      magic: @current_magic,
      file_table_offset: 16,
      archive_table_offset: archive_offset,
      file_count: file_count,
      archive_count: 1,
      records: records,
      archive_md5s: [archive_md5],
      raw: raw
    }
  end

  defp finfolist(size, archive_md5) do
    record = %IntegrityRecord{
      index: 0,
      path: Archive.virtual_path(0),
      size: size,
      md5: archive_md5,
      group: 0
    }

    %Finfolist{records: [record], raw: <<>>}
  end

  defp path_for(record, files) do
    Enum.find_value(files, fn {path, _contents} ->
      if VirtualPath.hash(path) == {record.crc32, record.crc16}, do: VirtualPath.normalize(path)
    end)
  end
end
