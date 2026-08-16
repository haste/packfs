defmodule Packfs.Format.IntegrityRecord do
  @moduledoc "A whole-file `finfolist.bin` integrity record."

  @enforce_keys [:index, :path, :size, :md5, :group]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          path: String.t(),
          size: non_neg_integer(),
          md5: <<_::128>>,
          group: non_neg_integer()
        }
end
