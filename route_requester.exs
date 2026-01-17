#!/usr/bin/env elixir

Mix.install([
  {:req, "~> 0.4"},
  {:geo, ">= 0.0.1"},
  {:decimal, ">= 0.0.1"}
])

defmodule RouteFinder do
  @fixed_centroids %{
    [-87.90781, 43.0446435] => [-87.908435, 43.044649],
    [-87.91735, 43.044312] => [-87.916086, 43.044268],
    [-87.9173505, 43.044311500000006] => [-87.916066, 43.044212],
    [-87.930762, 43.053942] => [-87.932313, 43.054875],
    [-87.901187, 43.039687] => [-87.901449, 43.04026],
    [-87.983029, 43.144908] => [-87.983581, 43.144911],
    [-87.936583, 43.0450925] => [-87.936594, 43.045798],
    [-88.0315855, 43.072317999999996] => [-88.035276, 43.072747],
    [-87.938816, 43.0319675] => [-87.938888, 43.031483],
    [-87.995225, 43.15287] => [-87.998828, 43.155958],
    [-87.966366, 42.9673435] => [-87.966371, 42.966663],
    [-88.0503365, 42.963963500000006] => [-88.050583, 42.966328],
    [-87.991423, 42.972942] => [-87.991487, 42.973807],
    [-87.91964999999999, 43.041537500000004] => [-87.920179, 43.041521],
    [-87.925737, 42.989200499999995] => [-87.92574, 42.989991],
    [-87.9907795, 42.953223] => [-87.992401, 42.953182],
    [-87.9277925, 43.037424] => [-87.927897, 43.038573],
    [-87.9403775, 43.029298999999995] => [-87.94066, 43.031434]
  }

  def haversine_distance([lon1, lat1 | _], [lon2, lat2 | _]) do
    # Earth radius in km
    r = 6371
    lat1_rad = lat1 * :math.pi() / 180
    lat2_rad = lat2 * :math.pi() / 180
    dlat = (lat2 - lat1) * :math.pi() / 180
    dlon = (lon2 - lon1) * :math.pi() / 180

    a =
      :math.sin(dlat / 2) * :math.sin(dlat / 2) +
        :math.cos(lat1_rad) * :math.cos(lat2_rad) *
          :math.sin(dlon / 2) * :math.sin(dlon / 2)

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
    r * c
  end

  def polygon_center(%Geo.Polygon{coordinates: coordinates}) do
    {x_min, y_min, x_max, y_max} =
      List.flatten(coordinates)
      |> Enum.reduce({nil, nil, nil, nil}, fn {x, y}, {x_min, y_min, x_max, y_max} ->
        if is_nil(x_min) do
          {x, y, x, y}
        else
          x_min = Enum.min([x_min, x])
          y_min = Enum.min([y_min, y])
          x_max = Enum.max([x_max, x])
          y_max = Enum.max([y_max, y])

          {x_min, y_min, x_max, y_max}
        end
      end)

    [(x_min + x_max) / 2, (y_min + y_max) / 2]
  end

  def get_point_pairs(
        geojson_file,
        min_distance,
        max_distance,
        num_pairs,
        output_dir
      ) do
    points = File.read!(geojson_file) |> JSON.decode!()

    points =
      points["features"]
      |> Enum.reduce([], fn feature, acc ->
        feature = Geo.JSON.decode!(feature)
        population = Map.fetch!(feature.properties, "population")
        jobs = Map.fetch!(feature.properties, "jobs")

        cond do
          is_struct(feature, Geo.Point) ->
            {lng, lat} = feature.coordinates
            [[lng, lat, population, jobs] | acc]

          is_struct(feature, Geo.Polygon) ->
            [lng, lat] = polygon_center(feature)

            [lng, lat] = Map.get(@fixed_centroids, [lng, lat], [lng, lat])
            [[lng, lat, population, jobs] | acc]

          true ->
            acc
        end
      end)

    # Randomly sample pairs until we have enough
    Stream.repeatedly(fn ->
      p1 = Enum.random(points)
      p2 = Enum.random(points)
      {p1, p2}
    end)
    |> Stream.filter(fn {p1, p2} ->
      {[_, _, pop1, job1], [_, _, pop2, job2]} = {p1, p2}

      if p1 != p2 && pop1 + job1 > 0 && pop2 + job2 > 0 do
        haversine_distance = haversine_distance(p1, p2)
        haversine_distance <= max_distance and haversine_distance >= min_distance
      else
        false
      end
    end)
    # |> Stream.map(fn {p1, p2} ->
    |> Task.async_stream(fn {p1, p2} ->
      make_request({p1, p2}, output_dir)
      {p1, p2}
    end)
    |> Enum.take(num_pairs)
  end

  def make_request({[lon1, lat1, pop1, job1], [lon2, lat2, pop2, job2]}, output_dir) do
    lonlats = "#{lon1},#{lat1}|#{lon2},#{lat2}"
    filename = Path.join(output_dir, "response_#{lonlats}.geojson")

    debug_route =
      "http://localhost:8080/#map=10/43.0397/-87.8931/standard&lonlats=#{lon1},#{lat1};#{lon2},#{lat2}"

    weight = pop1 + pop2 + job1 + job2

    port =
      [17777, 17778, 17779, 17780]
      |> Enum.random()

    params = [lonlats: lonlats, profile: "city", alternativeidx: 0, format: "geojson"]

    if !File.exists?(filename) do
      case Req.get("http://localhost:#{port}/brouter",
             params: params
           ) do
        {:ok, response} ->
          if is_map(response.body) do
            body =
              process_geojson(response.body, weight)
              |> JSON.encode!()

            File.write!(filename, body)
          else
            IO.inspect("#{debug_route} is invalid with weight #{weight}")
          end

        {:error, reason} ->
          IO.puts(:stderr, "Request failed: #{inspect(reason)}")
      end
    end
  end

  def process_geojson(%{"features" => [feature | _]}, weight) do
    geometry = feature["geometry"]
    properties = feature["properties"]

    unless geometry["type"] == "LineString" do
      raise "Feature must be a LineString"
    end

    coordinates = geometry["coordinates"]
    messages = properties["messages"]

    unless is_list(messages) and length(messages) >= 2 do
      raise "Messages array not found or too short"
    end

    [headers | data_rows] = messages

    # Extract message coordinates and find their positions in the linestring
    # The brouter response has a "messages" attribute which has values like
    # CostPerKm, distance, tags, etc. The corresponding LineString segments may
    # be represented by multiple messages. This part of the process combines
    # the messages and splits into multiple LineStrings where necessary.
    {message_positions, _} =
      data_rows
      |> Enum.reduce({[], 0}, fn segment_data, {positions, search_from} ->
        lon_str = Enum.at(segment_data, 0)
        lat_str = Enum.at(segment_data, 1)

        lon = Decimal.new(String.to_integer(lon_str)) |> Decimal.div(Decimal.new(1_000_000))
        lat = Decimal.new(String.to_integer(lat_str)) |> Decimal.div(Decimal.new(1_000_000))

        # Find the next matching coordinate index starting from search_from
        coord_index =
          coordinates
          |> Enum.drop(search_from)
          |> Enum.find_index(fn [c_lon, c_lat | _] ->
            Decimal.equal?(Decimal.new(to_string(c_lon)), lon) and
              Decimal.equal?(Decimal.new(to_string(c_lat)), lat)
          end)
          |> case do
            nil -> nil
            idx -> idx + search_from
          end

        {positions ++ [{segment_data, coord_index}], coord_index || search_from}
      end)

    # Build features for segments between message positions
    new_features =
      message_positions
      |> Enum.with_index()
      |> Enum.reduce([], fn {{segment_data, coord_index}, msg_idx}, acc ->
        if is_nil(coord_index) do
          lon_str = Enum.at(segment_data, 0)
          lat_str = Enum.at(segment_data, 1)

          IO.inspect(
            "Warning: Message coordinate [#{lon_str}, #{lat_str}] not found in LineString at message index #{msg_idx}"
          )

          acc
        else
          # Determine the segment range for this message
          start_idx =
            if msg_idx == 0 do
              0
            else
              case Enum.at(message_positions, msg_idx - 1) do
                {_, prev_idx} when not is_nil(prev_idx) -> prev_idx
                _ -> 0
              end
            end

          end_idx = coord_index

          # Skip if no segments to create (e.g., first message at starting point)
          if start_idx >= end_idx do
            acc
          else
            # Create features for all segments in this range
            segments =
              start_idx..(end_idx - 1)
              |> Enum.reduce([], fn seg_idx, seg_acc ->
                segment_coords = [
                  Enum.take(Enum.at(coordinates, seg_idx), 2),
                  Enum.take(Enum.at(coordinates, seg_idx + 1), 2)
                ]

                segment_props =
                  build_segment_properties(headers, segment_data, seg_idx, properties, weight)

                new_feature = %{
                  "type" => "Feature",
                  "properties" => segment_props,
                  "geometry" => %{
                    "type" => "LineString",
                    "coordinates" => segment_coords
                  }
                }

                [new_feature | seg_acc]
              end)
              |> Enum.reverse()

            acc ++ segments
          end
        end
      end)

    %{
      "type" => "FeatureCollection",
      "features" => new_features
    }
  end

  # Calculate a rough "excess" cost where any cost above $1,050/km is excessive.
  def build_segment_properties(headers, segment_data, index, _properties, weight) do
    headers
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {header, i}, acc ->
      if header == "CostPerKm" do
        cost_per_km =
          Enum.at(segment_data, i)
          |> String.to_integer()

        excess_cost = weight * max(cost_per_km - 1_050, 0)

        Map.put(acc, "excess_cost", excess_cost)
        |> Map.put("cost_per_km", cost_per_km)
      else
        acc
      end
    end)
    |> Map.put("index", index)
    |> Map.put("weight", weight)
  end
end

{_opts, args, _} = OptionParser.parse(System.argv(), strict: [])

num_pairs = String.to_integer(Enum.at(args, 0) || "1")
min_distance = String.to_float(Enum.at(args, 1) || "1.0")
max_distance = String.to_float(Enum.at(args, 2) || "1.0")
output_dir = Enum.at(args, 3) || "."

File.mkdir_p!(output_dir)

pairs =
  RouteFinder.get_point_pairs(
    "census.geojson",
    min_distance,
    max_distance,
    num_pairs,
    output_dir
  )

IO.puts("Completed #{length(pairs)} requests")
