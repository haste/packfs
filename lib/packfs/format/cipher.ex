defmodule Packfs.Format.Cipher do
  @moduledoc "The position-aware PackFS payload XOR transform."

  import Bitwise

  @mask 0xFFFFFFFF

  @spec initial_state(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def initial_state(crc32, crc16) do
    crc32
    |> Kernel.+(crc16)
    |> band(@mask)
    |> rotate_left_3()
  end

  @spec transform(binary(), non_neg_integer(), non_neg_integer()) ::
          {binary(), non_neg_integer()}
  def transform(binary, crc16, state) do
    transform_words(binary, crc16, state, [])
  end

  ###
  ### Helpers
  ###

  defp transform_words(
         <<word::little-unsigned-32, rest::binary>>,
         crc16,
         state,
         transformed
       ) do
    next_state = next_state(state, crc16)
    transform_words(rest, crc16, next_state, [word |> bxor(state) |> little_word() | transformed])
  end

  defp transform_words(<<>>, _crc16, state, transformed) do
    {transformed |> Enum.reverse() |> IO.iodata_to_binary(), state}
  end

  defp transform_words(tail, _crc16, state, transformed) do
    <<first, rest::binary>> = tail
    tail_mask = state |> little_word() |> binary_part(0, byte_size(tail)) |> xor_bytes()
    output = [Enum.reverse(transformed), <<bxor(first, tail_mask)>>, rest]
    {IO.iodata_to_binary(output), state}
  end

  defp next_state(state, crc16) do
    state
    |> Kernel.+(crc16)
    |> band(@mask)
    |> rotate_left_3()
  end

  defp rotate_left_3(value), do: band(value <<< 3 ||| value >>> 29, @mask)
  defp little_word(value), do: <<value::little-unsigned-32>>

  defp xor_bytes(binary) do
    binary
    |> :binary.bin_to_list()
    |> Enum.reduce(0, &bxor/2)
  end
end
