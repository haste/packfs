defmodule Packfs.Format.RepackResult do
  @moduledoc "Summary returned after a successful rebuild."

  @enforce_keys [:archives, :files, :bytes, :cipher_mode]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          archives: non_neg_integer(),
          files: non_neg_integer(),
          bytes: non_neg_integer(),
          cipher_mode: :raw | :xor
        }
end
