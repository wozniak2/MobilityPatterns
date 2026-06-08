args = commandArgs(trailingOnly = TRUE)

#setwd("/home/adam/Dokumenty/commuting_patterns")

library(elevatr)
library(rJavaEnv)
library(dplyr)
library(r5r)
library(sf)
#library(terra)
library(tidyr)
library(tmap)

#sink(paste("rconsolelog_", format(Sys.time()), ".txt", sep = ""))

#tmap_mode("plot")
#select_municipality <- c("Swarzędz_W")
select_municipality <- args[1]
workplace_cutoff <- 150
pop_cutoff <- 30

#Read origins file & transform to points, add ID
origins <- st_read("pop_grid.gpkg")
origins <- st_centroid(origins)
if (st_crs(origins) != 4326) {
  origins <- st_transform(origins, crs = 4326)
}
origins$id <- 1:nrow(origins)  

#Read destinations file & transform to points, add ID
destinations <- st_read("workplace_grid.gpkg")
destinations <- st_centroid(destinations)
if (st_crs(destinations) != 4326) {
  destinations <- st_transform(destinations, crs = 4326)
}
destinations$id <- 1:nrow(destinations)

#Download elevation data IF DOES NOT EXIST
#ap <- st_read("ap.gpkg")
#elev <- get_elev_raster(locations = ap, z = 13)
#writeRaster(elev, "./routing/elevation.tiff")

# Build R5 graph object
use_java(version = "21")
options(java.parameters = '-Xmx16G')
r5r_network <- build_network(data_path = "./routing", 
                     elevation = "MINETTI", 
                     verbose = FALSE)

#OPTIONAL: extract & visualize street, PT networks
#streets <- street_network_to_sf(r5r_network)
#tm_shape(streets$edges) + tm_lines(col = "car_speed",
#                                   col.scale = tm_scale_categorical())

#transit <- transit_network_to_sf(r5r_network)
#tm_shape(transit$routes) + tm_lines(col = "route_id",
#                                    col.scale = tm_scale_categorical()) +
#  tm_shape(transit$stops) + tm_symbols()

#OPTIONAL: Calculate travel time matrix
#ttm_car <- travel_time_matrix(r5r_network = r5r_network, 
#                              origins = subset(origins, municipality_short == select_municipality & working_age_pop > pop_cutoff),
#                              destinations = subset(destinations, workplaces > workplace_cutoff),
#                              mode = "CAR",
#                              carspeed_scale = 1,
#                              verbose = TRUE,
#                              progress = TRUE)

#ttm_pt <- travel_time_matrix(r5r_network = r5r_network, 
#                              origins = subset(origins, municipality_short == select_municipality & working_age_pop > pop_cutoff),
#                              destinations = subset(destinations, workplaces > workplace_cutoff),
#                              mode = c("WALK", "TRANSIT"),
#                              departure_datetime = as.POSIXct("15-11-2025 07:00:00", 
#                                                             format = "%d-%m-%Y %H:%M:%S"),
#                              verbose = TRUE,
#                              progress = TRUE)

#Calculate itineraries by car
system.time(itineraries_car <- detailed_itineraries(r5r_network = r5r_network, 
                                        origins = subset(origins, municipality_short == select_municipality & working_age_pop > pop_cutoff),
                                        destinations = subset(destinations, workplaces > workplace_cutoff),
                                        mode = "CAR",
                                        all_to_all = TRUE,
                                        carspeed_scale = 1,
                                        verbose = TRUE,
                                        progress = TRUE))

#OPTIONAL: plot itineraries
#tm_shape(itineraries_car) + tm_lines(col = "total_duration")

#Save to file
st_write(itineraries_car, dsn = paste("./itineraries/car_itineraries_", select_municipality, ".gpkg", sep = ""), append = FALSE)

#OPTIONAL: check availability of PT by date
#check_transit_availability(r5r_network = r5r_network,
#                           dates = "2025-11-27")

#Calculate itineraries by PT
system.time(itineraries_pt <- detailed_itineraries(r5r_network = r5r_network, 
                                        origins = subset(origins, municipality_short == select_municipality & working_age_pop > pop_cutoff),
                                        destinations = subset(destinations, workplaces > workplace_cutoff),
                                        departure_datetime = as.POSIXct("27-11-2025 07:00:00", 
                                                                        format = "%d-%m-%Y %H:%M:%S"),
                                        mode = c("WALK", "TRANSIT"),
                                        max_walk_time = 15,
                                        max_trip_duration = 90,
                                        max_rides = 3,
                                        all_to_all = TRUE,
                                        verbose = TRUE,
                                        progress =  TRUE))

#OPTIONAL: plot itineraries
#tm_shape(itineraries_pt) + tm_lines(col = "mode",
#                                    col.scale = tm_scale_categorical())

#Save to file
st_write(itineraries_pt, dsn = paste("./itineraries/pt_itineraries_", select_municipality, ".gpkg", sep = ""))
