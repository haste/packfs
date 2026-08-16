defmodule Packfs.Format.Workspace do
  @moduledoc "A loaded unpacked PackFS extraction workspace."

  alias Packfs.Format.Error
  alias Packfs.Format.Finfolist
  alias Packfs.Format.Manifest
  alias Packfs.Format.PackInfo
  alias Packfs.Shared.FileOps

  @context "extraction workspace"

  @enforce_keys [:root, :manifest, :pack_info, :finfolist]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          root: Path.t(),
          manifest: Manifest.t(),
          pack_info: PackInfo.t(),
          finfolist: Finfolist.t() | nil
        }

  @spec load(Path.t()) :: {:ok, t()} | {:error, Error.t()}
  def load(root) do
    expanded = Path.expand(root)

    with {:ok, manifest_binary} <-
           FileOps.read(Path.join(expanded, "packfs-manifest.json"), @context),
         {:ok, manifest} <- Manifest.decode(manifest_binary),
         {:ok, pack_info_binary} <-
           FileOps.read(Path.join([expanded, "original", "packinfo.bin"]), @context),
         {:ok, pack_info} <- PackInfo.decode(pack_info_binary),
         {:ok, finfolist} <-
           FileOps.read_optional(
             Path.join([expanded, "original", "finfolist.bin"]),
             &Finfolist.decode/1,
             @context
           ) do
      {:ok,
       %__MODULE__{
         root: expanded,
         manifest: manifest,
         pack_info: pack_info,
         finfolist: finfolist
       }}
    end
  end
end
