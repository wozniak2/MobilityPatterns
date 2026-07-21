library(dplyr)
library(sf)

#Make a list of municipalities to loop through
pop_grid <- st_read("pop_grid.gpkg")
municipalities <- unique(pop_grid$municipality_short)

#Loop through files
tryCatch({
  for (i in 1:length(municipalities)) {

  filename_car <- paste0("./itineraries2/car_itineraries_", municipalities[i], ".gpkg")
  filename_pt <- paste0("./itineraries2/pt_itineraries_", municipalities[i], ".gpkg")

  #Read itineraries & drop geometries
  car_it <- st_read(filename_car)
  pt_it <- st_read(filename_pt)

  car_it_df <- as.data.frame(st_drop_geometry(car_it))
  pt_it_df <- as.data.frame(st_drop_geometry(pt_it))

  #Fix, aggregate & join
  car_it_df$unique_id <- paste(car_it_df$from_id, car_it_df$to_id, sep = "_")

  car_it_final <- car_it_df %>% 
  select(unique_id,
         from_id,
         to_id,
         from_lat,
         from_lon,
         to_lat,
         to_lon,
         total_duration,
         total_distance) %>% 
  rename(total_duration_car = total_duration,
         total_distance_car = total_distance)

  pt_it_df$unique_id <- paste(pt_it_df$from_id, pt_it_df$to_id, sep = "_")
  pt_it_df$route[pt_it_df$route==""] <- 0

  pt_it_final <- pt_it_df %>% 
  select(unique_id, 
         departure_time, 
         total_duration,
         total_distance,
         segment,
         mode,
         segment_duration,
         wait,
         distance,
         route) %>% 
  rename(total_duration_pt = total_duration,
         total_distance_pt = total_distance) %>% 
  group_by(unique_id) %>%
  mutate(
    segments = n(),
    mode = paste(mode, collapse = ","),
    segment_duration = paste(segment_duration, collapse = ","),
    wait = paste(wait, collapse = ","),
    distance = paste(distance, collapse = ","),
    route = paste(route, collapse = ",")
  ) %>% 
  select(!segment) %>% 
  distinct(unique_id, .keep_all = TRUE)

  itineraries <- left_join(pt_it_final, car_it_final, by = "unique_id")  
  itineraries$time_ratio <- itineraries$total_duration_pt / itineraries$total_duration_car
  itineraries$dist_ratio <- itineraries$total_distance_pt / itineraries$total_distance_car
  
  #Write result to file
  write.csv(itineraries, file = paste0("./itineraries_csv/itineraries_", municipalities[i], "_.csv"))
  }

  }, error = function(e) {
    # Handle the error
    cat("An error occurred:", conditionMessage(e), "\n")
    NA
  })

