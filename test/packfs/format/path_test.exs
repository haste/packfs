defmodule Packfs.Format.PathTest do
  use ExUnit.Case, async: true

  alias Packfs.Format.Path, as: VirtualPath

  test "matches the documented double-hash vector" do
    path = "/data/product/font/font16x16x8/0_0.img"
    assert VirtualPath.hash(path) == {0x6CDF6A53, 0x90DD}
  end

  test "normalizes only the prefixes used by the retail lookup" do
    assert VirtualPath.normalize("DaTa/product/File.BIN") == "/DaTa/product/File.BIN"
    assert VirtualPath.normalize("/DATA/AEP/GF_TEST.BIN") == "/data/aep/gf_test.bin"
    assert VirtualPath.normalize("/data/product/File.BIN") == "/data/product/File.BIN"

    refute VirtualPath.hash("/data/product/File.BIN") ==
             VirtualPath.hash("/data/product/file.bin")
  end
end
