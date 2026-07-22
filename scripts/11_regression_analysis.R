# =============================================================================
# 11_regression_analysis.R
#
# Builds a per-OD-pair regression dataset (PT efficiency, network topology,
# stop accessibility, population exposure) from the outputs of steps 1-5,
# and runs exploratory correlation/VIF/OLS diagnostics on the PT/car travel
# time ratio.
#
# INPUT  : pt_itineraries.rds, car_itineraries.rds (from 05_read_itineraries.R)
#          pop_grid.gpkg (from 02_distribute_population.R)
#          gtfs/*.zip
# OUTPUT : regression_data.csv
# =============================================================================

library(sf)
library(tidyverse)
library(terra)
library(corrplot)
library(car)

setwd("C:/Users/wozni/Google Drive/UAM/HUB/MobilityPatterns/Data")
source("C:/Users/wozni/OneDrive/Documents/GitHub/MobilityPatterns/scripts/lisa_priority_utils.R")

# ── Load itineraries produced by 05_read_itineraries.R ───────────────────────
pt_itineraries  <- readRDS("pt_itineraries.rds")
car_itineraries <- readRDS("car_itineraries.rds")

cat(sprintf("PT rows : %d\nCar rows: %d\n",
            nrow(pt_itineraries), nrow(car_itineraries)))

# ── 1. Base OD summary ────────────────────────────────────────────────────────
pt_od <- pt_itineraries %>%
  st_drop_geometry() %>%
  group_by(from_id, to_id, from_lat, from_lon, to_lat, to_lon, county) %>%
  summarise(
    pt_duration_min  = min(total_duration),
    pt_distance_m    = min(total_distance),
    n_transfers      = max(segment) - 1,
    .groups = "drop"
  )

car_od <- car_itineraries %>%
  st_drop_geometry() %>%
  group_by(from_id, to_id, from_lat, from_lon, to_lat, to_lon) %>%
  summarise(
    car_duration_min = min(total_duration),
    car_distance_m   = min(total_distance),
    .groups = "drop"
  )

od_comparison <- inner_join(
  pt_od, car_od,
  by = c("from_id", "to_id", "from_lat", "from_lon", "to_lat", "to_lon")
) %>%
  mutate(
    tt_ratio = pt_duration_min / car_duration_min,
    tt_diff  = pt_duration_min - car_duration_min,
    competitive = case_when(
      tt_ratio <= 1.0 ~ "PT faster",
      tt_ratio <= 1.5 ~ "Comparable (< 1.5x)",
      tt_ratio <= 2.0 ~ "PT slower (1.5–2x)",
      TRUE            ~ "PT much slower (> 2x)"
    ) %>% factor(levels = c(
      "PT faster", "Comparable (< 1.5x)",
      "PT slower (1.5–2x)", "PT much slower (> 2x)"
    ))
  )

# ── 2. Network topology variables ─────────────────────────────────────────────

# Straight-line OD distance
od_sf <- od_comparison %>%
  st_as_sf(coords = c("from_lon", "from_lat"), crs = 4326)

dest_sf <- od_comparison %>%
  st_as_sf(coords = c("to_lon", "to_lat"), crs = 4326)

od_comparison <- od_comparison %>%
  mutate(
    straightline_m = as.numeric(st_distance(
      od_sf, dest_sf, by_element = TRUE
    )),
    od_distance_km  = straightline_m / 1000,

    # Route directness: actual / straight-line (higher = more circuitous)
    pt_directness  = pt_distance_m  / straightline_m,
    car_directness = car_distance_m / straightline_m,

    # Implied car speed (proxy for congestion level)
    car_speed_kmh  = (car_distance_m / 1000) / (car_duration_min / 60)
  )

# ── 3. PT segment decomposition ───────────────────────────────────────────────
# Walk share, wait time, in-vehicle time per OD pair
pt_segments <- pt_itineraries %>%
  st_drop_geometry() %>%
  group_by(from_id, to_id) %>%
  summarise(
    walk_time_min    = sum(segment_duration[mode == "WALK"],  na.rm = TRUE),
    wait_time_min    = sum(wait[mode %in% c("BUS", "RAIL", "TRAM")],
                           na.rm = TRUE),
    invehicle_min    = sum(segment_duration[mode %in% c("BUS", "RAIL", "TRAM")],
                           na.rm = TRUE),
    walk_dist_m      = sum(distance[mode == "WALK"], na.rm = TRUE),
    total_time_check = max(total_duration),
    .groups = "drop"
  ) %>%
  mutate(
    walk_share    = walk_time_min  / total_time_check,
    wait_share    = wait_time_min  / total_time_check,
    invehicle_share = invehicle_min / total_time_check
  )

od_comparison <- od_comparison %>%
  left_join(pt_segments, by = c("from_id", "to_id"))

# ── 4. Distance from city centre (origin and destination) ─────────────────────
poznan_centre <- st_sfc(st_point(c(16.9252, 52.4064)), crs = 4326)

od_comparison <- od_comparison %>%
  mutate(
    # Origin distance from centre
    origin_dist_centre_km = as.numeric(st_distance(
      od_sf, poznan_centre
    )) / 1000,

    # Destination distance from centre
    dest_dist_centre_km = as.numeric(st_distance(
      dest_sf, poznan_centre
    )) / 1000,

    # Destination type
    dest_type = case_when(
      dest_dist_centre_km < 2  ~ "City centre",
      dest_dist_centre_km < 5  ~ "Inner ring",
      TRUE                     ~ "Peripheral"
    ) %>% factor(levels = c("City centre", "Inner ring", "Peripheral"))
  )

# ── 5. PT stop characteristics ────────────────────────────────────────────────
stops_poznan <- load_gtfs_stops("gtfs")

# Reproject OD origins to 2180 for distance computation
origin_sf_2180 <- od_comparison %>%
  st_as_sf(coords = c("from_lon", "from_lat"), crs = 4326) %>%
  st_transform(2180)

# Nearest stop index
nearest_stop_idx <- st_nearest_feature(origin_sf_2180, stops_poznan)

od_comparison <- od_comparison %>%
  mutate(
    dist_to_stop_m = as.numeric(
      st_distance(origin_sf_2180, stops_poznan,
                  by_element = FALSE)[
                    cbind(seq_len(nrow(origin_sf_2180)), nearest_stop_idx)
                  ]
    ),
    n_departures   = stops_poznan$n_departures[nearest_stop_idx],

    # PT accessibility band
    pt_accessibility = case_when(
      dist_to_stop_m <  300  ~ "Good (< 300m)",
      dist_to_stop_m <  600  ~ "Moderate (300–600m)",
      dist_to_stop_m < 1000  ~ "Poor (600m–1km)",
      TRUE                   ~ "Very poor (> 1km)"
    ) %>% factor(levels = c(
      "Good (< 300m)", "Moderate (300–600m)",
      "Poor (600m–1km)", "Very poor (> 1km)"
    ))
  )

# ── 6. Rail vs bus indicator ──────────────────────────────────────────────────
# is_rail comes straight from load_gtfs_stops() (route_type 0-2 vs. bus)
od_comparison <- od_comparison %>%
  mutate(nearest_stop_is_rail = stops_poznan$is_rail[nearest_stop_idx])

# ── 7. Daily frequency normalisation ─────────────────────────────────────────
service_days <- attr(stops_poznan, "service_days")
cat("GTFS service days:", service_days, "\n")

od_comparison <- od_comparison %>%
  mutate(daily_departures = n_departures / service_days)

# ── 8. Origin & destination population density ───────────────────────────────
pop_grid_2180 <- st_read("pop_grid.gpkg", quiet = TRUE) %>%
  st_transform(2180)

dest_sf_2180 <- od_comparison %>%
  st_as_sf(coords = c("to_lon", "to_lat"), crs = 4326) %>%
  st_transform(2180)

od_comparison <- od_comparison %>%
  mutate(
    origin_working_age_pop = pop_grid_2180$working_age_pop[
      st_nearest_feature(origin_sf_2180, pop_grid_2180)
    ],
    dest_working_age_pop = pop_grid_2180$working_age_pop[
      st_nearest_feature(dest_sf_2180, pop_grid_2180)
    ]
  )

# ── 9. Final regression dataset ───────────────────────────────────────────────
regression_data <- od_comparison %>%
  select(
    # Identifiers (origin coordinates kept for downstream spatial models,
    # e.g. 13_gwr_sdm_comparison.R)
    from_id, to_id, county, from_lon, from_lat,

    # Outcome
    tt_ratio,

    # PT efficiency
    pt_duration_min, pt_distance_m, pt_directness,
    n_transfers, walk_share, wait_share, invehicle_min,

    # Car efficiency
    car_duration_min, car_distance_m, car_directness,
    car_speed_kmh,

    # OD geometry
    od_distance_km, straightline_m,

    # Origin characteristics
    origin_dist_centre_km,
    dist_to_stop_m, pt_accessibility,
    n_departures, daily_departures,
    nearest_stop_is_rail,
    origin_working_age_pop,

    # Destination characteristics
    dest_dist_centre_km, dest_type,
    dest_working_age_pop,

    # Classification
    competitive
  ) %>%
  filter(
    !is.na(tt_ratio),
    !is.na(n_transfers),
    !is.na(walk_share),
    !is.na(dist_to_stop_m),
    !is.na(origin_dist_centre_km),
    !is.na(dest_dist_centre_km),
    !is.na(origin_working_age_pop),
    !is.na(dest_working_age_pop),
    is.finite(tt_ratio),
    is.finite(pt_directness),
    is.finite(car_directness)
  )

write.csv(regression_data, "regression_data.csv", row.names = FALSE)
cat("Saved regression_data.csv:", nrow(regression_data), "rows\n")

## ── Regression diagnostics ───────────────────────────────────────────────────

cor_vars <- regression_data %>%
  select(tt_ratio, pt_duration_min, car_duration_min,
         n_transfers, walk_share, wait_share,
         dist_to_stop_m, daily_departures,
         origin_dist_centre_km, dest_dist_centre_km,
         origin_working_age_pop, dest_working_age_pop, od_distance_km,
         pt_directness, car_speed_kmh) %>%
  cor(use = "complete.obs")

print(round(cor_vars, 2))

# Visual correlation matrix
corrplot(cor_vars, method = "color", type = "upper",
         tl.cex = 0.8, tl.col = "black",
         col = colorRampPalette(c("#c0392b", "white", "#2980b9"))(200),
         title = "Correlation matrix — regression variables",
         mar = c(0, 0, 2, 0))

# ── Check VIF — variance inflation factors ────────────────────────────────────
# pt_duration_min is excluded: it is the numerator of tt_ratio, so including
# it as a predictor is close to circular. car_speed_kmh is replaced with
# car_directness (distance-only route-circuity measure) because car_speed_kmh
# is derived from car_duration_min, the denominator of tt_ratio, and shares
# that mechanical dependence with the outcome.
vif_model <- lm(
  tt_ratio ~ n_transfers + walk_share +
    dist_to_stop_m + daily_departures +
    origin_dist_centre_km + dest_dist_centre_km +
    origin_working_age_pop + dest_working_age_pop + od_distance_km +
    pt_directness + car_directness +
    nearest_stop_is_rail,
  data = regression_data
)

vif_vals <- vif(vif_model)
print(sort(vif_vals, decreasing = TRUE))
# Rule of thumb: VIF > 10 indicates problematic multicollinearity
# VIF > 5 warrants investigation

lm_base <- lm(
  tt_ratio ~ n_transfers +
    walk_share +
    daily_departures +
    dist_to_stop_m +
    origin_dist_centre_km +
    dest_dist_centre_km +
    origin_working_age_pop +
    dest_working_age_pop +
    nearest_stop_is_rail +
    car_directness,
  data = regression_data
)

summary(lm_base)
