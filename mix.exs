defmodule Packfs.MixProject do
  use Mix.Project

  @release_version "1.0.0"

  def project do
    [
      app: :packfs,
      version: version(),
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      escript: [main_module: Packfs.Cli],
      releases: releases(),
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:crypto]] ++ application_mod(Mix.env())
  end

  defp application_mod(:prod), do: [mod: {Packfs.Application, []}]
  defp application_mod(_environment), do: []

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_environment), do: ["lib"]

  defp deps do
    [
      {:burrito, "~> 1.5.0", only: :prod, runtime: false},
      {:optimus, "~> 0.6.1"},
      {:owl, "~> 0.13.1"},
      {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4.2", only: [:dev, :test], runtime: false}
    ]
  end

  defp version do
    System.get_env("PACKFS_VERSION") || local_version()
  end

  defp local_version do
    with git when is_binary(git) <- System.find_executable("git"),
         {revision, 0} <-
           System.cmd(git, ["rev-parse", "--short=12", "HEAD"],
             cd: __DIR__,
             stderr_to_stdout: true
           ) do
      "#{@release_version}-dev+git.#{String.trim(revision)}"
    else
      _error -> "#{@release_version}-dev"
    end
  end

  defp releases do
    [
      packfs: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            linux_x86_64: [os: :linux, cpu: :x86_64],
            windows_x86_64: [os: :windows, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end
end
