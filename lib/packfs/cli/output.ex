defmodule Packfs.Cli.Output do
  @moduledoc "Renders command results for people or JSON consumers."

  alias Packfs.Format.Inspection
  alias Packfs.Format.Manifest.Addition
  alias Packfs.Format.PackInfo
  alias Packfs.Format.RepackResult
  alias Packfs.Format.UnpackResult
  alias Packfs.Format.Validation
  alias Packfs.Format.WorkspaceStatus

  @spec add(Addition.t()) :: :ok
  def add(%Addition{} = result) do
    update = if result.update, do: " (update #{result.update})", else: ""
    Owl.IO.puts("Added #{result.path} to archive #{result.archive_id}#{update}.")
  end

  @spec inspection(Inspection.t(), boolean()) :: :ok
  def inspection(%Inspection{} = inspection, true) do
    inspection |> inspection_json() |> write_json()
  end

  def inspection(%Inspection{} = inspection, false) do
    write_inspection(inspection)
    write_findings(inspection.validation)
    write_records(inspection.records)
  end

  @spec validation(Validation.t(), boolean()) :: :ok
  def validation(%Validation{} = validation, true) do
    validation |> validation_json() |> write_json()
  end

  def validation(%Validation{} = validation, false) do
    Owl.IO.puts(status(validation))
    write_findings(validation)
  end

  @spec unpack(UnpackResult.t()) :: :ok
  def unpack(%UnpackResult{} = result) do
    files = quantity(result.files, "file")
    archives = quantity(result.archives, "archive")
    size = human_size(result.bytes)

    Owl.IO.puts("Unpacked #{files} from #{archives} (#{size}, #{result.cipher_mode}).")
    Owl.IO.puts("Paths: #{result.resolved} resolved, #{result.unresolved} unresolved.")
    write_updates(result.updates)
    write_messages("warning", result.warnings, :stderr)
  end

  @spec repack(RepackResult.t()) :: :ok
  def repack(%RepackResult{} = result) do
    files = quantity(result.files, "file")
    archives = quantity(result.archives, "archive")
    size = human_size(result.bytes)

    Owl.IO.puts("Repacked #{files} into #{archives} (#{size}, #{result.cipher_mode}).")
  end

  @spec workspace_status(WorkspaceStatus.t(), boolean()) :: :ok
  def workspace_status(%WorkspaceStatus{} = status, true) do
    status
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> write_json()
  end

  def workspace_status(%WorkspaceStatus{} = status, false) do
    if WorkspaceStatus.clean?(status) do
      Owl.IO.puts("Workspace clean.")
    else
      write_status_paths("M", status.modified)
      write_status_paths("D", status.deleted)
      write_status_paths("A", status.added)
      write_status_paths("!", status.errors)
    end
  end

  @spec error(Exception.t() | String.t()) :: :ok
  def error(%_module{} = reason) do
    Owl.IO.puts("error: #{Exception.message(reason)}", :stderr)
  end

  def error(reason) when is_binary(reason) do
    Owl.IO.puts("error: #{reason}", :stderr)
  end

  @spec lines(iodata(), IO.device()) :: :ok
  def lines(lines, device \\ :stdio) do
    Enum.each(lines, &Owl.IO.puts(&1, device))
  end

  ###
  ### Helpers
  ###

  defp write_status_paths(marker, paths) do
    Enum.each(paths, &Owl.IO.puts("#{marker} #{&1}"))
  end

  defp inspection_json(inspection) do
    %{
      "type" => Atom.to_string(inspection.kind),
      "root" => inspection.root,
      "summary" => stringify_map(inspection.summary),
      "validation" => validation_json(inspection.validation),
      "records" => Enum.map(inspection.records, &record_json/1)
    }
  end

  defp validation_json(validation) do
    %{
      "valid" => Validation.valid?(validation),
      "errors" => validation.errors,
      "warnings" => validation.warnings
    }
  end

  defp stringify_map(map) do
    Map.new(map, fn {key, value} -> {Atom.to_string(key), json_value(value)} end)
  end

  defp record_json(record) do
    record
    |> Map.update!(:md5, &hex/1)
    |> maybe_update_digest(:extracted_md5)
    |> stringify_map()
  end

  defp maybe_update_digest(map, key) do
    case Map.fetch(map, key) do
      {:ok, digest} -> Map.put(map, key, hex(digest))
      :error -> map
    end
  end

  defp json_value(value) when is_atom(value), do: Atom.to_string(value)
  defp json_value(value), do: value

  defp write_json(value) do
    value |> JSON.encode!() |> Owl.IO.puts()
  end

  defp write_inspection(%Inspection{kind: :packed} = inspection) do
    summary = inspection.summary
    unresolved = summary.file_count - summary.resolved

    lines([
      "Packed data root: #{inspection.root}",
      "Magic: 0x#{hex(summary.magic, 8)} (#{PackInfo.magic_name(summary.magic)})",
      "Archives: #{summary.selected_archives} selected, #{summary.archive_count} total",
      "Files: #{summary.file_count} selected, #{summary.total_file_count} total",
      "Paths: #{summary.resolved} resolved, #{unresolved} unresolved",
      "Cipher: #{summary.cipher_mode}",
      "Integrity records: #{summary.integrity_record_count}",
      "Status: #{inspection_status(inspection.validation)}"
    ])
  end

  defp write_inspection(%Inspection{kind: :workspace} = inspection) do
    summary = inspection.summary

    lines([
      "Extraction workspace: #{inspection.root}",
      "Format: #{summary.manifest_format}",
      "Archives: #{summary.archive_count}",
      "Files: #{summary.file_count}",
      "Paths: #{summary.resolved} resolved, #{summary.unresolved} unresolved",
      "Cipher: #{summary.cipher_mode}",
      "Status: #{inspection_status(inspection.validation)}"
    ])
  end

  defp write_findings(validation) do
    write_messages("warning", validation.warnings, :stderr)
    write_messages("error", validation.errors, :stderr)
  end

  defp write_messages(label, messages, device) do
    Enum.each(messages, &Owl.IO.puts("#{label}: #{&1}", device))
  end

  defp write_records([]), do: :ok

  defp write_records(records) do
    rows = Enum.map(records, &record_row/1)

    columns = [
      "index",
      "hash",
      "archive",
      "offset",
      "size",
      "md5",
      "virtual path",
      "logical path",
      "update",
      "stored path"
    ]

    Owl.IO.puts(table(rows, columns))
  end

  defp record_row(record) do
    %{
      "index" => record.index,
      "hash" => "#{hex(record.crc32, 8)}-#{hex(record.crc16, 4)}",
      "archive" => record.archive_id,
      "offset" => record.offset,
      "size" => record.size,
      "md5" => hex(record.md5),
      "virtual path" => record.virtual_path || "-",
      "logical path" => Map.get(record, :logical_path, record.virtual_path) || "-",
      "update" => Map.get(record, :update) || "-",
      "stored path" => Map.get(record, :stored_path, "-")
    }
  end

  defp table(rows, columns) do
    Owl.Table.new(rows,
      border_style: :none,
      padding_x: 1,
      render_cell: &display/1,
      sort_columns: &column_before?(&1, &2, columns)
    )
  end

  defp column_before?(left, right, columns) do
    column_index(columns, left) <= column_index(columns, right)
  end

  defp column_index(columns, column) do
    Enum.find_index(columns, &(&1 == column)) || length(columns)
  end

  defp display(nil), do: "-"
  defp display(value) when is_atom(value), do: Atom.to_string(value)
  defp display(value) when is_integer(value), do: Integer.to_string(value)
  defp display(value) when is_binary(value), do: value

  defp status(%Validation{errors: []}), do: "OK"
  defp status(%Validation{}), do: "FAILED"

  defp inspection_status(%Validation{errors: [], warnings: []}), do: "OK"

  defp inspection_status(%Validation{errors: [], warnings: warnings}) do
    "OK (#{length(warnings)} warnings)"
  end

  defp inspection_status(%Validation{errors: errors}) do
    "FAILED (#{length(errors)} errors)"
  end

  defp quantity(1, singular), do: "1 #{singular}"
  defp quantity(value, singular), do: "#{value} #{singular}s"

  defp write_updates(updates) do
    updates
    |> Enum.sort()
    |> Enum.each(fn {name, count} ->
      Owl.IO.puts("Update #{name}: #{quantity(count, "file")}.")
    end)
  end

  defp human_size(bytes) when bytes < 1024, do: "#{bytes} B"

  defp human_size(bytes) do
    bytes |> Kernel./(1024) |> scaled_size(["KiB", "MiB", "GiB", "TiB"])
  end

  defp scaled_size(value, [unit]) do
    "#{format_size(value)} #{unit}"
  end

  defp scaled_size(value, [unit | _units]) when value < 1024 do
    "#{format_size(value)} #{unit}"
  end

  defp scaled_size(value, [_unit | units]) do
    scaled_size(value / 1024, units)
  end

  defp format_size(value) do
    :erlang.float_to_binary(value, decimals: 1)
  end

  defp hex(value) when is_binary(value), do: Base.encode16(value, case: :lower)

  defp hex(value, width) do
    value |> Integer.to_string(16) |> String.pad_leading(width, "0")
  end
end
