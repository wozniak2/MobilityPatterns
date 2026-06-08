library(dplyr)
library(ggplot2)
library(ggpubr)
library(sf)
library(readr)
library(terra)

setwd("/Users/wozni/Google Drive/UAM/HUB/MobilityPatterns/Data")

# boundary for Poznan agglomeration
ap <- st_read("ap.gpkg")
# population data
pop_geocoded <- read_csv("pop_geocoded.csv")

# Remove rows with any missing values 
pop_geocoded <- pop_geocoded[complete.cases(pop_geocoded$g_dlug), ]

## sf object
pop_geocoded <- st_as_sf(
  pop_geocoded,
  coords = c("g_dlug", "g_szer"),
  crs = 4326
)

# Get the bounding box for ap
bbox <- st_bbox(ap)
bbox <- st_transform(bbox, crs = 2180)

# Create a polygon grid that covers the extent of the points
# cellsize argument defines the dimensions of the grid (in meters)

grid_poly <- st_make_grid(bbox, c(200, 200), what = "polygons") %>%
  st_as_sf() %>%
  # Assign a unique ID to each grid cell
  mutate(grid_id = row_number())

grid_poly <- st_transform(grid_poly, crs = st_crs(pop_geocoded))

# Spatially join the points to the grid polygons
# st_join adds polygon attributes to the points data frame for points falling within each polygon
points_joined <- st_join(pop_geocoded, grid_poly, join = st_within)

# Aggregate the 'value' variable by 'grid_id' using dplyr
# Sum the 'value' for all points within each grid cell
aggregated_data <- points_joined %>%
#  filter(!is.na(grid_id)) %>% # Remove points outside the main grid extent (if any)
  group_by(grid_id) %>%
  summarise(total_value = sum(WIEK_26_DO_60, na.rm = TRUE), 
            point_count = n())

aggregated_data <- st_drop_geometry(aggregated_data)

# merge the results
final_grid <- left_join(grid_poly, aggregated_data, by = "grid_id")

# join with municipality data & clean-up
ap <- st_transform(ap, st_crs(final_grid))
final_grid <- st_intersection(final_grid, ap)
final_grid <- rename(final_grid, c(working_age_pop = total_value, municipality = JPT_NAZWA_)) %>% 
  subset(select = c("grid_id", "working_age_pop", "point_count", "municipality")) #Make human-readable & clean

final_grid$municipality_short <- sub(" - ", "_", final_grid$municipality)
final_grid$municipality_short <- sub("obszar wiejski", "W", final_grid$municipality_short)
final_grid$municipality_short <- sub("miasto", "M", final_grid$municipality_short)
final_grid$municipality_short <- sub("_gmina wiejska", "", final_grid$municipality_short)
final_grid$municipality_short <- sub("_gmina miejska", "", final_grid$municipality_short)
final_grid$municipality_short <- sub(" ", "_", final_grid$municipality_short)

## plot population
ggplot()+
#  geom_sf(data = pop_geocoded, aes(color = WIEK_26_DO_60), size = 0.3, alpha = 0.2) +
  geom_sf(data = final_grid, aes(fill = working_age_pop), color="lightgrey", lwd = 0.1, alpha = 0.7) +
  geom_sf(data = ap, fill = NA, lwd = 0.5) +
  scale_fill_viridis_c(begin = 0.1, end = 1, na.value = "transparent")


## export population grid
st_write(final_grid, "pop_grid.gpkg", append = FALSE)
