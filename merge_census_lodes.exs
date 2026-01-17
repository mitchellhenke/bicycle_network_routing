#!/usr/bin/env elixir

Mix.install([
  {:req, "~> 0.5"},
  {:json, "~> 1.4"},
  {:unzip, "~> 0.1"}
])

defmodule CensusLodesmerger do
  @census_url "https://www2.census.gov/geo/tiger/TIGER2020/TABBLOCK20/tl_2020_55_tabblock20.zip"
  @lodes_url "http://lehd.ces.census.gov/data/lodes/LODES8/wi/od/wi_od_main_JT00_2022.csv.gz"

  def main(output_file, geoid_prefix \\ nil) do
    with temp_dir <- System.tmp_dir!(),
         :ok <- download_and_process(temp_dir, output_file, geoid_prefix) do
      IO.puts("Success! Output written to #{output_file}")
    else
      error ->
        IO.puts(:stderr, "Error: #{inspect(error)}")
        System.halt(1)
    end
  end

  defp download_and_process(temp_dir, output_file, geoid_prefix) do
    IO.puts("Downloading Census shapefile...")
    census_zip = Path.join(temp_dir, "census_blocks.zip")
    download_if_not_exists(@census_url, census_zip)

    IO.puts("Extracting shapefile...")
    census_extract_dir = Path.join(temp_dir, "census_blocks")
    File.mkdir_p!(census_extract_dir)
    extract_zip(census_zip, census_extract_dir)

    # Find shapefile
    shapefile_path =
      census_extract_dir
      |> File.ls!()
      |> Enum.find(&String.ends_with?(&1, ".shp"))
      |> case do
        nil -> raise "No shapefile found in extracted Census data"
        filename -> Path.join(census_extract_dir, filename)
      end

    IO.puts("Converting shapefile to GeoJSON...")
    census_geojson = Path.join(temp_dir, "census_blocks.geojson")

    if File.exists?(census_geojson) do
      File.rm!(census_geojson)
    end

    convert_to_geojson(shapefile_path, census_geojson)

    IO.puts("Downloading LODES data...")
    lodes_gz = Path.join(temp_dir, "lodes_data.csv.gz")
    download_if_not_exists(@lodes_url, lodes_gz)

    IO.puts("Extracting LODES CSV...")
    lodes_csv = Path.join(temp_dir, "lodes_data.csv")

    if File.exists?(lodes_csv) do
      File.rm!(lodes_csv)
    end

    extract_gz(lodes_gz, lodes_csv)

    IO.puts("Loading LODES data...")
    jobs_data = load_lodes_data(lodes_csv, geoid_prefix)

    IO.puts("Loading GeoJSON...")
    geojson_data = load_geojson(census_geojson)

    IO.puts("Merging data...")
    merged_data = merge_data(geojson_data, jobs_data, geoid_prefix)

    IO.puts("Writing output to #{output_file}...")

    if File.exists?(output_file) do
      File.rm!(output_file)
    end

    output_json = JSON.encode!(merged_data)
    File.write!(output_file, output_json)

    :ok
  end

  defp download_file(url, output_path) do
    Req.get!(url, into: File.stream!(output_path, [:write, :binary]))
  end

  defp download_if_not_exists(url, output_path) do
    if File.exists?(output_path) do
      IO.puts("File already exists, skipping download: #{output_path}")
    else
      download_file(url, output_path)
    end
  end

  defp extract_zip(zip_path, extract_to) do
    {:ok, _} = :zip.extract(String.to_charlist(zip_path), cwd: String.to_charlist(extract_to))
  end

  defp extract_gz(gz_path, output_path) do
    case System.cmd("gzip", ["-d", "-c", gz_path]) do
      {content, 0} -> File.write!(output_path, content)
      {error, code} -> raise "gzip failed with code #{code}: #{error}"
    end
  end

  defp convert_to_geojson(shapefile_path, output_geojson) do
    cmd = "ogr2ogr"
    args = ["-f", "GeoJSON", output_geojson, shapefile_path]

    case System.cmd(cmd, args) do
      {_output, 0} -> :ok
      {error, code} -> {:error, "ogr2ogr failed with code #{code}: #{error}"}
    end
  end

  defp load_geojson(geojson_path) do
    geojson_path
    |> File.read!()
    |> JSON.decode!()
  end

  defp load_lodes_data(csv_path, geoid_prefix) do
    csv_path
    |> File.stream!()
    |> Stream.drop(1)
    |> Stream.map(&String.trim/1)
    |> Stream.filter(fn line ->
      case String.split(line, ",") do
        [dest_block, _home_block, _jobs_str | _rest] ->
          if geoid_prefix do
            String.starts_with?(dest_block, geoid_prefix)
          else
            true
          end

        _ ->
          false
      end
    end)
    |> Enum.reduce(%{}, fn line, acc ->
      [dest_block, _home_block, jobs_str | _rest] = String.split(line, ",")
      jobs = String.to_integer(jobs_str)
      Map.update(acc, dest_block, jobs, &(&1 + jobs))
    end)
  end

  defp merge_data(geojson_data, jobs_data, geoid_prefix) do
    features =
      geojson_data
      |> Map.fetch!("features")
      |> Stream.filter(fn feature ->
        properties = Map.fetch!(feature, "properties")
        geoid = Map.fetch!(properties, "GEOID20")

        if geoid_prefix do
          String.starts_with?(geoid, geoid_prefix)
        else
          true
        end
      end)
      |> Enum.map(fn feature ->
        properties = Map.fetch!(feature, "properties")

        geoid = Map.fetch!(properties, "GEOID20")
        jobs = Map.get(jobs_data, geoid, 0)

        population = Map.fetch!(properties, "POP20")

        feature
        |> Map.put(
          "properties",
          properties
          |> Map.put("jobs", jobs)
          |> Map.put("population", population)
        )
      end)

    Map.put(geojson_data, "features", features)
  end
end

# Parse command line arguments
case System.argv() do
  [output_file] ->
    CensusLodesmerger.main(output_file)

  [output_file, geoid_prefix] ->
    CensusLodesmerger.main(output_file, geoid_prefix)

  _ ->
    IO.puts(:stderr, "Usage: merge_census_lodes.exs <output_file> [geoid_prefix]")
    IO.puts(:stderr, "  output_file: Path to output GeoJSON file")

    IO.puts(
      :stderr,
      "  geoid_prefix: Optional GEOID prefix to filter by (e.g., '55001' for Dane County)"
    )

    System.halt(1)
end
