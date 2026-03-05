library(sf)
library(dplyr) 
library(ggnewscale)
library(patchwork)
#library(terra)

setwd("/Users/wozni/Google Drive/UAM/HUB/MobilityPatterns/Data")

# grids
pop_grid <- st_read("popgrid.gpkg")
wp_grid <- st_read("workplace_grid.gpkg")

# boundry for Poznan agglomeration
ap <- st_read("ap.gpkg") ## city
poz <- st_read("poz.gpkg") ## donut

# OD flows
OD_flows <- read.csv("OD_flows.csv")

# merging, cleaning
boundaries <- st_union(ap, poz, is_coverage = TRUE) %>%
  st_make_valid()

boundaries <- st_union(boundaries)

colnames(pop_grid)[2] <- "population"

# OD flows + sf
# join and write 
OD_sf <- left_join(ap, OD_flows, by = "JPT_ID")
st_write(OD_sf, "OD_sf.gpkg", append = FALSE)

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

## add commuters and write
OD_sf <- st_transform(OD_sf, st_crs(final_grid))
ff_grid <- st_join(final_grid, OD_sf)
st_write(ff_grid, "pop_wp_flows_grid.gpkg", append = FALSE)

# remove zeros for better visu
final_grid <- final_grid %>% mutate_at(c('total_workplaces'), ~na_if(., 0))
final_grid <- final_grid %>% mutate_at(c('population'), ~na_if(., 0))

# write final grids to file
st_write(final_grid, "pop_workplaces_grid.gpkg", append = FALSE)

## plot population and workplaces
p1 <- ggplot(data = final_grid) +
  geom_sf(aes(geometry = geom, fill = population), color="transparent", alpha = 0.7) +
  scale_fill_viridis_c(begin = 0.1, end = 1, option = "plasma", na.value = NA) +
  ggnewscale::new_scale_fill() +
  geom_sf(aes(geometry = geom, fill = total_workplaces), color="transparent", alpha = 1) +
  scale_fill_viridis_c(begin = 0.1, end = 1, na.value = NA) +
  geom_sf(data = ap, fill = NA, lwd = 0.5) +
  geom_sf(data = intersected_roads, lwd = 0.3, color = "yellow", alpha = 1) +
  theme_bw() +
  theme(legend.background = element_rect(fill = "transparent"),
        legend.box.background = element_rect(fill = "transparent"),
        panel.background = element_rect(fill = "transparent"),
        panel.grid.major = element_blank(),
        panel.grid.minor = element_blank(),
        plot.background = element_rect(fill = "transparent",
                                       color = NA))
  

p2 <- ggplot(data = OD_sf) +
  geom_sf(aes(fill = commuters), color="black", lwd = 0.1, alpha = 0.7) +
  scale_fill_viridis_c(begin = 0.2, end = 1, option = "plasma", na.value = "transparent") +
  theme_bw() +
  theme(legend.background = element_rect(fill = "transparent"),
        legend.box.background = element_rect(fill = "transparent"),
        panel.background = element_rect(fill = "transparent"),
        panel.grid.major = element_blank(),
        panel.grid.minor = element_blank(),
        plot.background = element_rect(fill = "transparent",
                                       color = NA))


## plot all together
p1 + p2





