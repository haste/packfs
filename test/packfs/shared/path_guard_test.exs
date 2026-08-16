defmodule Packfs.Shared.PathGuardTest do
  use ExUnit.Case, async: true

  alias Packfs.Shared.PathGuard

  @tag :tmp_dir
  test "rejects traversal and symlink destinations", %{tmp_dir: temporary} do
    File.mkdir_p!(Path.join(temporary, "inside"))
    File.ln_s!(temporary, Path.join(temporary, "inside/link"))

    assert {:error, _message} = PathGuard.join(temporary, "../outside")
    assert {:error, _message} = PathGuard.join(temporary, "/absolute")
    assert {:error, _message} = PathGuard.join(temporary, "inside/link/file.bin")
    assert {:ok, _path} = PathGuard.join(temporary, "inside/file.bin")
  end
end
