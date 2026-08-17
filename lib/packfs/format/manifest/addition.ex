defmodule Packfs.Format.Manifest.Addition do
  @moduledoc "A new payload registered in an extraction workspace."

  @enforce_keys [:stored_path, :path, :archive_id, :crc32, :crc16, :update]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          stored_path: String.t(),
          path: String.t(),
          archive_id: non_neg_integer(),
          crc32: non_neg_integer(),
          crc16: non_neg_integer(),
          update: String.t() | nil
        }
end
