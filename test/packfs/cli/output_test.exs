defmodule Packfs.Cli.OutputTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Packfs.Cli.Output
  alias Packfs.Format.RepackResult
  alias Packfs.Format.UnpackResult

  test "unpack prints a concise summary" do
    result = %UnpackResult{
      archives: 85,
      files: 575,
      bytes: 545_486_740,
      resolved: 0,
      unresolved: 575,
      updates: %{},
      warnings: [],
      cipher_mode: :raw
    }

    assert capture_io(fn -> Output.unpack(result) end) ==
             "Unpacked 575 files from 85 archives (520.2 MiB, raw).\n" <>
               "Paths: 0 resolved, 575 unresolved.\n"
  end

  test "repack prints a concise summary" do
    result = %RepackResult{
      archives: 85,
      files: 575,
      bytes: 545_486_740,
      cipher_mode: :raw
    }

    assert capture_io(fn -> Output.repack(result) end) ==
             "Repacked 575 files into 85 archives (520.2 MiB, raw).\n"
  end

  test "unpack reports named update overlays" do
    result = %UnpackResult{
      archives: 1,
      files: 3,
      bytes: 100,
      resolved: 3,
      unresolved: 0,
      updates: %{"pre-update" => 2},
      warnings: [],
      cipher_mode: :raw
    }

    assert capture_io(fn -> Output.unpack(result) end) =~ "Update pre-update: 2 files.\n"
  end
end
