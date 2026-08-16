defmodule Packfs.Format.Manifest.Entry do
  @moduledoc "A payload tracked by an extraction workspace."

  @enforce_keys [
    :record,
    :stored_path,
    :virtual_path,
    :extracted_md5,
    :indexed_md5,
    :plaintext_md5_ok
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          record: non_neg_integer(),
          stored_path: String.t(),
          virtual_path: String.t() | nil,
          extracted_md5: <<_::128>>,
          indexed_md5: <<_::128>>,
          plaintext_md5_ok: boolean()
        }
end
