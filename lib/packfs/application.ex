defmodule Packfs.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _arguments) do
    Task.start(fn ->
      arguments()
      |> Packfs.Cli.run()
      |> System.halt()
    end)
  end

  ###
  ### Helpers
  ###

  defp arguments do
    case System.get_env("__BURRITO") do
      nil -> System.argv()
      _value -> :init.get_plain_arguments() |> Enum.map(&to_string/1)
    end
  end
end
