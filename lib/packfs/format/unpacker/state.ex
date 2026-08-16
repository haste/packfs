defmodule Packfs.Format.Unpacker.State do
  @moduledoc false

  @enforce_keys [
    :data_set,
    :output,
    :cipher_mode,
    :names,
    :force,
    :verify,
    :allow_bad_md5,
    :on_progress,
    :files,
    :bytes,
    :warnings
  ]
  defstruct @enforce_keys
end
