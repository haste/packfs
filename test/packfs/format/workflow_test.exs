defmodule Packfs.Format.WorkflowTest do
  use ExUnit.Case, async: true

  alias Packfs.Format.Archive
  alias Packfs.Format.DataSet
  alias Packfs.Format.Finfolist
  alias Packfs.Format.Manifest
  alias Packfs.Format.PackInfo
  alias Packfs.Format.Path, as: VirtualPath
  alias Packfs.Format.Repacker
  alias Packfs.Format.ResolvedName
  alias Packfs.Format.Unpacker
  alias Packfs.Format.Validation
  alias Packfs.Format.Verifier
  alias Packfs.Format.Workspace
  alias Packfs.Format.WorkspaceAdder
  alias Packfs.Format.WorkspaceVerifier
  alias Packfs.TestFixture

  @tag :tmp_dir
  test "unchanged XOR workspaces rebuild byte-for-byte", %{tmp_dir: temporary} do
    source = Path.join(temporary, "source")
    workspace_path = Path.join(temporary, "workspace")
    rebuilt = Path.join(temporary, "rebuilt")
    fixture = TestFixture.create_data_set(source, :xor)
    File.mkdir_p!(workspace_path)

    assert {:ok, data_set} = DataSet.load(source)
    assert {:ok, result} = Unpacker.run(data_set, workspace_path, MapSet.new([0]), fixture.names)
    assert result.cipher_mode == :xor
    assert result.files == 2
    assert result.resolved == 2

    assert {:ok, workspace} = Workspace.load(workspace_path)
    assert WorkspaceVerifier.verify(workspace, files: true) |> Validation.valid?()
    File.mkdir_p!(rebuilt)
    assert {:ok, _result} = Repacker.run(workspace, rebuilt)

    assert File.read!(Archive.path(rebuilt, 0)) == File.read!(Archive.path(source, 0))

    assert File.read!(Path.join([rebuilt, "pack", "packinfo.bin"])) ==
             File.read!(Path.join([source, "pack", "packinfo.bin"]))

    assert File.read!(Path.join(rebuilt, "finfolist.bin")) ==
             File.read!(Path.join(source, "finfolist.bin"))
  end

  @tag :tmp_dir
  test "unpack verifies the stored archive digest during extraction", %{tmp_dir: temporary} do
    source = Path.join(temporary, "source")
    workspace_path = Path.join(temporary, "workspace")
    fixture = TestFixture.create_data_set(source, :raw)
    assert {:ok, data_set} = DataSet.load(source)

    pack_info = %{data_set.pack_info | archive_md5s: [:binary.copy(<<0>>, 16)]}
    bad_index = %{data_set | pack_info: pack_info}

    assert {:error, error} =
             Unpacker.run(bad_index, workspace_path, MapSet.new([0]), fixture.names,
               cipher: :raw,
               verify_archives: true
             )

    assert Exception.message(error) =~ "archive 0: MD5 mismatch"
  end

  @tag :tmp_dir
  test "archives unpack concurrently without changing manifest order", %{tmp_dir: temporary} do
    source = Path.join(temporary, "source")
    workspace_path = Path.join(temporary, "workspace")
    fixture = TestFixture.create_data_set(source, :xor)
    assert {:ok, data_set} = DataSet.load(source)

    [first, second] = Enum.sort_by(fixture.records, & &1.offset)
    original_archive = File.read!(Archive.path(source, 0))
    first_payload = binary_part(original_archive, first.offset, first.size)
    second_payload = binary_part(original_archive, second.offset, second.size)

    File.write!(Archive.path(source, 0), first_payload)
    File.write!(Archive.path(source, 1), second_payload)

    records =
      Enum.map(data_set.pack_info.records, fn
        %{index: index} = record when index == second.index ->
          %{record | archive_id: 1, offset: 0}

        record ->
          record
      end)

    pack_info = %{data_set.pack_info | records: records}
    concurrent_data_set = %{data_set | pack_info: pack_info}

    assert {:ok, result} =
             Unpacker.run(
               concurrent_data_set,
               workspace_path,
               MapSet.new([0, 1]),
               fixture.names,
               cipher: :xor,
               jobs: 2
             )

    assert result.files == 2
    assert result.bytes == first.size + second.size

    manifest_path = Path.join(workspace_path, "packfs-manifest.json")
    assert {:ok, manifest} = manifest_path |> File.read!() |> Manifest.decode()
    assert Enum.map(manifest.files, & &1.record) == [first.index, second.index]
  end

  @tag :tmp_dir
  test "changed files update sizes, offsets, and integrity digests", %{tmp_dir: temporary} do
    source = Path.join(temporary, "source")
    workspace_path = Path.join(temporary, "workspace")
    rebuilt = Path.join(temporary, "rebuilt")
    fixture = TestFixture.create_data_set(source, :raw)

    assert {:ok, data_set} = DataSet.load(source)
    assert {:ok, _result} = Unpacker.run(data_set, workspace_path, MapSet.new([0]), fixture.names)

    changed_path = Path.join([workspace_path, "files", "data", "test", "Case.BIN"])
    changed_contents = :binary.copy("changed", 100)
    File.write!(changed_path, changed_contents)

    assert {:ok, workspace} = Workspace.load(workspace_path)
    assert {:ok, _result} = Repacker.run(workspace, rebuilt)
    assert {:ok, rebuilt_data_set} = DataSet.load(rebuilt)

    validation =
      Verifier.verify(rebuilt_data_set, MapSet.new([0]),
        archives: true,
        files: true,
        cipher: :raw
      )

    assert Validation.valid?(validation)

    rebuilt_pack_info = Path.join([rebuilt, "pack", "packinfo.bin"])
    assert {:ok, rebuilt_info} = rebuilt_pack_info |> File.read!() |> PackInfo.decode()

    changed_record =
      Enum.find(rebuilt_info.records, fn record ->
        fixture.names[{record.crc32, record.crc16}] == "/data/test/Case.BIN"
      end)

    following_record =
      Enum.find(rebuilt_info.records, fn record ->
        fixture.names[{record.crc32, record.crc16}] == "/data/aep/gf_sample.bin"
      end)

    assert changed_record.size == 700
    assert changed_record.md5 == :crypto.hash(:md5, changed_contents)
    assert following_record.offset == 1024

    rebuilt_archive = File.read!(Archive.path(rebuilt, 0))
    rebuilt_archive_md5 = :crypto.hash(:md5, rebuilt_archive)
    assert Enum.fetch!(rebuilt_info.archive_md5s, 0) == rebuilt_archive_md5

    rebuilt_finfolist = Path.join(rebuilt, "finfolist.bin")
    assert {:ok, finfolist} = rebuilt_finfolist |> File.read!() |> Finfolist.decode()
    integrity_record = Enum.find(finfolist.records, &(&1.path == Archive.virtual_path(0)))

    assert integrity_record.size == byte_size(rebuilt_archive)
    assert integrity_record.md5 == rebuilt_archive_md5
  end

  @tag :tmp_dir
  test "new workspace files are added to the archive and file table", %{tmp_dir: temporary} do
    source = Path.join(temporary, "source")
    workspace_path = Path.join(temporary, "workspace")
    rebuilt = Path.join(temporary, "rebuilt")
    fixture = TestFixture.create_data_set(source, :xor)
    added_path = "/data/new/Added.BIN"
    added_contents = :binary.copy("new payload", 71)

    assert {:ok, data_set} = DataSet.load(source)
    assert {:ok, _result} = Unpacker.run(data_set, workspace_path, MapSet.new([0]), fixture.names)

    source_path = Path.join(temporary, "added.bin")
    File.write!(source_path, added_contents)

    assert {:ok, workspace} = Workspace.load(workspace_path)
    assert {:ok, _result} = WorkspaceAdder.run(workspace, source_path, added_path)
    assert {:ok, workspace} = Workspace.load(workspace_path)
    assert {:ok, result} = Repacker.run(workspace, rebuilt)
    assert result.files == 3
    assert {:ok, rebuilt_data_set} = DataSet.load(rebuilt)

    assert rebuilt_data_set.pack_info.file_count == 3
    assert [_, _, _] = rebuilt_data_set.pack_info.records

    keys = Enum.map(rebuilt_data_set.pack_info.records, &{&1.crc32, &1.crc16})
    assert keys == Enum.sort(keys)

    added_record =
      Enum.find(rebuilt_data_set.pack_info.records, fn record ->
        {record.crc32, record.crc16} == VirtualPath.hash(added_path)
      end)

    assert added_record.archive_id == 0
    assert added_record.size == byte_size(added_contents)
    assert added_record.md5 == :crypto.hash(:md5, added_contents)

    validation =
      Verifier.verify(rebuilt_data_set, MapSet.new([0]),
        archives: true,
        files: true,
        cipher: :xor
      )

    assert Validation.valid?(validation)
  end

  @tag :tmp_dir
  test "new retained-update files use supplied CRC definitions", %{tmp_dir: temporary} do
    source = Path.join(temporary, "source")
    workspace_path = Path.join(temporary, "workspace")
    rebuilt = Path.join(temporary, "rebuilt")
    fixture = TestFixture.create_data_set(source, :xor)
    update = %{name: "pre-update", crc32_init: 0xD9AD63CB, crc16_init: 0x059A}
    added_path = "/data/update/Added.BIN"
    added_contents = :binary.copy("retained update", 37)

    assert {:ok, data_set} = DataSet.load(source)

    assert {:ok, _result} = Unpacker.run(data_set, workspace_path, MapSet.new([0]), fixture.names)

    source_path = Path.join(temporary, "update-added.bin")
    File.write!(source_path, added_contents)

    assert {:ok, workspace} = Workspace.load(workspace_path)

    assert {:ok, _result} =
             WorkspaceAdder.run(workspace, source_path, added_path, update: update)

    assert {:ok, workspace} = Workspace.load(workspace_path)
    assert {:ok, result} = Repacker.run(workspace, rebuilt)
    assert result.files == 3
    assert {:ok, rebuilt_data_set} = DataSet.load(rebuilt)

    expected_hash = VirtualPath.hash(added_path, update.crc32_init, update.crc16_init)

    added_record =
      Enum.find(rebuilt_data_set.pack_info.records, fn record ->
        {record.crc32, record.crc16} == expected_hash
      end)

    assert added_record.size == byte_size(added_contents)
    assert added_record.md5 == :crypto.hash(:md5, added_contents)

    validation =
      Verifier.verify(rebuilt_data_set, MapSet.new([0]),
        archives: true,
        files: true,
        cipher: :xor
      )

    assert Validation.valid?(validation)
  end

  @tag :tmp_dir
  test "missing workspace files are removed from the archive and file table", %{
    tmp_dir: temporary
  } do
    source = Path.join(temporary, "source")
    workspace_path = Path.join(temporary, "workspace")
    rebuilt = Path.join(temporary, "rebuilt")
    fixture = TestFixture.create_data_set(source, :raw)
    deleted_path = "/data/aep/gf_sample.bin"

    assert {:ok, data_set} = DataSet.load(source)
    assert {:ok, _result} = Unpacker.run(data_set, workspace_path, MapSet.new([0]), fixture.names)

    File.rm!(Path.join([workspace_path, "files", "data", "aep", "gf_sample.bin"]))

    assert {:ok, workspace} = Workspace.load(workspace_path)
    assert {:ok, result} = Repacker.run(workspace, rebuilt)
    assert result.files == 1
    assert {:ok, rebuilt_data_set} = DataSet.load(rebuilt)

    assert rebuilt_data_set.pack_info.file_count == 1
    assert [_] = rebuilt_data_set.pack_info.records

    refute Enum.any?(rebuilt_data_set.pack_info.records, fn record ->
             {record.crc32, record.crc16} == VirtualPath.hash(deleted_path)
           end)

    validation =
      Verifier.verify(rebuilt_data_set, MapSet.new([0]),
        archives: true,
        files: true,
        cipher: :raw
      )

    assert Validation.valid?(validation)
  end

  @tag :tmp_dir
  test "retained update files unpack into a named overlay and rebuild byte-for-byte", %{
    tmp_dir: temporary
  } do
    source = Path.join(temporary, "source")
    workspace_path = Path.join(temporary, "workspace")
    rebuilt = Path.join(temporary, "rebuilt")
    fixture = TestFixture.create_data_set(source, :raw)
    {hash, path} = Enum.find(fixture.names, fn {_hash, path} -> path == "/data/test/Case.BIN" end)

    names = Map.put(fixture.names, hash, %ResolvedName{path: path, update: "pre-update"})

    assert {:ok, data_set} = DataSet.load(source)
    assert {:ok, result} = Unpacker.run(data_set, workspace_path, MapSet.new([0]), names)
    assert result.resolved == 2
    assert result.updates == %{"pre-update" => 1}

    updated_path =
      Path.join([workspace_path, "updates", "pre-update", String.trim_leading(path, "/")])

    assert File.read!(updated_path) == fixture.files[path]

    assert {:ok, workspace} = Workspace.load(workspace_path)
    assert WorkspaceVerifier.verify(workspace, files: true) |> Validation.valid?()
    assert {:ok, _result} = Repacker.run(workspace, rebuilt)

    assert File.read!(Archive.path(rebuilt, 0)) == File.read!(Archive.path(source, 0))
  end
end
