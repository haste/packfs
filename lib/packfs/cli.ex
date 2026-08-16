defmodule Packfs.Cli do
  @moduledoc "PackFS executable entry point."

  alias Packfs.Cli.Command
  alias Packfs.Cli.Output
  alias Packfs.Cli.Parser

  @spec main([String.t()]) :: no_return()
  def main(arguments) do
    arguments |> run() |> System.halt()
  end

  @spec run([String.t()]) :: non_neg_integer()
  def run(arguments) do
    parser = Parser.new()

    case Optimus.parse(parser, arguments) do
      {:ok, _result} ->
        Output.lines(Optimus.Help.help(parser, [], terminal_width()))
        0

      {:ok, command, result} ->
        Command.run(command, result)

      {:error, errors} ->
        Output.lines(Optimus.Errors.format(parser, errors), :stderr)
        2

      {:error, command, errors} ->
        Output.lines(Optimus.Errors.format(parser, command, errors), :stderr)
        2

      :version ->
        Output.lines(Optimus.Title.title(parser))
        0

      :help ->
        Output.lines(Optimus.Help.help(parser, [], terminal_width()))
        0

      {:help, command} ->
        Output.lines(Optimus.Help.help(parser, command, terminal_width()))
        0
    end
  end

  ###
  ### Helpers
  ###

  defp terminal_width do
    Owl.IO.columns() || 80
  end
end
