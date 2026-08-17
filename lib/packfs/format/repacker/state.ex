defmodule Packfs.Format.Repacker.State do
  @moduledoc false

  @enforce_keys [
    :workspace,
    :output,
    :force,
    :on_progress,
    :pack_info,
    :sources,
    :records,
    :archive_md5s,
    :archive_sizes
  ]
  defstruct @enforce_keys
end
