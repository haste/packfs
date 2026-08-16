defmodule Packfs.Format.Repacker.State do
  @moduledoc false

  @enforce_keys [
    :workspace,
    :output,
    :force,
    :on_progress,
    :entries,
    :records,
    :archive_md5s,
    :archive_sizes
  ]
  defstruct @enforce_keys
end
