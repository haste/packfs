defmodule Packfs.Format.Repacker.ArchiveState do
  @moduledoc false

  @enforce_keys [:stream, :workspace, :entries, :cipher_mode, :position, :md5, :records]
  defstruct @enforce_keys
end
