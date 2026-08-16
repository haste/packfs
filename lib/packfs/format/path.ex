defmodule Packfs.Format.Path do
  @moduledoc "PackFS virtual-path normalization and lookup hashing."

  import Bitwise

  @crc32_initial 0xFFFFFFFF
  @crc16_initial 0xFFFF

  @spec normalize(String.t()) :: String.t()
  def normalize(path) when is_binary(path) do
    path
    |> prepend_root(starts_with_case_insensitive?(path, "data/"))
    |> normalize_aep()
  end

  @spec hash(String.t(), non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  def hash(path, crc32_initial \\ @crc32_initial, crc16_initial \\ @crc16_initial) do
    normalized = normalize(path)
    {crc32_iso_hdlc(normalized, crc32_initial), crc16_x25(normalized, crc16_initial)}
  end

  @spec crc16_x25(binary(), non_neg_integer()) :: non_neg_integer()
  def crc16_x25(binary, initial \\ @crc16_initial) do
    binary
    |> :binary.bin_to_list()
    |> Enum.reduce(initial, &crc16_byte/2)
    |> bxor(0xFFFF)
    |> band(0xFFFF)
  end

  ###
  ### Helpers
  ###

  defp starts_with_case_insensitive?(value, prefix)
       when byte_size(value) < byte_size(prefix) do
    false
  end

  defp starts_with_case_insensitive?(value, prefix) do
    candidate = binary_part(value, 0, byte_size(prefix))
    String.downcase(candidate) == String.downcase(prefix)
  end

  defp crc16_byte(byte, crc) do
    Enum.reduce(1..8, bxor(crc, byte), fn _, value -> crc16_bit(value) end)
  end

  defp prepend_root(path, true), do: "/" <> path
  defp prepend_root(path, false), do: path

  defp normalize_aep(path) do
    normalize_aep(path, starts_with_case_insensitive?(path, "/data/aep"))
  end

  defp normalize_aep(path, true), do: String.downcase(path)
  defp normalize_aep(path, false), do: path

  defp crc32_iso_hdlc(binary, @crc32_initial), do: :erlang.crc32(binary)

  defp crc32_iso_hdlc(binary, initial) do
    binary
    |> :binary.bin_to_list()
    |> Enum.reduce(initial, &crc32_byte/2)
    |> bxor(0xFFFFFFFF)
    |> band(0xFFFFFFFF)
  end

  defp crc32_byte(byte, crc) do
    Enum.reduce(1..8, bxor(crc, byte), fn _, value -> crc32_bit(value) end)
  end

  defp crc32_bit(value) when band(value, 1) == 1 do
    bxor(value >>> 1, 0xEDB88320)
  end

  defp crc32_bit(value), do: value >>> 1

  defp crc16_bit(value) when band(value, 1) == 1 do
    bxor(value >>> 1, 0x8408)
  end

  defp crc16_bit(value), do: value >>> 1
end
