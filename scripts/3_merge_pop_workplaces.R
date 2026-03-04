library(sf)
library(dplyr) 
library(ggnewscale)
#library(terra)

setwd("/Users/wozni/Google Drive/UAM/HUB/MobilityPatterns/Data")

# grids
pop_grid <- st_read("popgrid.gpkg")
wp_grid <- st_read("workplace_grid.gpkg")

# boundry for Poznan agglomeration
ap <- st_read("ap.gpkg") ## city
poz <- st_read("poz.gpkg") ## donut

# merging, cleaning
boundaries <- st_union(ap, poz, is_coverage = TRUE) %>%
  st_make_valid()

boundaries <- st_union(boundaries)

colnames(pop_grid)[2] <- "population"

# some osm feature
bbox <- st_bbox(pop_grid)
osm_highways <- opq(bbox = bbox) %>% 
  add_osm_feature(key = 'highway', value = c("motorway", "primary", "secondary"))  %>% 
  osmdata_sf()

# cut roads to boundaries
osm_highways$osm_lines <- st_transform(osm_highways$osm_lines, crs = st_crs(boundaries))
intersected_roads <- st_intersection(osm_highways$osm_lines, boundaries)

# Spatially join the grids
data_joined <- st_join(wp_grid, pop_grid, join = st_within)

# Aggregate the 'value' variable 'id'
# Sum the 'value' for all points within each grid cell
aggregated_data <- data_joined %>%
  group_by(grid_id.y) %>%
  summarise(total_value = sum(workplaces, na.rm = TRUE), 
            point_count = n()) # Also count points per cell


colnames(aggregated_data)[1:2] <-c("grid_id", "total_workplaces")
aggregated_data <- st_drop_geometry(aggregated_data)

# Join the aggregated data back to the polygon grid
# Use a standard left_join from dplyr to merge the results
final_grid <- left_join(pop_grid, aggregated_data, by = "grid_id")


# remove zeros for better visu
final_grid <- final_grid %>% mutate_at(c('total_workplaces'), ~na_if(., 0))

## plot population and workplaces
ggplot(data = final_grid) +
  geom_sf(aes(geometry = geom, fill = total_workplaces), color=NA, lwd = 0.1, alpha = 1) +
  scale_fill_viridis_c(begin = 0.2, end = 1, na.value = "transparent") +
  new_scale_fill() +
  geom_sf(aes(geometry = geom, fill = population), color="lightgrey", lwd = 0.1, alpha = 0.5) +
  scale_fill_viridis_c(begin = 0, end = 1, option = "plasma") +
  geom_sf(data = ap, fill = NA, lwd = 0.5) +
  geom_sf(data = intersected_roads, lwd = 0.3, color = "yellow", alpha = 0.7)
  
