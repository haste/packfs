defmodule Packfs.Format.CipherTest do
  use ExUnit.Case, async: true

  alias Packfs.Format.Cipher

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
end
