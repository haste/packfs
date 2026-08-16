defmodule Packfs.Cli.Command do
  @moduledoc "Coordinates CLI commands across the format and presentation domains."

  alias Optimus.ParseResult
  alias Packfs.Cli.Output
  alias Packfs.Format.DataSet
  alias Packfs.Format.Inspector
  alias Packfs.Format.Names
  alias Packfs.Format.PackInfo
  alias Packfs.Format.Repacker
  alias Packfs.Format.Target
  alias Packfs.Format.Unpacker
  alias Packfs.Format.Validation
  alias Packfs.Format.Verifier
  alias Packfs.Format.Workspace
  alias Packfs.Format.WorkspaceVerifier
  alias Packfs.Shared.Selection

  @spec run([atom()], ParseResult.t()) :: non_neg_integer()
  def run([:inspect], %ParseResult{} = parsed) do
    case inspect_target(parsed) do
      {:ok, inspection} ->
        Output.inspection(inspection, parsed.flags.json)
        0

      {:error, reason} ->
        Output.error(reason)
        1
    end
  end

  def run([:verify], %ParseResult{} = parsed) do
    case verify(parsed) do
      {:ok, validation} ->
        Output.validation(validation, parsed.flags.json)
        validation_exit(validation)

      {:error, reason} ->
        Output.error(reason)
        1
    end
  end

  def run([:unpack], %ParseResult{} = parsed) do
    case unpack(parsed) do
      {:ok, result} ->
        write_unpack_result(result, parsed.flags.quiet)
        0

      {:error, reason} ->
        Output.error(reason)
        1
    end
  end

  def run([:repack], %ParseResult{} = parsed) do
    case repack(parsed) do
      {:ok, result} ->
        write_repack_result(result, parsed.flags.quiet)
        0

      {:error, reason} ->
        Output.error(reason)
        1
    end
  end

  ###
  ### Helpers
  ###

  defp inspect_target(parsed) do
    with {:ok, target} <- Target.load(parsed.args.target),
         {:ok, options} <- inspection_options(target, parsed) do
      {:ok, Inspector.inspect(target, options)}
    end
  end

  defp inspection_options(%Target{kind: :packed, data: data_set}, parsed) do
    with {:ok, selected} <- selection(data_set, parsed.options.pack),
         {:ok, resolved} <- resolve_names(data_set, selected, parsed) do
      {:ok,
       [
         selected: selected,
         names: resolved.paths,
         warnings: resolved.warnings,
         cipher: parsed.options.cipher,
         records: parsed.flags.records
       ]}
    end
  end

  defp inspection_options(%Target{kind: :workspace}, parsed) do
    {:ok, [records: parsed.flags.records]}
  end

  defp verify(parsed) do
    with {:ok, target} <- Target.load(parsed.args.target) do
      verify_target(target, parsed)
    end
  end

  defp verify_target(%Target{kind: :packed, data: data_set}, parsed) do
    with {:ok, selected} <- selection(data_set, parsed.options.pack) do
      {:ok,
       Verifier.verify(data_set, selected,
         archives: parsed.flags.archives,
         files: parsed.flags.files,
         cipher: parsed.options.cipher
       )}
    end
  end

  defp verify_target(%Target{kind: :workspace, data: workspace}, parsed) do
    {:ok, WorkspaceVerifier.verify(workspace, files: parsed.flags.files)}
  end

  defp unpack(parsed) do
    with {:ok, data_set} <- DataSet.load(parsed.args.source),
         {:ok, selected} <- selection(data_set, parsed.options.pack),
         :ok <- validate_unpack_source(data_set, selected, parsed.flags.skip_verify),
         {:ok, resolved} <- resolve_names(data_set, selected, parsed),
         {:ok, result} <- unpack_data_set(data_set, selected, resolved.paths, parsed) do
      {:ok, %{result | warnings: resolved.warnings ++ result.warnings}}
    end
  end

  defp validate_unpack_source(data_set, selected, skip_verify) do
    validation = Verifier.verify(data_set, selected, archives: not skip_verify, files: false)

    case validation.errors do
      [] -> :ok
      errors -> {:error, "source validation failed: " <> Enum.join(errors, "; ")}
    end
  end

  defp unpack_data_set(data_set, selected, names, parsed) do
    Unpacker.run(data_set, parsed.args.output, selected, names,
      cipher: parsed.options.cipher,
      verify: not parsed.flags.skip_verify,
      allow_bad_md5: parsed.flags.allow_bad_md5,
      force: parsed.flags.force
    )
  end

  defp repack(parsed) do
    with {:ok, workspace} <- Workspace.load(parsed.args.workspace) do
      Repacker.run(workspace, parsed.args.output, force: parsed.flags.force)
    end
  end

  defp selection(data_set, values) do
    Selection.parse(values, data_set.pack_info.archive_count)
  end

  defp resolve_names(data_set, selected, parsed) do
    records = PackInfo.selected_records(data_set.pack_info, selected)
    Names.resolve(records, parsed.options.name_set, parsed.options.names)
  end

  defp validation_exit(%Validation{errors: []}), do: 0
  defp validation_exit(%Validation{}), do: 1

  defp write_unpack_result(_result, true), do: :ok
  defp write_unpack_result(result, false), do: Output.unpack(result)
  defp write_repack_result(_result, true), do: :ok
  defp write_repack_result(result, false), do: Output.repack(result)
end
