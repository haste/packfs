defmodule Packfs.Format.ValidationTest do
  use ExUnit.Case, async: true

  alias Packfs.Format.Validation

  test "merged findings retain the order of both validations" do
    left = %Validation{} |> Validation.error("left one") |> Validation.error("left two")
    right = %Validation{} |> Validation.error("right one") |> Validation.error("right two")

    assert %Validation{errors: ["left one", "left two", "right one", "right two"]} =
             left |> Validation.merge(right) |> Validation.finish()
  end

  test "check adds only failed conditions" do
    validation =
      %Validation{}
      |> Validation.check(true, "passes")
      |> Validation.check(false, "fails")
      |> Validation.finish()

    assert validation.errors == ["fails"]
  end
end
