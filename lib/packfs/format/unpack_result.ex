defmodule Packfs.Format.UnpackResult do
  @moduledoc "Summary returned after a successful extraction."

  @enforce_keys [:archives, :files, :bytes, :resolved, :unresolved, :warnings, :cipher_mode]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          archives: non_neg_integer(),
          files: non_neg_integer(),
          bytes: non_neg_integer(),
          resolved: non_neg_integer(),
          unresolved: non_neg_integer(),
          warnings: [String.t()],
          cipher_mode: :raw | :xor
        }
end
