library(dplyr)
library(osmdata)
library(sf)
library(terra)
library(tmap)

setwd("C:/Users/wozni/OneDrive/Pulpit/MobilityPatterns/Data")

#Set global parameters
tmap_mode("view")
total_workplaces <- 371010 #June 2025
ghsl_share <- 0.8
sme_share <- 0.2

#Get city boundary from OSM
boundary <- opq('poznan poland') %>% 
  add_osm_feature('key' = 'admin_level', 'value' = '7') %>% 
  osmdata_sf() %>% 
  unname_osmdata_sf()
boundary <- boundary$osm_multipolygons %>% filter(name == "Poznań")

#OPTIONAL: Check if downloaded correctly
#tm_shape(boundary) + tm_polygons()

#Load GHSL non-residential volume grid
ghsl_nonres <- rast("GHS_BUILT_V_NRES_E2025_GLOBE_R2023A_54009_100_V1_0_R3_C20.tif")
boundary <- st_transform(boundary, st_crs(ghsl_nonres))

#Crop to boundary extent and vectorize
ghsl_nonres <- crop(ghsl_nonres, boundary)
ghsl_nonres <- as.polygons(ghsl_nonres, aggregate = FALSE) %>% st_as_sf()

#Make workplaces grid
workplace_grid <- st_intersection(ghsl_nonres, boundary)
workplace_grid <- rename(workplace_grid, nonres_volume = GHS_BUILT_V_NRES_E2025_GLOBE_R2023A_54009_100_V1_0_R3_C20) %>% 
  subset(select = "nonres_volume") #%>% filter(nonres_volume > 0) #Make human-readable & clean
workplace_grid$nonres_weight <- workplace_grid$nonres_volume / sum(workplace_grid$nonres_volume)
workplace_grid <- workplace_grid %>% mutate(grid_id = row_number())
workplace_grid <- st_transform(workplace_grid, st_crs <- 4326)
workplace_grid <- st_make_valid(workplace_grid)

#OPTIONAL: Plot to check
#tm_shape(workplace_grid) + tm_polygons(fill = "nonres_volume", col_alpha = 0, palette = "Reds")

#Read small enterprises data
sme <- read.csv("ceidg_geocode.csv")
sme <- sme %>% filter(!is.na(g_dlug))
sme <- st_as_sf(sme, coords = c("g_dlug", "g_szer"), crs = 4326)
sme <- st_make_valid(sme)

#OPTIONAL: plot to check
#tm_shape(sme) + tm_symbols()

#Add SME to grid
sme_join <- st_join(sme, workplace_grid, join = st_within)
sme_per_grid <- count(as_tibble(sme_join), grid_id)
sme_per_grid <- rename(sme_per_grid, sme_count = n)
workplace_grid <- left_join(workplace_grid, sme_per_grid, by = "grid_id")
workplace_grid <- workplace_grid %>% mutate(sme_count = ifelse(is.na(sme_count), 0, sme_count))
workplace_grid$sme_weight <- workplace_grid$sme_count / sum(workplace_grid$sme_count)

#Calculate workplaces per grid cell
workplace_grid$workplaces <- ((workplace_grid$nonres_weight * ghsl_share) +
                              (workplace_grid$sme_weight * sme_share)) * 
                                total_workplaces

#OPTIONAL: Plot to check
tm_shape(filter(workplace_grid, workplaces >0)) + tm_polygons(fill = "workplaces", col_alpha = 0, fill_alpha = 0.5, palette = "Reds")
