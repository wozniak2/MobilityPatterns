library(tidyverse)
library(sf)
library(spdep)
library(tidytransit)


### !!! require 'df_pit' and 'df_cit' data frames produced by '6_plot_itineraries.R' !!! ###

# ── 1. Normalise & join ───────────────────────────────────────────────────────
# Add log-frequency and mode label to each frame
car_df <- df_cit %>% mutate(mode = "Cars",             log_freq = log1p(freq))
pt_df  <- df_pit  %>% mutate(mode = "Public transport", log_freq = log1p(freq))


# Join on grid coordinates; pixels missing in one mode get NA → then 0
diff_df <- full_join(
  car_df %>% select(x, y, log_freq),
  pt_df  %>% select(x, y, log_freq),
  by = c("x", "y"),
  suffix = c("_car", "_pt")
) %>%
  mutate(
    across(starts_with("log_freq"), ~replace_na(.x, 0)),
    diff = log_freq_car - log_freq_pt   # positive = cars dominate
  )

# ── 2. Import and merge GTFS data ─────────────────────────────────────────────
gtfs_dir   <- "/Users/wozni/Google Drive/UAM/HUB/MobilityPatterns/Data/gtfs"
gtfs_files <- list.files(gtfs_dir, pattern = "\\.zip$", full.names = TRUE)


# Read each zip into a list
gtfs_list <- gtfs_files %>%
  set_names(basename(.)) %>%
  map(read_gtfs)

# Merge key tables across all feeds
merge_table <- function(gtfs_list, table_name) {
  gtfs_list %>%
    imap(function(gtfs, fname) {
      tbl <- gtfs[[table_name]]
      if (!is.null(tbl)) tbl %>% mutate(feed = fname)
      else NULL
    }) %>%
    compact() %>%
    bind_rows()
}

stops      <- merge_table(gtfs_list, "stops")
routes     <- merge_table(gtfs_list, "routes")
trips      <- merge_table(gtfs_list, "trips")
stop_times <- merge_table(gtfs_list, "stop_times")

# Deduplicate stop_ids across feeds
stops <- stops %>%
  mutate(stop_id = paste(feed, stop_id, sep = "_"))

stop_times <- stop_times %>%
  select(-feed) %>%
  left_join(trips %>% select(trip_id, route_id, feed), by = "trip_id") %>%
  mutate(stop_id = paste(feed, stop_id, sep = "_"))

# Stop frequency across all feeds
stop_freq <- stop_times %>%
  count(stop_id, name = "n_departures")

stops <- stops %>%
  left_join(stop_freq, by = "stop_id") %>%
  mutate(n_departures = replace_na(n_departures, 0))

cat(sprintf(
  "Total stops  : %d\nTotal routes : %d\nFeeds merged : %d\n",
  nrow(stops),
  nrow(routes),
  length(gtfs_list)
))

# ── 3. Create diff_sf with correct CRS (EPSG:3857) ───────────────────────────
diff_sf <- diff_df %>%
  filter(!is.na(diff)) %>%
  st_as_sf(coords = c("x", "y"), crs = 3857) %>%
  st_transform(2180)



# ── 4. Compute spatial weights ────────────────────────────────────────────────
cell_size <- car_df %>%
  arrange(x) %>%
  pull(x) %>%
  diff() %>%
  .[. > 1] %>%        # filter floating point noise
  min()

# Build spatial weights (queen contiguity on raster grid)
coords_mat <- st_coordinates(diff_sf)
nb  <- dnearneigh(coords_mat, d1 = 0, d2 = cell_size * 1.5)
lw  <- nb2listw(nb, style = "W", zero.policy = TRUE)

moran_result <- moran.test(diff_sf$diff, lw, zero.policy = TRUE)
print(moran_result)
# Moran's I > 0 and significant → differences are spatially clustered (not random)

# ── 4. Local Moran's I — WHERE are the significant clusters? ─────────────────
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

# ── 6. Extract High-High pixels ───────────────────────────────────────────────
hh_pixels <- diff_sf %>% filter(lisa_type == "High-High (car cluster)")

# ── 5. Prepare PT stops (filter to Poznań area in WGS84) ─────────────────────
stops_poznan <- stops %>%
  distinct(stop_id, .keep_all = TRUE) %>%
  filter(
    !is.na(stop_lon), !is.na(stop_lat),
    stop_lon > 16.5, stop_lon < 17.5,
    stop_lat > 52.0, stop_lat < 52.8
  ) %>%
  st_as_sf(coords = c("stop_lon", "stop_lat"), crs = 4326) %>%
  st_transform(2180)

# ── 7. Compute distance to nearest PT stop ────────────────────────────────────
nearest_stop <- st_nearest_feature(hh_pixels, stops_poznan)

hh_pixels <- hh_pixels %>%
  mutate(
    dist_to_stop_m = as.numeric(st_distance(
      geometry,
      stops_poznan$geometry[nearest_stop],
      by_element = TRUE
    )),
    pt_accessibility = case_when(
      dist_to_stop_m <  300 ~ "Good (< 300m)",
      dist_to_stop_m <  600 ~ "Moderate (300–600m)",
      dist_to_stop_m < 1000 ~ "Poor (600m–1km)",
      TRUE                  ~ "Very poor (> 1km)"
    )
  )

# ── 8. Prepare city boundary ──────────────────────────────────────────────────
poz <- st_read("boundary.gpkg")
ap <- st_read("ap.gpkg")
poz_r <- st_transform(poz, 2180)
ap_r <- st_transform(ap, 2180)

# ── 9. Plot ───────────────────────────────────────────────────────────────────
ggplot() +
#  geom_sf(data = poz_r, fill = "grey15", colour = "grey40", linewidth = 0.3) +
  geom_sf(
    data = hh_pixels,
    aes(colour = pt_accessibility),
    size = 0.6, shape = 15
  ) +
#  geom_sf(
#    data        = stops_poznan,
#    colour      = "white", size = 0.1, alpha = 0.5,
#    inherit.aes = FALSE
#  ) +
  scale_colour_manual(
    values = c(
      "Good (< 300m)"       = "#7ee8a2",
      "Moderate (300–600m)" = "#f0c060",
      "Poor (600m–1km)"     = "#e07820",
      "Very poor (> 1km)"   = "#c0392b"
    ),
    name = "PT accessibility"
  ) +
  coord_sf(crs = st_crs(poz_r)) +
  labs(
    title    = "PT accessibility in car-dominated zones for Rokietnica",
    subtitle = "High-High LISA pixels coloured by distance to nearest PT stop"
  ) +
  theme_dark() +
  theme(
    panel.background = element_rect(fill = "#1a1a1a"),
    plot.background  = element_rect(fill = "#1a1a1a"),
    legend.background = element_rect(fill = "#1a1a1a"),
    legend.key = element_rect(fill = "#1a1a1a"),
    
    text = element_text(color = "white"),
    axis.text = element_blank(),
    axis.title = element_blank(),
    
    legend.title = element_text(size = 14, color = "white"),
    legend.text  = element_text(size = 14, color = "white"),
    
    panel.grid.major = element_blank(),
    panel.grid.minor = element_blank()
  ) +
  guides(color = guide_legend(override.aes = list(size = 5)))

