defmodule Packfs.Format.WorkflowTest do
  use ExUnit.Case, async: true

  alias Packfs.Format.Archive
  alias Packfs.Format.DataSet
  alias Packfs.Format.Finfolist
  alias Packfs.Format.PackInfo
  alias Packfs.Format.Repacker
  alias Packfs.Format.Unpacker
  alias Packfs.Format.Validation
  alias Packfs.Format.Verifier
  alias Packfs.Format.Workspace
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
end
