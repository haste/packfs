defmodule Packfs.Format.DataSet do
  @moduledoc "A loaded packed PackFS data root."

  alias Packfs.Format.Archive
  alias Packfs.Format.Error
  alias Packfs.Format.Finfolist
  alias Packfs.Format.PackInfo
  alias Packfs.Shared.FileOps

  @context "packed data set"

  @enforce_keys [:root, :pack_info, :finfolist]
  defstruct @enforce_keys

  @type cipher_mode :: :raw | :xor
  @type t :: %__MODULE__{root: Path.t(), pack_info: PackInfo.t(), finfolist: Finfolist.t() | nil}

  @spec load(Path.t()) :: {:ok, t()} | {:error, Error.t()}
  def load(root) do
    expanded = Path.expand(root)

    with {:ok, pack_info_binary} <-
           FileOps.read(Path.join([expanded, "pack", "packinfo.bin"]), @context),
         {:ok, pack_info} <- PackInfo.decode(pack_info_binary),
         {:ok, finfolist} <-
           FileOps.read_optional(
             Path.join(expanded, "finfolist.bin"),
             &Finfolist.decode/1,
             @context
           ) do
      {:ok, %__MODULE__{root: expanded, pack_info: pack_info, finfolist: finfolist}}
    end
  end

  @spec cipher_mode(t(), :auto | cipher_mode()) ::
          {:ok, cipher_mode()} | {:error, Error.t()}
  def cipher_mode(_data_set, mode) when mode in [:raw, :xor], do: {:ok, mode}

  def cipher_mode(%__MODULE__{} = data_set, :auto) do
    candidates = Enum.sort_by(data_set.pack_info.records, &sample_order/1)

    detect(candidates, data_set.root, %{raw: 0, xor: 0, mismatches: 0, unreadable: 0})
  end

  ###
  ### Helpers
  ###

  defp detect([], _root, counts), do: detection_result(counts)

  defp detect([%{size: 0} | records], root, counts) do
    detect(records, root, counts)
  end

  defp detect([record | records], root, counts) do
    root
    |> sample(record, counts)
    |> continue_detection(records, root)
  end

  defp sample(root, record, counts) do
    case Archive.payload_digests(root, record) do
      {:ok, raw, xor} -> count_sample(raw, xor, record.md5, counts)
      {:error, _reason} -> Map.update!(counts, :unreadable, &(&1 + 1))
    end
  end

  defp count_sample(md5, xor, md5, counts) when xor != md5 do
    Map.update!(counts, :raw, &(&1 + 1))
  end

  defp count_sample(raw, md5, md5, counts) when raw != md5 do
    Map.update!(counts, :xor, &(&1 + 1))
  end

  defp count_sample(md5, md5, md5, counts), do: counts

  defp count_sample(_raw, _xor, _md5, counts) do
    Map.update!(counts, :mismatches, &(&1 + 1))
  end

  defp continue_detection(%{raw: raw, xor: xor}, _records, _root) when raw > 0 and xor > 0 do
    {:error, error("auto-detection found both raw and XOR-matching payloads")}
  end

  defp continue_detection(%{raw: raw}, _records, _root) when raw >= 3, do: {:ok, :raw}
  defp continue_detection(%{xor: xor}, _records, _root) when xor >= 3, do: {:ok, :xor}

  defp continue_detection(%{raw: raw, xor: xor, mismatches: mismatches} = counts, _records, _root)
       when raw + xor + mismatches >= 16 do
    detection_result(counts)
  end

  defp continue_detection(counts, records, root), do: detect(records, root, counts)

  defp detection_result(%{raw: raw}) when raw > 0, do: {:ok, :raw}
  defp detection_result(%{xor: xor}) when xor > 0, do: {:ok, :xor}

  defp detection_result(counts) do
    {:error,
     error(
       "cannot auto-detect payload storage " <>
         "(#{counts.mismatches} mismatched samples, #{counts.unreadable} unreadable)"
     )}
  end

  defp sample_order(%{size: size, index: index}) when size < 4 do
    {1, size, index}
  end

  defp sample_order(%{size: size, index: index}), do: {0, size, index}

  defp error(message), do: %Error{message: message, context: @context}
end
