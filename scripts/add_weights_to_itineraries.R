#Add population and workplace weights to itineraries

library(data.table)
library(dplyr)
library(sf)

#Read & prepare grids
pop_grid <- st_read("pop_grid.gpkg")
workplace_grid <- st_read("workplace_grid.gpkg")

workplace_grid <- st_transform(workplace_grid, crs = st_crs(pop_grid))

pop_grid$area <- st_area(pop_grid)
pop_grid <- setDT(pop_grid)[, .SD[which.max(area)], by=grid_id] #Remove cells with duplicate IDs on municipal boundaries
pop_grid <- st_as_sf(pop_grid)

#Read & join itineraries
itineraries_list <- lapply(list.files(path = "./itineraries_csv", full.names = TRUE), read.csv)
itineraries_combined <- do.call("rbind", itineraries_list)

itineraries_origins <- st_as_sf(itineraries_combined, coords = c("from_lon", "from_lat"))
st_crs(itineraries_origins) <- st_crs(pop_grid)
#st_crs(workplace_grid) <- st_crs(pop_grid)

itineraries_pop_weights <- st_join(itineraries_origins, pop_grid, join = st_intersects)
itineraries_pop_weights <- as.data.frame(st_drop_geometry(itineraries_pop_weights))
itineraries_pop_weights <- itineraries_pop_weights %>% 
  select(!c(point_count, area)) 

itineraries_destinations <- st_as_sf(itineraries_pop_weights, coords = c("to_lon", "to_lat"))
st_crs(itineraries_destinations) <- st_crs(pop_grid)
workplace_grid <- workplace_grid %>% select(workplaces)
itineraries_weights <- st_join(itineraries_destinations, workplace_grid, join = st_intersects)
itineraries_weights <- itineraries_weights %>% filter(!is.na(working_age_pop))
itineraries_weights <- as.data.frame(st_drop_geometry(itineraries_weights))

write.csv(itineraries_weights, file = "itineraries_weights.csv", append = FALSE)