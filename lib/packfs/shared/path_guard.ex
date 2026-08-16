defmodule Packfs.Shared.PathGuard do
  @moduledoc "Validates manifest-controlled paths before filesystem access."

  @spec join(Path.t(), String.t()) :: {:ok, Path.t()} | {:error, String.t()}
  def join(base, relative) do
    parts = Path.split(relative)

    with :ok <- validate_relative(relative, parts) do
      join_validated(base, relative, parts)
    end
  end

  ###
  ### Helpers
  ###

  defp validate_relative(relative, parts) do
    cond do
      Path.type(relative) != :relative ->
        {:error, "stored path must be relative: #{inspect(relative)}"}

      parts == [] or Enum.any?(parts, &(&1 in ["", ".", ".."])) ->
        {:error, "stored path contains an unsafe segment: #{inspect(relative)}"}

      true ->
        :ok
    end
  end

  defp join_validated(base, relative, parts) do
    expanded_base = Path.expand(base)
    candidate = Path.expand(relative, expanded_base)

    with :ok <- inside_base(candidate, expanded_base),
         :ok <- no_symlink_parent(expanded_base, parts) do
      {:ok, candidate}
    end
  end

  defp inside_base(path, base) do
    relative = Path.relative_to(path, base)

    if relative == ".." or String.starts_with?(relative, "../") do
      {:error, "stored path escapes the extraction directory"}
    else
      :ok
    end
  end

  defp no_symlink_parent(base, parts) do
    Enum.reduce_while(parts, base, fn part, parent ->
      path = Path.join(parent, part)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :symlink}} ->
          {:halt, {:error, "stored path crosses symlink #{path}"}}

        {:ok, _stat} ->
          {:cont, path}

        {:error, :enoent} ->
          {:cont, path}

        {:error, reason} ->
          {:halt, {:error, "cannot inspect #{path}: #{reason}"}}
      end
    end)
    |> case do
      path when is_binary(path) -> :ok
      error -> error
    end
  end
end
