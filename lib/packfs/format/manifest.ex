defmodule Packfs.Format.Manifest do
  @moduledoc "Codec for PackFS extraction workspace manifests."

  alias Packfs.Format.Error
  alias Packfs.Format.Manifest.Addition
  alias Packfs.Format.Manifest.Entry

  @format "packfs-workspace-v1"
  @max_u16 0xFFFF
  @max_u32 0xFFFFFFFF

  @enforce_keys [:cipher_mode, :packs, :files]
  defstruct [{:additions, []} | @enforce_keys]

  @type t :: %__MODULE__{
          cipher_mode: :raw | :xor,
          packs: [non_neg_integer()],
          files: [Entry.t()],
          additions: [Addition.t()]
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
      "cipher_mode" => Atom.to_string(manifest.cipher_mode),
      "packs" => manifest.packs,
      "additions" => Enum.map(manifest.additions, &encode_addition/1),
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
         {:ok, additions} <- parse_additions(Map.get(map, "additions", [])),
         {:ok, files} <- parse_entries(Map.get(map, "files")) do
      {:ok,
       %__MODULE__{
         cipher_mode: cipher_mode,
         packs: packs,
         additions: additions,
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

  defp parse_additions(value),
    do: parse_collection(value, &build_addition/1, "additions", "addition")

  defp build_addition(map) do
    with {:ok, stored_path} <- required_string(map, "stored_path"),
         {:ok, path} <- required_string(map, "path"),
         {:ok, archive_id} <- bounded_integer(map, "archive", @max_u16),
         {:ok, crc32} <- bounded_integer(map, "crc32", @max_u32),
         {:ok, crc16} <- bounded_integer(map, "crc16", @max_u16),
         {:ok, update} <- optional_string(map, "update") do
      {:ok,
       %Addition{
         stored_path: stored_path,
         path: path,
         archive_id: archive_id,
         crc32: crc32,
         crc16: crc16,
         update: update
       }}
    end
  end

  defp parse_entries(value), do: parse_collection(value, &build_entry/1, "files", "file entry")

  defp parse_collection(values, builder, _key, label) when is_list(values) do
    case Enum.reduce_while(values, [], &parse_object(&1, &2, builder, label)) do
      {:error, reason} -> {:error, reason}
      parsed -> {:ok, Enum.reverse(parsed)}
    end
  end

  defp parse_collection(_value, _builder, key, _label) do
    {:error, error("#{key} must be a JSON array")}
  end

  defp parse_object(map, parsed, builder, _label) when is_map(map) do
    case builder.(map) do
      {:ok, value} -> {:cont, [value | parsed]}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp parse_object(_value, _parsed, _builder, label) do
    {:halt, {:error, error("#{label} must be an object")}}
  end

  defp build_entry(map) do
    with {:ok, record} <- non_negative_integer(map, "record"),
         {:ok, stored_path} <- required_string(map, "stored_path"),
         {:ok, path} <- optional_string(map, "path"),
         {:ok, update} <- optional_string(map, "update"),
         {:ok, extracted_md5} <- digest(map, "extracted_md5"),
         {:ok, indexed_md5} <- digest(map, "indexed_md5") do
      {:ok,
       %Entry{
         record: record,
         stored_path: stored_path,
         path: path,
         update: update,
         extracted_md5: extracted_md5,
         indexed_md5: indexed_md5
       }}
    end
  end

  defp non_negative_integer(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      value -> {:error, error("#{key} must be a non-negative integer, got #{inspect(value)}")}
    end
  end

  defp bounded_integer(map, key, maximum) do
    case Map.get(map, key) do
      value when is_integer(value) and value >= 0 and value <= maximum ->
        {:ok, value}

      value ->
        {:error, error("#{key} must be an integer from 0 to #{maximum}, got #{inspect(value)}")}
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

  defp encode_addition(%Addition{} = addition) do
    %{
      "stored_path" => addition.stored_path,
      "path" => addition.path,
      "archive" => addition.archive_id,
      "crc32" => addition.crc32,
      "crc16" => addition.crc16,
      "update" => addition.update
    }
  end

  defp encode_entry(%Entry{} = entry) do
    %{
      "record" => entry.record,
      "stored_path" => entry.stored_path,
      "path" => entry.path,
      "update" => entry.update,
      "extracted_md5" => Base.encode16(entry.extracted_md5, case: :lower),
      "indexed_md5" => Base.encode16(entry.indexed_md5, case: :lower)
    }
  end

  defp error(message), do: %Error{message: message, context: "packfs-manifest.json"}
end
