defmodule Packfs.Format.ResolvedName do
  @moduledoc "A logical path resolved for a runtime record or a retained update record."

  @enforce_keys [:path, :update]
  defstruct @enforce_keys

  @type t :: %__MODULE__{path: String.t(), update: String.t() | nil}
end
