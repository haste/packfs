defmodule Packfs.Format.Validation do
  @moduledoc "Structured PackFS validation findings."

  defstruct errors: [], warnings: []

  @type t :: %__MODULE__{errors: [String.t()], warnings: [String.t()]}

  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{errors: []}), do: true
  def valid?(%__MODULE__{}), do: false

  @spec error(t(), String.t()) :: t()
  def error(%__MODULE__{} = validation, message) do
    %{validation | errors: [message | validation.errors]}
  end

  @spec warning(t(), String.t()) :: t()
  def warning(%__MODULE__{} = validation, message) do
    %{validation | warnings: [message | validation.warnings]}
  end

  @spec check(t(), boolean(), String.t()) :: t()
  def check(%__MODULE__{} = validation, true, _message), do: validation
  def check(%__MODULE__{} = validation, false, message), do: error(validation, message)

  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = left, %__MODULE__{} = right) do
    %__MODULE__{
      errors: right.errors ++ left.errors,
      warnings: right.warnings ++ left.warnings
    }
  end

  @spec finish(t()) :: t()
  def finish(%__MODULE__{} = validation) do
    %{
      validation
      | errors: Enum.reverse(validation.errors),
        warnings: Enum.reverse(validation.warnings)
    }
  end
end
