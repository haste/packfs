defmodule Packfs.Format.CipherTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Packfs.Format.Cipher

  @mask 0xFFFFFFFF

  test "matches a fixed XOR vector and remains its own inverse" do
    input = <<0, 1, 2, 3, 4, 5, 6, 7, 8>>
    crc32 = 0x6CDF6A53
    crc16 = 0x90DD
    state = Cipher.initial_state(crc32, crc16)

    assert state == 0x66FFD983
    assert {encrypted, 0xC01F1F01} = Cipher.transform(input, crc16, state)
    assert encrypted == <<0x83, 0xD8, 0xFD, 0x65, 0x07, 0x56, 0x05, 0x3F, 0x09>>

    assert {^input, 0xC01F1F01} = Cipher.transform(encrypted, crc16, state)
  end

  test "the retail partial-word behavior only changes the first tail byte" do
    crc32 = 0x10203040
    crc16 = 0x5060
    state = Cipher.initial_state(crc32, crc16)
    input = <<1, 2, 3>>

    {output, ^state} = Cipher.transform(input, crc16, state)
    <<first, second, third>> = output

    assert first != 1
    assert second == 2
    assert third == 3
  end

  test "block transform matches the word-at-a-time algorithm" do
    crc32 = 0x89ABCDEF
    crc16 = 0x7654
    state = Cipher.initial_state(crc32, crc16)

    for size <- [31, 32, 33, 255, 256, 257, 4099] do
      input = :binary.list_to_bin(for index <- 0..(size - 1), do: rem(index * 73 + 19, 256))
      assert Cipher.transform(input, crc16, state) == reference_transform(input, crc16, state)
    end
  end

  defp reference_transform(binary, crc16, state) do
    reference_words(binary, crc16, state, [])
  end

  defp reference_words(
         <<word::little-unsigned-32, rest::binary>>,
         crc16,
         state,
         transformed
       ) do
    next_state = state |> Kernel.+(crc16) |> band(@mask) |> rotate_left_3()
    output = <<bxor(word, state)::little-unsigned-32>>
    reference_words(rest, crc16, next_state, [output | transformed])
  end

  defp reference_words(<<>>, _crc16, state, transformed) do
    {transformed |> Enum.reverse() |> IO.iodata_to_binary(), state}
  end

  defp reference_words(tail, _crc16, state, transformed) do
    <<first, rest::binary>> = tail
    mask = binary_part(<<state::little-unsigned-32>>, 0, byte_size(tail))
    tail_mask = mask |> :binary.bin_to_list() |> Enum.reduce(0, &bxor/2)
    output = [Enum.reverse(transformed), <<bxor(first, tail_mask)>>, rest]
    {IO.iodata_to_binary(output), state}
  end

  defp rotate_left_3(value), do: band(value <<< 3 ||| value >>> 29, @mask)
end
