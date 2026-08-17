defmodule Packfs.CliTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Packfs.Format.DataSet
  alias Packfs.Format.Unpacker
  alias Packfs.Format.Workspace
  alias Packfs.TestFixture

  @tag :tmp_dir
  test "inspect emits built-in JSON output", %{tmp_dir: temporary} do
    source = Path.join(temporary, "source")
    TestFixture.create_data_set(source, :raw)

    output =
      capture_io(fn ->
        assert Packfs.Cli.run([
                 "inspect",
                 source,
                 "--pack",
                 "0",
                 "--cipher",
                 "raw",
                 "--json"
               ]) == 0
      end)

    assert {:ok, report} = JSON.decode(output)
    assert report["type"] == "packed"
    assert report["summary"]["cipher_mode"] == "raw"
    assert report["validation"]["valid"]
  end

  test "invalid arguments use the command-line error exit status" do
    output =
      capture_io(:stderr, fn ->
        assert Packfs.Cli.run(["verify"]) == 2
      end)

    assert output =~ "missing required arguments: TARGET"
  end

  test "unpack rejects a non-positive worker count" do
    output =
      capture_io(:stderr, fn ->
        assert Packfs.Cli.run(["unpack", "source", "output", "--jobs", "0"]) == 2
      end)

    assert output =~ "expected a positive integer"
  end

  @tag :tmp_dir
  test "add registers files and status reports them", %{tmp_dir: temporary} do
    source = Path.join(temporary, "source")
    workspace = Path.join(temporary, "workspace")
    addition = Path.join(temporary, "addition.bin")
    fixture = TestFixture.create_data_set(source, :raw)
    File.write!(addition, "added")

    assert {:ok, data_set} = DataSet.load(source)
    assert {:ok, _result} = Unpacker.run(data_set, workspace, MapSet.new([0]), fixture.names)

    output =
      capture_io(fn ->
        assert Packfs.Cli.run([
                 "add",
                 workspace,
                 addition,
                 "--path",
                 "/data/new.bin"
               ]) == 0
      end)

    assert output == "Added /data/new.bin to archive 0.\n"

    status = capture_io(fn -> assert Packfs.Cli.run(["status", workspace]) == 0 end)
    assert status == "A files/data/new.bin\n"
    assert File.read!(Path.join([workspace, "files", "data", "new.bin"])) == "added"

    File.write!(Path.join([workspace, "files", "data", "test", "Case.BIN"]), "changed")
    File.rm!(Path.join([workspace, "files", "data", "aep", "gf_sample.bin"]))

    status = capture_io(fn -> assert Packfs.Cli.run(["status", workspace]) == 0 end)

    assert status ==
             "M files/data/test/Case.BIN\n" <>
               "D files/data/aep/gf_sample.bin\n" <>
               "A files/data/new.bin\n"
  end

  @tag :tmp_dir
  test "add persists final retained-update hash keys", %{tmp_dir: temporary} do
    source = Path.join(temporary, "source")
    workspace_path = Path.join(temporary, "workspace")
    addition = Path.join(temporary, "addition.bin")
    fixture = TestFixture.create_data_set(source, :raw)
    File.write!(addition, "added")

    assert {:ok, data_set} = DataSet.load(source)

    assert {:ok, _result} =
             Unpacker.run(data_set, workspace_path, MapSet.new([0]), fixture.names)

    first =
      [
        "add",
        workspace_path,
        addition,
        "--path",
        "/data/update-one.bin",
        "--update",
        "pre-update:d9ad63cb:059a",
        "--quiet"
      ]

    second =
      [
        "add",
        workspace_path,
        addition,
        "--path",
        "/data/update-two.bin",
        "--update",
        "pre-update:d9ad63cb:059a",
        "--quiet"
      ]

    capture_io(fn -> assert Packfs.Cli.run(first) == 0 end)
    capture_io(fn -> assert Packfs.Cli.run(second) == 0 end)

    assert {:ok, workspace} = Workspace.load(workspace_path)

    assert Enum.map(workspace.manifest.additions, & &1.update) == ["pre-update", "pre-update"]

    assert Enum.map(workspace.manifest.additions, &{&1.crc32, &1.crc16}) ==
             Enum.map(["/data/update-one.bin", "/data/update-two.bin"], fn path ->
               Packfs.Format.Path.hash(path, 0xD9AD63CB, 0x059A)
             end)
  end

  test "reports the application version" do
    expected = :packfs |> Application.spec(:vsn) |> to_string()

    output =
      capture_io(fn ->
        assert Packfs.Cli.run(["--version"]) == 0
      end)

    assert output =~ expected
  end
end
