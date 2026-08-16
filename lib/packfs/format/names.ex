defmodule Packfs.Format.Names do
  @moduledoc "Resolves PackFS hash pairs from bundled and user-supplied path sets."

  alias Packfs.Format.Error
  alias Packfs.Format.Path, as: VirtualPath

  @set_sources %{
    "gfdm-v4" => ["gfdm-v4.txt"],
    "gfdm-v5" => ["gfdm-v5.txt"],
    "gfdm-v6" => ["gfdm-v6.txt"],
    "gfdm-v7" => ["gfdm-v7.txt"],
    "gfdm-v8" => ["gfdm-v8.txt"],
    "gfdm-xg1" => ["gfdm-xg1.txt"]
  }

  @type hash_pair :: {non_neg_integer(), non_neg_integer()}
  @type result :: %{paths: %{hash_pair() => String.t()}, warnings: [String.t()]}

  @spec resolve([Packfs.Format.FileRecord.t()], [String.t()], [Path.t()]) ::
          {:ok, result()} | {:error, Error.t()}
  def resolve(records, selected_sets \\ ["all"], name_files \\ []) do
    wanted = records |> Enum.map(&{&1.crc32, &1.crc16}) |> MapSet.new()

    with {:ok, bundled} <- bundled_sources(selected_sets),
         {:ok, state} <- load_sources(bundled, wanted, 0, empty_state()),
         {:ok, state} <- load_sources(name_files, wanted, 1, state) do
      {:ok, finalize(state)}
    end
  end

  @spec available_sets() :: [String.t()]
  def available_sets, do: ["all" | @set_sources |> Map.keys() |> Enum.sort()]

  ###
  ### Helpers
  ###

  defp bundled_sources(selected_sets) do
    case selected_sets |> expand_all() |> Enum.reduce_while([], &add_set_sources/2) do
      {:error, reason} -> {:error, reason}
      filenames -> {:ok, source_paths(filenames)}
    end
  end

  defp expand_all(sets) do
    if "all" in sets, do: Map.keys(@set_sources), else: Enum.uniq(sets)
  end

  defp add_set_sources(set, sources) do
    case Map.fetch(@set_sources, set) do
      {:ok, filenames} -> {:cont, Enum.reverse(filenames, sources)}
      :error -> {:halt, {:error, error("unknown name set #{inspect(set)}")}}
    end
  end

  defp source_paths(filenames) do
    names_root = Path.join(priv_dir(), "names")
    filenames |> Enum.reverse() |> Enum.uniq() |> Enum.map(&Path.join(names_root, &1))
  end

  defp load_sources(sources, wanted, priority, initial) do
    case Enum.reduce_while(sources, initial, &reduce_source(&1, &2, wanted, priority)) do
      {:error, reason} -> {:error, reason}
      state -> {:ok, state}
    end
  end

  defp reduce_source(source, state, wanted, priority) do
    case load_source(source, wanted, priority, state) do
      {:ok, updated} -> {:cont, updated}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp load_source(source, wanted, priority, state) do
    case File.read(source) do
      {:ok, contents} -> add_source_contents(contents, wanted, priority, state)
      {:error, reason} -> {:error, source_error(source, reason)}
    end
  end

  defp add_source_contents(contents, wanted, priority, state) do
    updated =
      contents
      |> String.split("\n")
      |> Enum.reduce(state, &add_line(&1, &2, wanted, priority))

    {:ok, updated}
  end

  defp source_error(source, reason) do
    message = "cannot read name source #{source}: #{:file.format_error(reason)}"
    error(message)
  end

  defp add_line(line, state, wanted, priority) do
    line
    |> String.trim()
    |> add_candidate(state, wanted, priority)
  end

  defp add_candidate("", state, _wanted, _priority), do: state
  defp add_candidate("#" <> _comment, state, _wanted, _priority), do: state

  defp add_candidate(candidate, state, wanted, priority) do
    canonical = VirtualPath.normalize(candidate)
    hash = VirtualPath.hash(canonical)
    maybe_add_candidate(state, hash, canonical, wanted, priority)
  end

  defp maybe_add_candidate(state, hash, path, wanted, priority) do
    add_wanted_candidate(state, hash, path, priority, MapSet.member?(wanted, hash))
  end

  defp add_wanted_candidate(state, _hash, _path, _priority, false), do: state

  defp add_wanted_candidate(state, hash, path, priority, true) do
    state.candidates
    |> Map.get(hash)
    |> update_candidate(state, hash, path, priority)
  end

  defp update_candidate(nil, state, hash, path, priority) do
    candidate = %{priority: priority, paths: MapSet.new([path])}
    put_in(state, [:candidates, hash], candidate)
  end

  defp update_candidate(%{priority: current}, state, hash, path, priority)
       when priority > current do
    candidate = %{priority: priority, paths: MapSet.new([path])}
    put_in(state, [:candidates, hash], candidate)
  end

  defp update_candidate(%{priority: current}, state, _hash, _path, priority)
       when priority < current do
    state
  end

  defp update_candidate(candidate, state, hash, path, _priority) do
    updated = %{candidate | paths: MapSet.put(candidate.paths, path)}
    put_in(state, [:candidates, hash], updated)
  end

  defp empty_state, do: %{candidates: %{}, warnings: []}

  defp finalize(state) do
    {paths, warnings} =
      Enum.reduce(state.candidates, {%{}, state.warnings}, fn {hash, candidate}, result ->
        resolve_candidate(hash, candidate, result)
      end)

    %{paths: paths, warnings: Enum.reverse(warnings)}
  end

  defp resolve_candidate(hash, %{paths: paths}, {resolved, warnings}) do
    case MapSet.to_list(paths) do
      [path] -> {Map.put(resolved, hash, path), warnings}
      ambiguous -> {resolved, [collision_warning(hash, ambiguous) | warnings]}
    end
  end

  defp collision_warning({crc32, crc16}, paths) do
    formatted = Enum.join(Enum.sort(paths), ", ")

    "ambiguous path hash #{hex(crc32, 8)}-#{hex(crc16, 4)}: #{formatted}"
  end

  defp priv_dir do
    :packfs
    |> :code.priv_dir()
    |> to_string()
  end

  defp hex(value, width) do
    value |> Integer.to_string(16) |> String.pad_leading(width, "0")
  end

  defp error(message), do: %Error{message: message, context: "name resolver"}
end
