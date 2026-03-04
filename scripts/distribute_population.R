library(sf)
library(readr)

setwd("/Users/wozni/Google Drive/UAM/HUB/MobilityPatterns/Data")

# boundry for Poznan agglomeration
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


# Create a polygon grid that covers the extent of the points
# n argument defines the dimensions of the grid

grid_poly <- st_make_grid(bbox, n=c(100,100), what = "polygons") %>%
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

## plot population
ggplot()+
#  geom_sf(data = pop_geocoded, aes(color = WIEK_26_DO_60), size = 0.3, alpha = 0.2) +
  geom_sf(data = final_grid, aes(fill = total_value), color="lightgrey", lwd = 0.1, alpha = 0.7) +
  geom_sf(data = ap, fill = NA, lwd = 0.5) +
  scale_fill_viridis_c(begin = 0.1, end = 1, na.value = "transparent")


## export population grid
st_write(final_grid, "popgrid.gpkg")
