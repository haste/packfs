defmodule Packfs.Format.Inspection do
  @moduledoc "Structured metadata for a packed data set or extraction workspace."

  alias Packfs.Format.Validation

  @enforce_keys [:kind, :root, :summary, :records, :validation]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          kind: :packed | :workspace,
          root: Path.t(),
          summary: map(),
          records: [map()],
          validation: Validation.t()
        }
end
