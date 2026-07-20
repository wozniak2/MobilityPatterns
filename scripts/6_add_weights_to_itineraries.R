# =============================================================================
# add_weights_to_itineraries.R
#
# Adds population and workplace weights to commuting itineraries.
#
# DEPENDENCY: Requires objects from 5_read_itineraries.R to be present
# in the environment. Run that script first, or ensure the following
# objects are loaded:
#   - pt_itineraries  : sf object, raw PT itineraries (all counties combined)
#   - car_itineraries : sf object, raw car itineraries (all counties combined)
#   - pop_grid        : sf object, population grid (pop_grid.gpkg)
#   - workplace_grid  : sf object, workplace grid (workplace_grid.gpkg)
#
# INPUT  : pt_itineraries, car_itineraries (from 5_read_itineraries.R)
# OUTPUT : itineraries_weights.csv
# =============================================================================

library(data.table)
library(dplyr)
library(sf)

setwd("/Users/wozni/Google Drive/UAM/HUB/MobilityPatterns/Data")
#Read & prepare grids
pop_grid <- st_read("pop_grid.gpkg")
workplace_grid <- st_read("workplace_grid.gpkg")

workplace_grid <- st_transform(workplace_grid, crs = st_crs(pop_grid))

pop_grid$area <- st_area(pop_grid)
pop_grid <- setDT(pop_grid)[, .SD[which.max(area)], by=grid_id] #Remove cells with duplicate IDs on municipal boundaries
pop_grid <- st_as_sf(pop_grid)

#Read & join itineraries
# Join PT and car by OD pair, then weight
od_combined <- inner_join(
  pt_itineraries  |> st_drop_geometry() |>
    select(from_id, to_id, from_lon, from_lat, to_lon, to_lat,
           county, total_duration, total_distance, mode, segment),
  car_itineraries |> st_drop_geometry() |>
    select(from_id, to_id, total_duration, total_distance) |>
    rename(car_duration = total_duration,
           car_distance = total_distance),
  by = c("from_id", "to_id")
) |>
  mutate(time_ratio = total_duration / car_duration)

# Now assign weights once — origins
itineraries_origins <- od_combined |>
  st_as_sf(coords = c("from_lon", "from_lat"), crs = 4326) |>
  st_transform(st_crs(pop_grid)) |>
  st_join(pop_grid |> select(grid_id, working_age_pop),
          join = st_intersects) |>
  st_drop_geometry() |>
  filter(!is.na(working_age_pop))

cat("After pop join:", nrow(itineraries_origins), "rows\n")

# Destinations
itineraries_weights <- itineraries_origins |>
  st_as_sf(coords = c("to_lon", "to_lat"), crs = 4326) |>
  st_transform(st_crs(workplace_grid)) |>
  st_join(workplace_grid |> select(workplaces),
          join = st_intersects) |>
  st_drop_geometry() |>
  filter(!is.na(workplaces))

cat("After workplace join:", nrow(itineraries_weights), "rows\n")

write.csv(itineraries_weights, "itineraries_weights.csv", row.names = FALSE)
