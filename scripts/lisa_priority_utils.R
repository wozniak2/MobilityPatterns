# =============================================================================
# lisa_priority_utils.R
#
# Shared helpers for the car-vs-PT LISA clustering and PT investment-priority
# classification used by 9_analyse_itineraries.R and 10_OD_comparison.R.
# Extracted so the two scripts don't maintain two independent copies of the
# same clustering/classification logic.
# =============================================================================

library(dplyr)
library(sf)
library(spdep)
library(tidytransit)
library(purrr)
library(tidyr)

#' Load and merge every GTFS feed in `gtfs_dir`, returning stop-level
#' departure counts as an sf object filtered to a bounding box.
load_gtfs_stops <- function(gtfs_dir,
                             lon_range = c(16.5, 17.5),
                             lat_range = c(52.0, 52.8),
                             crs = 2180) {
  gtfs_files <- list.files(gtfs_dir, pattern = "\\.zip$", full.names = TRUE)
  gtfs_list  <- gtfs_files %>% set_names(basename(.)) %>% map(read_gtfs)

  merge_table <- function(gtfs_list, table_name) {
    gtfs_list %>%
      imap(function(gtfs, fname) {
        tbl <- gtfs[[table_name]]
        if (!is.null(tbl)) tbl %>% mutate(feed = fname) else NULL
      }) %>%
      compact() %>%
      bind_rows()
  }

  stops      <- merge_table(gtfs_list, "stops")
  trips      <- merge_table(gtfs_list, "trips")
  stop_times <- merge_table(gtfs_list, "stop_times")

  # Prefix stop_id with feed name to avoid collisions across feeds
  stops <- stops %>% mutate(stop_id = paste(feed, stop_id, sep = "_"))
  stop_times <- stop_times %>%
    select(-feed) %>%
    left_join(trips %>% select(trip_id, route_id, feed), by = "trip_id") %>%
    mutate(stop_id = paste(feed, stop_id, sep = "_"))

  stops %>%
    left_join(stop_times %>% count(stop_id, name = "n_departures"), by = "stop_id") %>%
    mutate(n_departures = replace_na(n_departures, 0)) %>%
    filter(stop_lon >= lon_range[1], stop_lon <= lon_range[2],
           stop_lat >= lat_range[1], stop_lat <= lat_range[2]) %>%
    st_as_sf(coords = c("stop_lon", "stop_lat"), crs = 4326) %>%
    st_transform(crs)
}

#' Compute global + local Moran's I (LISA) on a car-vs-PT log-frequency
#' difference surface (`diff_sf$diff`), classifying each cell's lisa_type.
compute_lisa <- function(diff_sf, cell_size) {
  coords_mat <- st_coordinates(diff_sf)
  nb <- dnearneigh(coords_mat, d1 = 0, d2 = cell_size * 1.5)
  lw <- nb2listw(nb, style = "W", zero.policy = TRUE)

  local_moran <- localmoran(diff_sf$diff, lw, zero.policy = TRUE)

  diff_sf %>%
    mutate(
      local_I   = local_moran[, "Ii"],
      local_p   = local_moran[, "Pr(z != E(Ii))"],
      local_sig = local_p < 0.05,
      mean_diff = mean(diff, na.rm = TRUE),
      lag_diff  = lag.listw(lw, diff, zero.policy = TRUE),
      lisa_type = case_when(
        local_sig & diff > mean_diff & lag_diff > mean_diff ~ "High-High (car cluster)",
        local_sig & diff < mean_diff & lag_diff < mean_diff ~ "Low-Low (PT cluster)",
        local_sig & diff > mean_diff & lag_diff < mean_diff ~ "High-Low (car outlier)",
        local_sig & diff < mean_diff & lag_diff > mean_diff ~ "Low-High (PT outlier)",
        TRUE                                                ~ "Not significant"
      )
    )
}

#' Given High-High LISA "car cluster" zones (with a `working_age_pop` column
#' already attached), add distance-to-nearest-stop, service frequency, and a
#' population-weighted investment-priority label.
classify_car_zones <- function(car_zones, stops_poznan, pop_threshold) {
  nearest_stop_idx <- st_nearest_feature(car_zones, stops_poznan)

  car_zones <- car_zones %>%
    mutate(
      n_departures   = stops_poznan$n_departures[nearest_stop_idx],
      dist_to_stop_m = as.numeric(
        st_distance(geometry, stops_poznan)[cbind(seq_len(nrow(car_zones)), nearest_stop_idx)]
      ),
      pt_accessibility = case_when(
        dist_to_stop_m <  300  ~ "Good (< 300m)",
        dist_to_stop_m <  600  ~ "Moderate (300–600m)",
        dist_to_stop_m < 1000  ~ "Poor (600m–1km)",
        TRUE                   ~ "Very poor (> 1km)"
      ) %>% factor(levels = c(
        "Good (< 300m)", "Moderate (300–600m)", "Poor (600m–1km)", "Very poor (> 1km)"
      )),
      freq_service = case_when(
        n_departures == 0                                          ~ "No service",
        n_departures < quantile(stops_poznan$n_departures, 0.25)   ~ "Low frequency",
        n_departures < quantile(stops_poznan$n_departures, 0.75)   ~ "Medium frequency",
        TRUE                                                        ~ "High frequency"
      ) %>% factor(levels = c(
        "No service", "Low frequency", "Medium frequency", "High frequency"
      ))
    )

  car_zones %>%
    mutate(
      priority = case_when(
        working_age_pop >= pop_threshold &
          pt_accessibility %in% c("Very poor (> 1km)", "Poor (600m–1km)")        ~ "High priority — no nearby stop",
        working_age_pop >= pop_threshold &
          pt_accessibility %in% c("Moderate (300–600m)", "Good (< 300m)") &
          freq_service %in% c("No service", "Low frequency")                     ~ "High priority — infrequent service",
        working_age_pop >= pop_threshold &
          pt_accessibility == "Moderate (300–600m)" &
          freq_service == "Medium frequency"                                      ~ "Medium priority",
        working_age_pop >= pop_threshold &
          pt_accessibility == "Good (< 300m)" &
          freq_service %in% c("Medium frequency", "High frequency")              ~ "Car preference gap",
        TRUE                                                                      ~ "Low priority"
      ) %>% factor(levels = c(
        "High priority — no nearby stop",
        "High priority — infrequent service",
        "Medium priority",
        "Car preference gap",
        "Low priority"
      ))
    )
}
