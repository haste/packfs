defmodule Packfs.CliTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

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

  test "reports the application version" do
    expected = :packfs |> Application.spec(:vsn) |> to_string()

    output =
      capture_io(fn ->
        assert Packfs.Cli.run(["--version"]) == 0
      end)

    assert output =~ expected
  end
end
