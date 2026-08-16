defmodule Packfs.Format.Error do
  @moduledoc "Structured failure returned by PackFS format operations."

  defexception [:message, :context, :offset]

  @type t :: %__MODULE__{
          message: String.t(),
          context: String.t() | nil,
          offset: non_neg_integer() | nil
        }

  @impl Exception
  def message(%__MODULE__{} = error) do
    [error.context, format_offset(error.offset), error.message]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(": ")
  end

  ###
  ### Helpers
  ###

  defp format_offset(nil), do: nil
  defp format_offset(offset), do: "offset 0x#{Integer.to_string(offset, 16)}"
end
