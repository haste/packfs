defmodule Mix.Tasks.Packfs do
  @moduledoc false

  use Mix.Task

  @shortdoc "Runs the PackFS CLI"

  @impl Mix.Task
  def run(arguments) do
    Packfs.Cli.main(arguments)
  end
end
