#!/usr/bin/env elixir

defmodule GeoJsonMerger do
  def merge_files(pattern, output_file) do
    files = Path.wildcard(pattern)

    if Enum.empty?(files) do
      IO.puts(:stderr, "No files matched pattern: #{pattern}")
      System.halt(1)
    end

    all_features =
      files
      |> Enum.flat_map(fn file ->
        case File.read(file) do
          {:ok, content} ->
            case JSON.decode(content) do
              {:ok, geojson} ->
                extract_features(geojson)

              {:error, reason} ->
                IO.puts(:stderr, "Error parsing #{file}: #{inspect(reason)}")
                []
            end

          {:error, reason} ->
            IO.puts(:stderr, "Error reading #{file}: #{inspect(reason)}")
            []
        end
      end)

    deduplicated_features = deduplicate_by_geometry(all_features)

    merged = %{
      "type" => "FeatureCollection",
      "features" => deduplicated_features
    }

    case File.write(output_file, JSON.encode!(merged)) do
      :ok ->
        IO.puts("Successfully merged #{length(files)} files into #{output_file}")
        IO.puts("Total features before deduplication: #{length(all_features)}")
        IO.puts("Total features after deduplication: #{length(deduplicated_features)}")

      {:error, reason} ->
        IO.puts(:stderr, "Error writing to #{output_file}: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp deduplicate_by_geometry(features) do
    features
    |> Enum.reduce(%{}, fn feature, acc ->
      geometry = feature["geometry"]
      geometry_key = JSON.encode!(geometry)

      if Map.has_key?(acc, geometry_key) do
        existing = acc[geometry_key]
        new_excess_cost = get_in(feature, ["properties", "excess_cost"])
        new_weight = get_in(feature, ["properties", "weight"])

        updated =
          update_in(existing, ["properties", "count"], &(&1 + 1))
          |> update_in(["properties", "excess_cost"], &(&1 + new_excess_cost))
          |> update_in(["properties", "weight"], &(&1 + new_weight))

        Map.put(acc, geometry_key, updated)
      else
        with_count = put_in(feature, ["properties", "count"], 1)
        Map.put(acc, geometry_key, with_count)
      end
    end)
    |> Map.values()
  end

  defp extract_features(%{"features" => features}) when is_list(features) do
    features
  end

  defp extract_features(%{"features" => _}) do
    []
  end

  defp extract_features(_) do
    []
  end
end

{_opts, args, _} = OptionParser.parse(System.argv(), strict: [])

pattern = Enum.at(args, 0)
output_file = Enum.at(args, 1)

cond do
  is_nil(pattern) ->
    IO.puts(:stderr, "Usage: elixir merge_geojson.exs <pattern> <output_file>")
    System.halt(1)

  is_nil(output_file) ->
    IO.puts(:stderr, "Usage: elixir merge_geojson.exs <pattern> <output_file>")
    System.halt(1)

  true ->
    GeoJsonMerger.merge_files(pattern, output_file)
end
