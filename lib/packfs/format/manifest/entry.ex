defmodule Packfs.Format.Manifest.Entry do
  @moduledoc "A payload tracked by an extraction workspace."

  @enforce_keys [
    :record,
    :stored_path,
    :path,
    :update,
    :extracted_md5,
    :indexed_md5
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          record: non_neg_integer(),
          stored_path: String.t(),
          path: String.t() | nil,
          update: String.t() | nil,
          extracted_md5: <<_::128>>,
          indexed_md5: <<_::128>>
        }
end
