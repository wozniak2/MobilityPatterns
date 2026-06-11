library(tidyverse)
library(sf)
library(spdep)
library(tidytransit)
library(maptiles)
library(tidyterra)
library(terra)
library(osmdata)

# !!! This script requires the 'results' object produced by '5_read_itineraries.R' !!!

# ── 1. Combine counties & compute log-frequency difference ───────────────────
df_cit <- map_dfr(results, ~ .x$df_cit)
df_pit <- map_dfr(results, ~ .x$df_pit)

diff_df <- full_join(
  df_cit %>% mutate(log_freq = log1p(freq)) %>% select(x, y, log_freq),
  df_pit %>% mutate(log_freq = log1p(freq)) %>% select(x, y, log_freq),
  by     = c("x", "y"),
  suffix = c("_car", "_pt")
) %>%
  mutate(
    across(starts_with("log_freq"), ~replace_na(.x, 0)),
    diff = log_freq_car - log_freq_pt   # positive = car dominates
  )

# ── 2. Import and merge GTFS feeds ───────────────────────────────────────────
gtfs_dir   <- "/Users/wozni/Google Drive/UAM/HUB/MobilityPatterns/Data/gtfs"
gtfs_files <- list.files(gtfs_dir, pattern = "\\.zip$", full.names = TRUE)

gtfs_list <- gtfs_files %>%
  set_names(basename(.)) %>%
  map(read_gtfs)

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

# Compute departure frequency per stop and filter to Poznań metro bbox
stops_poznan <- stops %>%
  left_join(
    stop_times %>% count(stop_id, name = "n_departures"),
    by = "stop_id"
  ) %>%
  mutate(n_departures = replace_na(n_departures, 0)) %>%
  filter(stop_lon >= 16.5, stop_lon <= 17.5,
         stop_lat >= 52.0, stop_lat <= 52.8) %>%
  st_as_sf(coords = c("stop_lon", "stop_lat"), crs = 4326) %>%
  st_transform(2180)

# ── 3. Build spatial object and compute global Moran's I ─────────────────────
diff_sf <- diff_df %>%
  filter(!is.na(diff)) %>%
  st_as_sf(coords = c("x", "y"), crs = 3857) %>%
  st_transform(2180)

# Derive raster cell size from a single county to avoid cross-county fp noise
cell_size <- results[[1]]$df_cit %>%
  arrange(x) %>% pull(x) %>% diff() %>%
  .[. > 1] %>% min()
cat("Cell size (m):", cell_size, "\n")

# Queen contiguity spatial weights on raster grid
coords_mat <- st_coordinates(diff_sf)
nb <- dnearneigh(coords_mat, d1 = 0, d2 = cell_size * 1.5)
lw <- nb2listw(nb, style = "W", zero.policy = TRUE)

moran_result <- moran.test(diff_sf$diff, lw, zero.policy = TRUE)
print(moran_result)

# ── 4. Local Moran's I (LISA) — locate significant clusters ──────────────────
local_moran <- localmoran(diff_sf$diff, lw, zero.policy = TRUE)

diff_sf <- diff_sf %>%
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

# ── 5. Assign population to all pixels via nearest GHS-POP grid cell ─────────
pop_grid   <- st_read("pop_grid.gpkg", quiet = TRUE)   # input CRS: World Mollweide
pop_grid_r <- st_transform(pop_grid, st_crs(diff_sf))  # reproject to EPSG:2180

nearest_idx     <- st_nearest_feature(diff_sf, pop_grid_r)
diff_sf$working_age_pop <- pop_grid_r$working_age_pop[nearest_idx]

# ── 6. Extract car-dominated zones ───────────────────────────────────────────
car_zones <- diff_sf %>% filter(lisa_type == "High-High (car cluster)")

# Distance to nearest PT stop → physical accessibility category
nearest_stop_idx       <- st_nearest_feature(car_zones, stops_poznan)
car_zones$n_departures <- stops_poznan$n_departures[nearest_stop_idx]

car_zones <- car_zones %>%
  mutate(
    dist_to_stop_m = as.numeric(
      st_distance(geometry, stops_poznan)[
        cbind(seq_len(nrow(.)), st_nearest_feature(., stops_poznan))
      ]
    ),
    pt_accessibility = case_when(
      dist_to_stop_m <  300  ~ "Good (< 300m)",
      dist_to_stop_m <  600  ~ "Moderate (300–600m)",
      dist_to_stop_m < 1000  ~ "Poor (600m–1km)",
      TRUE                   ~ "Very poor (> 1km)"
    ) %>% factor(levels = c(
      "Good (< 300m)", "Moderate (300–600m)", "Poor (600m–1km)", "Very poor (> 1km)"
    ))
  )

# ── 7. Classify service frequency of nearest stop ────────────────────────────
# Inspect distribution before committing to breaks
cat("\nDeparture frequency summary:\n")
print(summary(stops_poznan$n_departures))

car_zones <- car_zones %>%
  mutate(freq_service = case_when(
    n_departures == 0                                                  ~ "No service",
    n_departures < quantile(stops_poznan$n_departures, 0.25)          ~ "Low frequency",
    n_departures < quantile(stops_poznan$n_departures, 0.75)          ~ "Medium frequency",
    TRUE                                                               ~ "High frequency"
  ) %>% factor(levels = c(
    "No service", "Low frequency", "Medium frequency", "High frequency"
  )))

# ── 8. Investment priority — population × distance × frequency ───────────────
pop_threshold <- quantile(pop_grid_r$working_age_pop, 0.80, na.rm = TRUE)
cat("Population threshold (80th pct):", pop_threshold, "\n")

car_zones <- car_zones %>%
  mutate(
    priority = case_when(
      # Populated + no physical access → build new infrastructure
      working_age_pop >= pop_threshold &
        pt_accessibility %in% c("Very poor (> 1km)", "Poor (600m–1km)")        ~ "High priority — no nearby stop",
      
      # Populated + stop nearby but infrequent → improve service frequency
      working_age_pop >= pop_threshold &
        pt_accessibility %in% c("Moderate (300–600m)", "Good (< 300m)") &
        freq_service %in% c("No service", "Low frequency")                     ~ "High priority — infrequent service",
      
      # Populated + moderate access + moderate frequency → incremental upgrade
      working_age_pop >= pop_threshold &
        pt_accessibility == "Moderate (300–600m)" &
        freq_service == "Medium frequency"                                      ~ "Medium priority",
      
      # Populated + good access + frequent service → behavioural/modal gap
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


# Remove pixels inside Poznań city boundary (focus on suburban gaps)
poz_r <- st_transform(poz, st_crs(car_zones))
outside   <- lengths(st_intersects(car_zones, st_union(poz_r))) == 0
car_zones <- car_zones[outside, ]

cat("\nPriority breakdown:\n")
print(table(car_zones$priority))

# ── 9. Diagnostic heatmap — frequency vs distance ────────────────────────────
car_zones %>%
  st_drop_geometry() %>%
  filter(working_age_pop >= pop_threshold) %>%
  count(pt_accessibility, freq_service) %>%
  ggplot(aes(x = freq_service, y = pt_accessibility, fill = n)) +
  geom_tile(colour = "grey30") +
  geom_text(aes(label = n), colour = "white", size = 4) +
  scale_fill_gradient(low = "#1a1a1a", high = "#c0392b", name = "Pixels") +
  labs(
    title    = "Car-dominated pixels by PT distance and service frequency",
    subtitle = "High-population pixels only (top 20%)",
    x = "Service frequency (nearest stop)",
    y = "Distance to nearest stop"
  ) +
  theme_dark() +
  theme(
    panel.background  = element_rect(fill = "#1a1a1a"),
    plot.background   = element_rect(fill = "#1a1a1a"),
    legend.background = element_rect(fill = "#1a1a1a"),
    text              = element_text(color = "white"),
    axis.text         = element_text(color = "white")
  )

# ── 10. Final map ─────────────────────────────────────────────────────────────
car_zones_wgs <- st_transform(car_zones, 4326)
poz_wgs       <- st_transform(poz_r, 4326)

# Dark B&W basemap: invert Esri grey canvas
bbox_zones <- st_bbox(car_zones_wgs) %>% st_as_sfc() %>% st_transform(3857)
osm_tiles <- get_tiles(bbox_zones, provider = "Esri.WorldGrayCanvas", zoom = 12, crop = TRUE)


osm_bw <- app(osm_tiles, fun = function(x) {
  grey <- 0.299 * x[1] + 0.587 * x[2] + 0.114 * x[3]
  255 - grey
})

osm_bw <- c(osm_bw, osm_bw, osm_bw)

# Fetch primary, secondary and tertiary roads from OSM
roads_lines <- opq(bbox = st_bbox(car_zones_wgs), timeout = 180) %>%
  add_osm_feature(key = "highway", value = c("primary", "secondary", "tertiary")) %>%
  osmdata_sf() %>%
  .$osm_lines %>%
  st_transform(4326) %>%
  select(osm_id, name, highway)

ggplot() +
  geom_spatraster_rgb(data = osm_bw, alpha = 0.55) +
  geom_sf(
    data        = roads_lines,
    aes(linewidth = highway),
    colour      = "grey60", alpha = 0.6,
    inherit.aes = FALSE, show.legend = FALSE
  ) +
  scale_linewidth_manual(values = c(
    "primary"   = 0.5,
    "secondary" = 0.25,
    "tertiary"  = 0.15
  )) +
  geom_sf(data = poz_wgs, fill = NA, colour = "white",
          linewidth = 0.4, inherit.aes = FALSE) +
  geom_sf(
    data        = car_zones_wgs %>% filter(priority != "Low priority"),
    aes(colour  = priority),
    size        = 0.6, shape = 15, alpha = 0.8,
    inherit.aes = FALSE
  ) +
  scale_colour_manual(
    values = c(
      "High priority — no nearby stop"     = "red",
      "High priority — infrequent service" = "hotpink",
      "Medium priority"                    = "green2",
      "Car preference gap"                 = "yellow"
    ),
    name = "Investment priority"
  ) +
  coord_sf(crs = 4326) +
  labs(
    title    = "PT investment priority zones",
    subtitle = "Car-dominated areas (High-High LISA) weighted by population & service frequency"
  ) +
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

ggsave("Fig_PT_investment_priority.png", width = 12, height = 9, dpi = 300)
