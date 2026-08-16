defmodule Packfs.Format.Manifest do
  @moduledoc "Codec for PackFS extraction workspace manifests."

  alias Packfs.Format.Error
  alias Packfs.Format.Manifest.Entry

  @format "packfs-workspace-v1"

  @enforce_keys [:source_data_root, :cipher_mode, :packs, :files]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          source_data_root: String.t() | nil,
          cipher_mode: :raw | :xor,
          packs: [non_neg_integer()],
          files: [Entry.t()]
        }

  @spec format() :: String.t()
  def format, do: @format

  @spec decode(binary()) :: {:ok, t()} | {:error, Error.t()}
  def decode(binary) do
    case JSON.decode(binary) do
      {:ok, value} -> decode_json(value)
      {:error, reason} -> {:error, error("invalid JSON: #{Exception.message(reason)}")}
    end
  end

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = manifest) do
    %{
      "format" => @format,
      "source_data_root" => manifest.source_data_root,
      "cipher_mode" => Atom.to_string(manifest.cipher_mode),
      "packs" => manifest.packs,
      "files" => Enum.map(manifest.files, &encode_entry/1)
    }
    |> JSON.encode!()
    |> Kernel.<>("\n")
  end

  ###
  ### Helpers
  ###

  defp decode_json(%{"format" => @format} = map) do
    with {:ok, cipher_mode} <- parse_cipher(Map.get(map, "cipher_mode")),
         {:ok, packs} <- parse_packs(Map.get(map, "packs")),
         {:ok, files} <- parse_entries(Map.get(map, "files")),
         {:ok, source} <- parse_source(Map.get(map, "source_data_root")) do
      {:ok,
       %__MODULE__{
         source_data_root: source,
         cipher_mode: cipher_mode,
         packs: packs,
         files: files
       }}
    end
  end

  defp decode_json(%{"format" => format}) do
    {:error, error("unsupported extraction manifest format #{inspect(format)}")}
  end

  defp decode_json(_value), do: {:error, error("manifest root must be a JSON object")}

  defp parse_cipher("raw"), do: {:ok, :raw}
  defp parse_cipher("xor"), do: {:ok, :xor}
  defp parse_cipher(value), do: {:error, error("invalid cipher_mode #{inspect(value)}")}

  defp parse_packs(packs) when is_list(packs) do
    if Enum.all?(packs, &(is_integer(&1) and &1 >= 0)) do
      {:ok, Enum.uniq(packs)}
    else
      {:error, error("packs must contain non-negative integers")}
    end
  end

  defp parse_packs(_value), do: {:error, error("packs must be a JSON array")}

  defp parse_entries(entries) when is_list(entries) do
    case Enum.reduce_while(entries, [], &parse_entry/2) do
      {:error, reason} -> {:error, reason}
      parsed -> {:ok, Enum.reverse(parsed)}
    end
  end

  defp parse_entries(_value), do: {:error, error("files must be a JSON array")}

  defp parse_entry(map, entries) when is_map(map) do
    case build_entry(map) do
      {:ok, entry} -> {:cont, [entry | entries]}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp parse_entry(_value, _entries), do: {:halt, {:error, error("file entry must be an object")}}

  defp build_entry(map) do
    with {:ok, record} <- non_negative_integer(map, "record"),
         {:ok, stored_path} <- required_string(map, "stored_path"),
         {:ok, virtual_path} <- optional_string(map, "virtual_path"),
         {:ok, logical_path} <- logical_path(map, virtual_path),
         {:ok, update} <- optional_string(map, "update"),
         {:ok, extracted_md5} <- digest(map, "extracted_md5"),
         {:ok, indexed_md5} <- digest(map, "indexed_md5"),
         {:ok, md5_ok} <- boolean(map, "plaintext_md5_ok") do
      {:ok,
       %Entry{
         record: record,
         stored_path: stored_path,
         virtual_path: virtual_path,
         logical_path: logical_path,
         update: update,
         extracted_md5: extracted_md5,
         indexed_md5: indexed_md5,
         plaintext_md5_ok: md5_ok
       }}
    end
  end

  defp non_negative_integer(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      value -> {:error, error("#{key} must be a non-negative integer, got #{inspect(value)}")}
    end
  end

  defp required_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      value -> {:error, error("#{key} must be a non-empty string, got #{inspect(value)}")}
    end
  end

  defp optional_string(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      value -> {:error, error("#{key} must be a string or null, got #{inspect(value)}")}
    end
  end

  defp logical_path(map, virtual_path) do
    case Map.fetch(map, "logical_path") do
      {:ok, _value} -> optional_string(map, "logical_path")
      :error -> {:ok, virtual_path}
    end
  end

  defp digest(map, key) do
    map |> Map.get(key) |> decode_digest(key)
  end

  defp decode_digest(value, _key) when is_binary(value) and byte_size(value) == 32 do
    case Base.decode16(value, case: :mixed) do
      {:ok, digest} -> {:ok, digest}
      :error -> {:error, error("digest contains non-hexadecimal characters")}
    end
  end

  defp decode_digest(_value, key), do: {:error, error("#{key} must be a 32-character MD5")}

  defp boolean(map, key) do
    case Map.get(map, key) do
      value when is_boolean(value) -> {:ok, value}
      value -> {:error, error("#{key} must be a boolean, got #{inspect(value)}")}
    end
  end

  defp parse_source(nil), do: {:ok, nil}
  defp parse_source(source) when is_binary(source), do: {:ok, source}

  defp parse_source(value),
    do: {:error, error("source_data_root must be a string or null: #{inspect(value)}")}

  defp encode_entry(%Entry{} = entry) do
    encoded = %{
      "record" => entry.record,
      "stored_path" => entry.stored_path,
      "virtual_path" => entry.virtual_path,
      "extracted_md5" => Base.encode16(entry.extracted_md5, case: :lower),
      "indexed_md5" => Base.encode16(entry.indexed_md5, case: :lower),
      "plaintext_md5_ok" => entry.plaintext_md5_ok
    }

    if is_nil(entry.update) do
      encoded
    else
      Map.merge(encoded, %{"logical_path" => entry.logical_path, "update" => entry.update})
    end
  end

  defp error(message), do: %Error{message: message, context: "packfs-manifest.json"}
end
