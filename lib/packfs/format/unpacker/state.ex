defmodule Packfs.Format.Unpacker.State do
  @moduledoc false

  @enforce_keys [
    :data_set,
    :output,
    :cipher_mode,
    :names,
    :force,
    :verify,
    :verify_archives,
    :allow_bad_md5,
    :on_progress,
    :files,
    :bytes,
    :warnings,
    :archive_digest
  ]
  defstruct @enforce_keys
end
