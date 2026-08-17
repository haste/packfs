defmodule Packfs.Format.ManifestTest do
  use ExUnit.Case, async: true

  alias Packfs.Format.Manifest
  alias Packfs.Format.Manifest.Addition

  test "uses the tool-owned workspace identifier" do
    json =
      JSON.encode!(%{
        "format" => "packfs-workspace-v1",
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
        "cipher_mode" => "xor",
        "packs" => [],
        "files" => []
      })

    assert {:error, error} = Manifest.decode(json)
    assert Exception.message(error) =~ "unsupported extraction manifest format"
  end

  test "round-trips registered additions with final hash keys" do
    manifest = %Manifest{
      cipher_mode: :xor,
      packs: [3],
      files: [],
      additions: [
        %Addition{
          stored_path: "updates/pre-update/data/new.bin",
          path: "/data/new.bin",
          archive_id: 3,
          crc32: 0x12345678,
          crc16: 0x9ABC,
          update: "pre-update"
        }
      ]
    }

    assert {:ok, ^manifest} = manifest |> Manifest.encode() |> Manifest.decode()
  end
end
