defmodule Packfs.Shared.Selection do
  @moduledoc "Parses repeatable archive IDs, comma lists, and inclusive ranges."

  @spec parse([String.t()], non_neg_integer()) ::
          {:ok, MapSet.t(non_neg_integer())} | {:error, String.t()}
  def parse([], count), do: {:ok, MapSet.new(archive_ids(count))}

  def parse(values, count) do
    with {:ok, ids} <- parse_values(values),
         :ok <- validate_ids(ids, count) do
      {:ok, MapSet.new(ids)}
    end
  end

  ###
  ### Helpers
  ###

  defp archive_ids(0), do: []
  defp archive_ids(count), do: 0..(count - 1)

  defp parse_values(values) do
    result =
      values
      |> Enum.flat_map(&String.split(&1, ",", trim: true))
      |> Enum.reduce_while([], &reduce_value/2)

    case result do
      {:error, message} -> {:error, message}
      ids -> {:ok, ids}
    end
  end

  defp reduce_value(value, ids) do
    case parse_value(value) do
      {:ok, parsed} -> {:cont, parsed ++ ids}
      {:error, message} -> {:halt, {:error, message}}
    end
  end

  defp parse_value(value) do
    case String.split(value, "-", parts: 2) do
      [single] -> parse_single(single)
      [first, last] -> parse_range(first, last)
    end
  end

  defp parse_single(value) do
    case parse_integer(value) do
      {:ok, integer} -> {:ok, [integer]}
      {:error, message} -> {:error, message}
    end
  end

  defp parse_range(first, last) do
    with {:ok, first_id} <- parse_integer(first),
         {:ok, last_id} <- parse_integer(last),
         true <- first_id <= last_id do
      {:ok, Enum.to_list(first_id..last_id)}
    else
      false -> {:error, "archive range starts after it ends: #{first}-#{last}"}
      {:error, _message} = error -> error
    end
  end

  defp parse_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _other -> {:error, "invalid archive selection: #{inspect(value)}"}
    end
  end

  defp validate_ids(ids, count) do
    case Enum.find(ids, &(&1 >= count)) do
      nil -> :ok
      id -> {:error, "archive #{id} is outside 0..#{max(count - 1, 0)}"}
    end
  end
end
