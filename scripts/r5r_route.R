setwd("/home/adam/Dokumenty/commuting_patterns")

library(rJavaEnv)
library(dplyr)
library(r5r)
library(sf)
library(tidyr)
library(tmap)

tmap_mode("plot")

#Read origins file & transform to points, add ID
origins <- st_read("buildings.gpkg")
origins <- st_centroid(origins)
if (st_crs(origins) != 4326) {
  st_crs(origins) = 4326
}
origins$id <- 1:nrow(origins)  

#Read destinations file & transform to points, add ID
destinations <- st_read("workplaces.gpkg")
destinations <- st_centroid(destinations)
if (st_crs(destinations) != 4326) {
  st_crs(destinations) = 4326
}
destinations$id <- 1:nrow(destinations)

# Build R5 graph object
use_java(version = "21")
options(java.parameters = '-Xmx8G')
r5r_network <- build_network(data_path = "./routing", 
                     elevation = "MINETTI", 
                     verbose = FALSE)

#OPTIONAL: extract & visualize street, PT networks
streets <- street_network_to_sf(r5r_network)
tm_shape(streets$edges) + tm_lines(col = "car_speed",
                                   col.scale = tm_scale_categorical())

transit <- transit_network_to_sf(r5r_network)
tm_shape(transit$routes) + tm_lines(col = "route_id",
                                    col.scale = tm_scale_categorical())
#Calculate & plot itineraries by car
itineraries_car <- detailed_itineraries(r5r_network = r5r_network, 
                                        origins = sample_n(origins, 200),
                                        destinations = sample_n(destinations, 100),
                                        mode = "CAR",
                                        all_to_all = TRUE,
                                        carspeed_scale = 1)

tm_shape(itineraries_car) + tm_lines(col = "total_duration")

#OPTIONAL: check availability of PT by date
check_transit_availability(r5r_network = r5r_network,
                           dates = "2025-11-15")

#Calculate & plot itineraries by PT
itineraries_pt <- detailed_itineraries(r5r_network = r5r_network, 
                                        origins = sample_n(origins, 200),
                                        destinations = sample_n(destinations, 100),
                                        departure_datetime = as.POSIXct("15-11-2025 07:00:00", 
                                                                        format = "%d-%m-%Y %H:%M:%S"),
                                        mode = "TRANSIT",
                                        mode_egress = "WALK",
                                        max_walk_time = 15,
                                        max_trip_duration = 60,
                                        max_rides = 2,
                                        all_to_all = TRUE)

tm_shape(itineraries_pt) + tm_lines(col = "mode",
                                    col.scale = tm_scale_categorical())
