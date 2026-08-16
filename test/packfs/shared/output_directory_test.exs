defmodule Packfs.Shared.OutputDirectoryTest do
  use ExUnit.Case, async: true

  alias Packfs.Shared.OutputDirectory

  @tag :tmp_dir
  test "accepts an existing empty directory", %{tmp_dir: temporary} do
    output = Path.join(temporary, "output")
    File.mkdir_p!(output)

    assert :ok = OutputDirectory.prepare(output, false)
  end

  @tag :tmp_dir
  test "requires force for a non-empty directory", %{tmp_dir: temporary} do
    output = Path.join(temporary, "output")
    File.mkdir_p!(output)
    File.write!(Path.join(output, "existing"), "keep")

    assert {:error, :enotempty} = OutputDirectory.prepare(output, false)
    assert :ok = OutputDirectory.prepare(output, true)
    assert File.read!(Path.join(output, "existing")) == "keep"
  end
end
