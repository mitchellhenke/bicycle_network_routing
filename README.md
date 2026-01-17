# Bicycle Network Routing

This project is an assortment of scripts/tools for generating a very naive model of bicycle networks and routing weighted by population and jobs. It depends heavily on [brouter](https://github.com/abrensch/brouter), [OpenStreetMap](https://www.openstreetmap.org/), Census data is used for [population](https://www2.census.gov/geo/tiger/TIGER2020/TABBLOCK20/) and jobs (via [LODES](https://lehd.ces.census.gov/data)) at the Census block level. The scripts are written in Elixir.

I've written a custom brouter profile in city.brf.


## Setup

You'll need a running [brouter server](https://github.com/abrensch/brouter?tab=readme-ov-file#run-the-brouter-http-server) and Elixir to run the scripts. A [mise](https://github.com/jdx/mise) file is included to make installation of Elixir easier.

The scripts are:
 1. `merge_census_lodes.exs` is used to download, filter and merge Census data into a single GeoJSON file for use in generating and weighting source/destination points
 1. `route_requester.exs` requests routing information from brouter and outputs a GeoJSON file
 1. `merge_geojson.exs` aggregates identical segment statistics across generated routes and outputs a single GeoJSON file


## Example

As an example of generating Census data for Milwaukee County and generating routes between 100 routes between 1-5km.

```sh
$ mise install elixir
$ elixir merge_census_lodes.exs census.geojson 55079
$ elixir route_requester.exs 100 1.0 5.0 ./routes
$ elixir merge_geojson.exs "./routes/*" output.geojson
```

## Limitations

- Many things are specific to my setup, not directly configurable, and scripts will need to be modified
- Route generation is random, the script will just pick two random Census blocks and if they're different and within the right range, it will generate the route. File names are based on the source and destination, so duplicate routes are skipped if the file already exists.
- Sometimes the center of a Census block is not routeable and it doesn't try to fix it. I've made a handful of manual corrections.
