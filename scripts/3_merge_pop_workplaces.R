library(sf)
library(dplyr)
library(ggplot2)
library(ggnewscale)
library(patchwork)
library(osmdata)

setwd("Data")

# grids
pop_grid <- st_read("pop_grid.gpkg")
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

# colnames(pop_grid)[2] <- "population"

# OD flows + sf
# join and write 
OD_sf <- left_join(ap, OD_flows, by = "JPT_ID")
st_write(OD_sf, "OD_sf.gpkg", append = FALSE)

# some osm feature
bbox <- st_bbox(pop_grid)
osm_highways <- opq(bbox = bbox, timeout = 180) %>% 
  add_osm_feature(key = 'highway', value = c("motorway", "primary", "secondary"))  %>% 
  osmdata_sf()

# cut roads to boundaries
osm_highways$osm_lines <- st_transform(osm_highways$osm_lines, crs = st_crs(boundaries))
intersected_roads <- st_intersection(osm_highways$osm_lines, boundaries)

# Spatially join the grids (produces grid_id.x from wp_grid, grid_id.y from pop_grid)
data_joined <- st_join(wp_grid, pop_grid)

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
data_joined <- data_joined %>% mutate_at(c('workplaces'), ~na_if(., 0))
#final_grid <- final_grid %>% mutate_at(c('working_age_pop'), ~na_if(., 0))

# write final grids to file
st_write(final_grid, "pop_workplaces_grid.gpkg", append = FALSE)

## plot population and workplaces
p1 <- ggplot(data = data_joined) +
  geom_sf(aes(geometry = geom, fill = working_age_pop), color="transparent", alpha = 1) +
  scale_fill_viridis_c(begin = 0.1, end = 1, option = "viridis", na.value = NA) +
  ggnewscale::new_scale_fill() +
  geom_sf(aes(geometry = geom, fill = workplaces), color="transparent", alpha = 1) +
  scale_fill_viridis_c(begin = 0.1, end = 1, option = "plasma", na.value = NA) +
  geom_sf(data = ap, fill = NA, lwd = 0.5, color="white") +
  geom_sf(data = intersected_roads, lwd = 0.1, color = "white", alpha = 0.6) +
  theme_dark() +
  theme(
    panel.background  = element_rect(fill = "#1a1a1a"),
    plot.background   = element_rect(fill = "#1a1a1a"),
    legend.background = element_rect(fill = "#1a1a1a"),
    legend.key        = element_rect(fill = "#1a1a1a"),
    text              = element_text(color = "white"),
    axis.text         = element_blank(),
    axis.title        = element_blank(),
    legend.title      = element_text(size = 14, color = "white"),
    legend.text       = element_text(size = 14, color = "white"),
    panel.grid.major  = element_blank(),
    panel.grid.minor  = element_blank()
  ) +
  guides(color = guide_legend(override.aes = list(size = 5)))

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





