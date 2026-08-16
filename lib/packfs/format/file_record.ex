defmodule Packfs.Format.FileRecord do
  @moduledoc "An indexed PackFS payload record."

  @enforce_keys [:index, :md5, :crc32, :crc16, :archive_id, :offset, :size]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          md5: <<_::128>>,
          crc32: non_neg_integer(),
          crc16: non_neg_integer(),
          archive_id: non_neg_integer(),
          offset: non_neg_integer(),
          size: non_neg_integer()
        }
end
