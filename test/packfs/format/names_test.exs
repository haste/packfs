defmodule Packfs.Format.NamesTest do
  use ExUnit.Case, async: true

  alias Packfs.Format.FileRecord
  alias Packfs.Format.Names
  alias Packfs.Format.Path, as: VirtualPath
  alias Packfs.Format.ResolvedName

  @tag :tmp_dir
  test "resolves a name through a custom update CRC", %{tmp_dir: temporary} do
    path = "/data/aep/h44_common.bin"
    name_file = Path.join(temporary, "names.txt")
    File.write!(name_file, path <> "\n")

    update = %{name: "pre-update", crc32_init: 0xD9AD63CB, crc16_init: 0x059A}
    {crc32, crc16} = VirtualPath.hash(path, update.crc32_init, update.crc16_init)

    record = %FileRecord{
      index: 0,
      md5: :crypto.hash(:md5, ""),
      crc32: crc32,
      crc16: crc16,
      archive_id: 0,
      offset: 0,
      size: 0
    }

    assert {:ok, %{paths: paths, warnings: []}} =
             Names.resolve([record], [], [name_file], [update])

    assert paths[{crc32, crc16}] == %ResolvedName{path: path, update: "pre-update"}
  end
end
