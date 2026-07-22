library(dplyr)
library(osmdata)
library(sf)
library(tmap)

setwd("Data")

#Set global parameters
tmap_mode("view")
total_workplaces <- 371010 #June 2025
sme_share <- 0.2
vo_threshold <- 51

#Load city boundary or get it from OSM
if (file.exists("boundary.gpkg")) {
  boundary <- st_read("boundary.gpkg")
  } else {
    boundary <- opq('poznan poland') %>%
    add_osm_feature('key' = 'admin_level', 'value' = '7') %>%
    osmdata_sf() %>%
    unname_osmdata_sf()
    boundary <- boundary$osm_multipolygons %>% filter(name == "Poznań")
    st_write(boundary, "boundary.gpkg")
  }
#OPTIONAL: Check if downloaded correctly
#tm_shape(boundary) + tm_polygons()

#Make 200x200m grid and aggregate BDOT10k buildings data
bbox <- st_bbox(boundary)
bbox <- st_transform(bbox, crs = 2180)
workplace_grid <- st_make_grid(bbox, c(200, 200), what = "polygons") %>%
  st_as_sf() %>%
  # Assign a unique ID to each grid cell
  mutate(grid_id = row_number())
buildings <- st_read("./work_bdot.gpkg")
buildings <- buildings %>% filter(!FUNKCJAOGOLNABUDYNKU %in% c("budynki mieszkalne",
                                                          "budynki produkcyjne, usługowe i gospodarcze dla rolnictwa",
                                                          "budynki transportu i łączności"))
buildings$total_floor_area <- as.numeric(st_area(buildings) * buildings$LICZBAKONDYGNACJI)
buildings <- st_centroid(buildings)

# Spatially join the points to the grid polygons
# st_join adds polygon attributes to the points data frame for points falling within each polygon
buildings_joined <- st_join(buildings, workplace_grid, join = st_within)

# Aggregate the 'value' variable by 'grid_id' using dplyr
# Sum the 'value' for all points within each grid cell
aggregated_data <- buildings_joined %>%
  #  filter(!is.na(grid_id)) %>% # Remove points outside the main grid extent (if any)
  group_by(grid_id) %>%
  summarise(bdot_area = sum(total_floor_area, na.rm = TRUE),
            point_count = n())
aggregated_data <- st_drop_geometry(aggregated_data)

# merge the results & clip to boundary
workplace_grid <- left_join(workplace_grid, aggregated_data, by = "grid_id")
boundary <- st_transform(boundary, crs = st_crs(workplace_grid))
workplace_grid <- st_intersection(workplace_grid, boundary)
workplace_grid <- workplace_grid %>% subset(select = c("grid_id", "bdot_area", "point_count"))
workplace_grid[is.na(workplace_grid)] <- 0
workplace_grid$bdot_weight <- workplace_grid$bdot_area / sum(workplace_grid$bdot_area)
workplace_grid <- st_make_valid(workplace_grid)
#OPTIONAL: Plot to check
#tm_shape(filter(workplace_grid, bdot_area > 0)) + tm_polygons(fill = "bdot_area", col_alpha = 0, fill_alpha = 0.5, palette = "Reds")

#Read small enterprises data
sme <- read.csv("ceidg_geocode.csv")
sme <- sme %>% filter(!is.na(g_dlug))
sme <- st_as_sf(sme, coords = c("g_dlug", "g_szer"), crs = 4326)
sme <- st_make_valid(sme)
sme <- st_transform(sme, crs = st_crs(workplace_grid))

#OPTIONAL: plot to check
#tm_shape(sme) + tm_symbols()

#Remove virtual offices
sme$street_and_number <- paste(sme$g_ul, sub("/.", "", sme$g_adr_nr), sep = " ")
sme_by_addr <- as.data.frame(table(sme$street_and_number))
sme <- left_join(sme, sme_by_addr, by = c("street_and_number" = "Var1"))
sme <- sme %>% filter(Freq < vo_threshold)

#Add SME to grid
sme_join <- st_join(sme, workplace_grid, join = st_within)
sme_per_grid <- count(as_tibble(sme_join), grid_id)
sme_per_grid <- rename(sme_per_grid, sme_count = n)
workplace_grid <- left_join(workplace_grid, sme_per_grid, by = "grid_id")
workplace_grid <- workplace_grid %>% mutate(sme_count = ifelse(is.na(sme_count), 0, sme_count))
workplace_grid$sme_weight <- workplace_grid$sme_count / sum(workplace_grid$sme_count)

#Calculate workplaces per grid cell (BDOT floor-area weight + SME count weight)
workplace_grid$workplaces <- ((workplace_grid$bdot_weight * (1 - sme_share)) +
                                (workplace_grid$sme_weight * sme_share)) *
  total_workplaces

workplace_grid <- st_transform(workplace_grid, crs = 4326)
st_write(workplace_grid, "workplace_grid.gpkg", append = FALSE)

#OPTIONAL: Plot to check
tm_shape(filter(workplace_grid, workplaces > 10)) + tm_polygons(fill = "workplaces", col_alpha = 0, fill_alpha = 0.5, palette = "Reds")
