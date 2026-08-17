defmodule Packfs.Format.Names do
  @moduledoc "Resolves PackFS hash pairs from bundled and user-supplied path sets."

  alias Packfs.Format.Error
  alias Packfs.Format.Path, as: VirtualPath
  alias Packfs.Format.ResolvedName

  @sets %{
    "gfdm-v4" => %{sources: ["gfdm-v4.txt"], updates: []},
    "gfdm-v5" => %{sources: ["gfdm-v5.txt"], updates: []},
    "gfdm-v6" => %{sources: ["gfdm-v6.txt"], updates: []},
    "gfdm-v7" => %{sources: ["gfdm-v7.txt"], updates: []},
    "gfdm-v8" => %{sources: ["gfdm-v8.txt"], updates: []},
    "gfdm-xg1" => %{sources: ["gfdm-xg1.txt"], updates: []},
    "jubeat" => %{
      sources: ["jubeat.txt"],
      updates: [
        %{
          name: "pre-update",
          crc32_init: 0xD9AD63CB,
          crc16_init: 0x059A,
          sources: ["jubeat-pre-update.txt"]
        }
      ]
    },
    "jubeat-ripples" => %{sources: ["jubeat-ripples.txt"], updates: []},
    "jubeat-ripples-append" => %{
      sources: ["jubeat-ripples-append.txt"],
      updates: []
    }
  }

  @type hash_pair :: {non_neg_integer(), non_neg_integer()}

  @type update :: %{
          required(:name) => String.t(),
          required(:crc32_init) => non_neg_integer(),
          required(:crc16_init) => non_neg_integer(),
          optional(:sources) => [String.t()]
        }

  @type result :: %{
          paths: %{hash_pair() => ResolvedName.t()},
          warnings: [String.t()]
        }

  @spec resolve(
          [Packfs.Format.FileRecord.t()],
          [String.t()],
          [Path.t()],
          [update()]
        ) :: {:ok, result()} | {:error, Error.t()}
  def resolve(records, selected_sets \\ ["all"], name_files \\ [], custom_updates \\ []) do
    wanted = records |> Enum.map(&{&1.crc32, &1.crc16}) |> MapSet.new()

    with {:ok, bundled_sources, bundled_updates} <- bundled_sources(selected_sets),
         {:ok, updates} <- merge_updates(bundled_updates, custom_updates),
         {:ok, state} <-
           load_sources(
             bundled_sources,
             wanted,
             0,
             regular_domains(custom_updates),
             empty_state()
           ),
         {:ok, state} <- load_update_sources(updates, wanted, state),
         {:ok, state} <-
           load_sources(name_files, wanted, 1, regular_domains(custom_updates), state) do
      {:ok, finalize(state)}
    end
  end

  @spec available_sets() :: [String.t()]
  def available_sets, do: ["all" | @sets |> Map.keys() |> Enum.sort()]

  ###
  ### Helpers
  ###

  defp bundled_sources(selected_sets) do
    selected_sets
    |> expand_all()
    |> Enum.reduce_while({[], []}, &add_set/2)
    |> case do
      {:error, reason} ->
        {:error, reason}

      {filenames, updates} ->
        {:ok, source_paths(Enum.reverse(filenames)), Enum.reverse(updates)}
    end
  end

  defp expand_all(sets) do
    if "all" in sets, do: Map.keys(@sets), else: Enum.uniq(sets)
  end

  defp add_set(set, {sources, updates}) do
    case Map.fetch(@sets, set) do
      {:ok, definition} ->
        {:cont,
         {
           Enum.reverse(definition.sources, sources),
           Enum.reverse(definition.updates, updates)
         }}

      :error ->
        {:halt, {:error, error("unknown name set #{inspect(set)}")}}
    end
  end

  defp source_paths(filenames) do
    names_root = Path.join(priv_dir(), "names")
    filenames |> Enum.uniq() |> Enum.map(&Path.join(names_root, &1))
  end

  defp merge_updates(bundled, custom) do
    updates = bundled ++ Enum.map(custom, &Map.put_new(&1, :sources, []))

    case Enum.reduce_while(updates, %{}, &merge_update/2) do
      {:error, reason} -> {:error, reason}
      merged -> {:ok, Map.values(merged)}
    end
  end

  defp merge_update(update, merged) do
    case Map.get(merged, update.name) do
      nil ->
        {:cont, Map.put(merged, update.name, update)}

      existing ->
        merge_matching_update(existing, update, merged)
    end
  end

  defp merge_matching_update(existing, update, merged) do
    if same_initials?(existing, update) do
      sources = Enum.uniq(existing.sources ++ update.sources)
      {:cont, Map.put(merged, update.name, %{existing | sources: sources})}
    else
      {:halt, {:error, error("update #{inspect(update.name)} has conflicting CRC initials")}}
    end
  end

  defp same_initials?(left, right) do
    left.crc32_init == right.crc32_init and left.crc16_init == right.crc16_init
  end

  defp regular_domains(custom_updates) do
    [:runtime | Enum.map(custom_updates, &update_domain/1)]
  end

  defp load_update_sources(updates, wanted, initial) do
    Enum.reduce_while(updates, {:ok, initial}, fn update, {:ok, state} ->
      sources = source_paths(update.sources)

      case load_sources(sources, wanted, 0, [update_domain(update)], state) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp update_domain(update) do
    {:update, update.name, update.crc32_init, update.crc16_init}
  end

  defp load_sources(sources, wanted, priority, domains, initial) do
    case Enum.reduce_while(sources, initial, fn source, state ->
           reduce_source(source, state, wanted, priority, domains)
         end) do
      {:error, reason} -> {:error, reason}
      state -> {:ok, state}
    end
  end

  defp reduce_source(source, state, wanted, priority, domains) do
    case load_source(source, wanted, priority, domains, state) do
      {:ok, updated} -> {:cont, updated}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp load_source(source, wanted, priority, domains, state) do
    case File.read(source) do
      {:ok, contents} -> add_source_contents(contents, wanted, priority, domains, state)
      {:error, reason} -> {:error, source_error(source, reason)}
    end
  end

  defp add_source_contents(contents, wanted, priority, domains, state) do
    updated =
      contents
      |> String.split("\n")
      |> Enum.reduce(state, fn line, current ->
        add_line(line, current, wanted, priority, domains)
      end)

    {:ok, updated}
  end

  defp source_error(source, reason) do
    message = "cannot read name source #{source}: #{:file.format_error(reason)}"
    error(message)
  end

  defp add_line(line, state, wanted, priority, domains) do
    line
    |> String.trim()
    |> add_candidate(state, wanted, priority, domains)
  end

  defp add_candidate("", state, _wanted, _priority, _domains), do: state
  defp add_candidate("#" <> _comment, state, _wanted, _priority, _domains), do: state

  defp add_candidate(candidate, state, wanted, priority, domains) do
    canonical = VirtualPath.normalize(candidate)

    Enum.reduce(domains, state, fn domain, current ->
      hash = hash(canonical, domain)
      name = %ResolvedName{path: canonical, update: update_name(domain)}
      maybe_add_candidate(current, hash, name, wanted, priority)
    end)
  end

  defp hash(path, :runtime), do: VirtualPath.hash(path)

  defp hash(path, {:update, _name, crc32_init, crc16_init}) do
    VirtualPath.hash(path, crc32_init, crc16_init)
  end

  defp update_name(:runtime), do: nil
  defp update_name({:update, name, _crc32_init, _crc16_init}), do: name

  defp maybe_add_candidate(state, hash, name, wanted, priority) do
    add_wanted_candidate(state, hash, name, priority, MapSet.member?(wanted, hash))
  end

  defp add_wanted_candidate(state, _hash, _name, _priority, false), do: state

  defp add_wanted_candidate(state, hash, name, priority, true) do
    state.candidates
    |> Map.get(hash)
    |> update_candidate(state, hash, name, priority)
  end

  defp update_candidate(nil, state, hash, name, priority) do
    candidate = %{priority: priority, names: MapSet.new([name])}
    put_in(state, [:candidates, hash], candidate)
  end

  defp update_candidate(%{priority: current}, state, hash, name, priority)
       when priority > current do
    candidate = %{priority: priority, names: MapSet.new([name])}
    put_in(state, [:candidates, hash], candidate)
  end

  defp update_candidate(%{priority: current}, state, _hash, _name, priority)
       when priority < current do
    state
  end

  defp update_candidate(candidate, state, hash, name, _priority) do
    updated = %{candidate | names: MapSet.put(candidate.names, name)}
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

  defp resolve_candidate(hash, %{names: names}, {resolved, warnings}) do
    case MapSet.to_list(names) do
      [name] -> {Map.put(resolved, hash, name), warnings}
      ambiguous -> {resolved, [collision_warning(hash, ambiguous) | warnings]}
    end
  end

  defp collision_warning({crc32, crc16}, names) do
    formatted = names |> Enum.map(&format_name/1) |> Enum.sort() |> Enum.join(", ")
    "ambiguous path hash #{hex(crc32, 8)}-#{hex(crc16, 4)}: #{formatted}"
  end

  defp format_name(%ResolvedName{path: path, update: nil}), do: path

  defp format_name(%ResolvedName{path: path, update: update}) do
    "#{path} [update #{update}]"
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
