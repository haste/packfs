defmodule Packfs.Cli.Parser do
  @moduledoc "Defines the PackFS command-line interface."

  @spec new() :: Optimus.t()
  def new do
    Optimus.new!(
      name: "packfs",
      description: "Inspect, verify, unpack, and repack Konami PackFS archives",
      version: version(),
      author: "PackFS contributors",
      about: "Manages packed data roots and manifest-based extraction workspaces.",
      allow_unknown_args: false,
      parse_double_dash: true,
      subcommands: [
        inspect: inspect_spec(),
        verify: verify_spec(),
        unpack: unpack_spec(),
        repack: repack_spec()
      ]
    )
  end

  ###
  ### Helpers
  ###

  defp inspect_spec do
    [
      name: "inspect",
      about: "Show metadata for a packed root or extraction workspace",
      args: [target: path_argument("TARGET", "Packed data root or extraction workspace")],
      flags: [
        records: flag("--records", "Include individual file records"),
        json: flag("--json", "Write machine-readable JSON")
      ],
      options: selection_options() ++ name_options() ++ cipher_options()
    ]
  end

  defp verify_spec do
    [
      name: "verify",
      about: "Validate a packed root or extraction workspace",
      args: [target: path_argument("TARGET", "Packed data root or extraction workspace")],
      flags: [
        archives: flag("--archives", "Hash complete packed archives"),
        files: flag("--files", "Hash individual plaintext files"),
        json: flag("--json", "Write machine-readable JSON")
      ],
      options: selection_options() ++ cipher_options()
    ]
  end

  defp unpack_spec do
    [
      name: "unpack",
      about: "Extract selected archives into a manifest workspace",
      args: [
        source: path_argument("SOURCE", "Packed data root"),
        output: path_argument("OUTPUT", "New extraction workspace")
      ],
      flags: [
        skip_verify: flag("--no-verify", "Skip archive and payload digest checks"),
        allow_bad_md5: flag("--allow-bad-md5", "Keep payloads with an indexed MD5 mismatch"),
        force: flag("--force", "Allow writes into an existing output directory"),
        quiet: flag("--quiet", "Suppress the success summary")
      ],
      options: selection_options() ++ name_options() ++ cipher_options()
    ]
  end

  defp repack_spec do
    [
      name: "repack",
      about: "Rebuild archives from a manifest workspace",
      args: [
        workspace: path_argument("WORKSPACE", "Extraction workspace"),
        output: path_argument("OUTPUT", "New packed data root or overlay")
      ],
      flags: [
        force: flag("--force", "Allow writes into an existing output directory"),
        quiet: flag("--quiet", "Suppress the success summary")
      ]
    ]
  end

  defp path_argument(value_name, help) do
    [value_name: value_name, help: help, required: true, parser: :string]
  end

  defp flag(long, help) do
    [long: long, help: help, multiple: false]
  end

  defp selection_options do
    [
      pack: [
        value_name: "ID_OR_RANGE",
        long: "--pack",
        help: "Select an archive ID, comma list, or inclusive range",
        parser: :string,
        multiple: true,
        required: false
      ]
    ]
  end

  defp name_options do
    [
      name_set: [
        value_name: "NAME",
        long: "--name-set",
        help: "Use a bundled path set; repeatable (default: all)",
        parser: :string,
        multiple: true,
        required: false,
        default: ["all"]
      ],
      names: [
        value_name: "FILE",
        long: "--names",
        help: "Add a newline-delimited path file; repeatable",
        parser: :string,
        multiple: true,
        required: false
      ]
    ]
  end

  defp cipher_options do
    [
      cipher: [
        value_name: "MODE",
        long: "--cipher",
        help: "Payload storage mode: auto, raw, or xor",
        parser: &parse_cipher/1,
        required: false,
        default: :auto
      ]
    ]
  end

  defp parse_cipher("auto"), do: {:ok, :auto}
  defp parse_cipher("raw"), do: {:ok, :raw}
  defp parse_cipher("xor"), do: {:ok, :xor}
  defp parse_cipher(value), do: {:error, "expected auto, raw, or xor; got #{inspect(value)}"}

  defp version do
    :packfs
    |> Application.spec(:vsn)
    |> to_string()
  end
end
