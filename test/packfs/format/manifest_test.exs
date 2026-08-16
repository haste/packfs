defmodule Packfs.Format.ManifestTest do
  use ExUnit.Case, async: true

  alias Packfs.Format.Manifest

  test "uses the tool-owned workspace identifier" do
    json =
      JSON.encode!(%{
        "format" => "packfs-workspace-v1",
        "source_data_root" => nil,
        "cipher_mode" => "raw",
        "packs" => [],
        "files" => []
      })

    assert {:ok, %Manifest{cipher_mode: :raw}} = Manifest.decode(json)
  end

  test "rejects the Python proof-of-concept identifiers" do
    json =
      JSON.encode!(%{
        "format" => "gfdm-v8-packfs-extract-v2",
        "source_data_root" => nil,
        "cipher_mode" => "xor",
        "packs" => [],
        "files" => []
      })

    assert {:error, error} = Manifest.decode(json)
    assert Exception.message(error) =~ "unsupported extraction manifest format"
  end
end
