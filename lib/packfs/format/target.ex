defmodule Packfs.Format.Target do
  @moduledoc "A packed data root or an extracted PackFS workspace."

  alias Packfs.Format.DataSet
  alias Packfs.Format.Error
  alias Packfs.Format.Workspace

  @enforce_keys [:kind, :data]
  defstruct @enforce_keys

  @type t :: %__MODULE__{kind: :packed | :workspace, data: DataSet.t() | Workspace.t()}

  @spec load(Path.t()) :: {:ok, t()} | {:error, Error.t()}
  def load(path) do
    root = Path.expand(path)
    manifest = Path.join(root, "packfs-manifest.json")
    pack_info = Path.join([root, "pack", "packinfo.bin"])

    load_detected(root, File.regular?(manifest), File.regular?(pack_info))
  end

  ###
  ### Helpers
  ###

  defp load_detected(root, true, _packed?) do
    case Workspace.load(root) do
      {:ok, workspace} -> {:ok, %__MODULE__{kind: :workspace, data: workspace}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_detected(root, false, true) do
    case DataSet.load(root) do
      {:ok, data_set} -> {:ok, %__MODULE__{kind: :packed, data: data_set}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_detected(root, false, false) do
    {:error,
     %Error{
       message: "neither packfs-manifest.json nor pack/packinfo.bin exists",
       context: root
     }}
  end
end
