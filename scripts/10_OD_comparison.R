# =============================================================================
# 8_OD_comparison.R
# Standalone OD travel time comparison: PT vs car
# Requires: commuting_itineraries/*.gpkg, poz.gpkg, pop_grid.gpkg, GTFS feeds
# Produces: Fig_PT_vs_car_travels.png
#           Fig_PT_vs_car_travels_HEX.png
#           Fig_PT_vs_car_travels_by_origin.png
# =============================================================================

library(sf)
library(tidyverse)
library(terra)
library(tidyr)
library(spdep)
library(tidytransit)
library(maptiles)
library(tidyterra)
library(scales)

# ── 0. Paths — edit here only ─────────────────────────────────────────────────
DATA_DIR  <- "/Users/wozni/Downloads/commuting_itineraries"
GTFS_DIR  <- "/Users/wozni/Google Drive/UAM/HUB/MobilityPatterns/Data/gtfs"
POZ_FILE  <- "poz.gpkg"
POP_FILE  <- "pop_grid.gpkg"

# =============================================================================
# 1. Load itineraries
# =============================================================================
pt_files  <- list.files(DATA_DIR, pattern = "^pt_itineraries_.*\\.gpkg$",  full.names = TRUE)
car_files <- list.files(DATA_DIR, pattern = "^car_itineraries_.*\\.gpkg$", full.names = TRUE)

extract_county <- function(fname) {
  str_extract(basename(fname), "(?<=itineraries_).*(?=\\.gpkg)") |> str_to_lower()
}

matched <- inner_join(
  tibble(county = extract_county(pt_files),  pt_path  = pt_files),
  tibble(county = extract_county(car_files), car_path = car_files),
  by = "county"
)
cat("Matched counties:", nrow(matched), "\n")

pt_itineraries <- matched |>
  pmap(\(county, pt_path, car_path)
    st_read(pt_path, quiet = TRUE) |> mutate(county = county)
  ) |>
  bind_rows()

car_itineraries <- matched |>
  pmap(\(county, pt_path, car_path)
    st_read(car_path, quiet = TRUE) |> mutate(county = county)
  ) |>
  bind_rows()

cat(sprintf("PT rows : %d\nCar rows: %d\n",
            nrow(pt_itineraries), nrow(car_itineraries)))

# =============================================================================
# 2. Build OD comparison table
# =============================================================================
pt_od <- pt_itineraries |>
  st_drop_geometry() |>
  group_by(from_id, to_id, from_lat, from_lon) |>
  summarise(
    pt_duration_min = min(total_duration),
    pt_distance_m   = min(total_distance),
    n_transfers     = max(segment) - 1,
    .groups = "drop"
  )

car_od <- car_itineraries |>
  st_drop_geometry() |>
  group_by(from_id, to_id, from_lat, from_lon) |>
  summarise(
    car_duration_min = min(total_duration),
    car_distance_m   = min(total_distance),
    .groups = "drop"
  )

od_comparison <- inner_join(pt_od, car_od,
                            by = c("from_id", "to_id", "from_lat", "from_lon")) |>
  mutate(
    tt_ratio = pt_duration_min / car_duration_min,
    tt_diff  = pt_duration_min - car_duration_min,
    competitive = case_when(
      tt_ratio <= 1.0 ~ "PT faster",
      tt_ratio <= 1.5 ~ "Comparable (< 1.5x)",
      tt_ratio <= 2.0 ~ "PT slower (1.5–2x)",
      TRUE            ~ "PT much slower (> 2x)"
    ) |> factor(levels = c(
      "PT faster", "Comparable (< 1.5x)",
      "PT slower (1.5–2x)", "PT much slower (> 2x)"
    ))
  )

od_sf_3857 <- od_comparison |>
  st_as_sf(coords = c("from_lon", "from_lat"), crs = 4326) |>
  st_transform(3857)

cat("OD pairs:", nrow(od_sf_3857), "\n")
cat("Lon range:", range(od_comparison$from_lon), "\n")
cat("Lat range:", range(od_comparison$from_lat), "\n")

# =============================================================================
# 3. Rebuild car_zones (High-High LISA clusters) from scratch
#    — mirrors the logic in 6_analyse_itineraries.R
# =============================================================================

# 3a. Log-frequency difference surface
df_cit <- car_itineraries |>
  st_drop_geometry() |>
  group_by(from_lon, from_lat) |>
  summarise(freq = n(), .groups = "drop") |>
  rename(x = from_lon, y = from_lat)

df_pit <- pt_itineraries |>
  st_drop_geometry() |>
  group_by(from_lon, from_lat) |>
  summarise(freq = n(), .groups = "drop") |>
  rename(x = from_lon, y = from_lat)

diff_df <- full_join(
  df_cit |> mutate(log_freq = log1p(freq)) |> select(x, y, log_freq),
  df_pit |> mutate(log_freq = log1p(freq)) |> select(x, y, log_freq),
  by = c("x", "y"), suffix = c("_car", "_pt")
) |>
  mutate(
    across(starts_with("log_freq"), \(v) replace_na(v, 0)),
    diff = log_freq_car - log_freq_pt
  )

diff_sf <- diff_df |>
  filter(!is.na(diff)) |>
  st_as_sf(coords = c("x", "y"), crs = 3857) |>
  st_transform(2180)

# 3b. LISA on the diff surface
cell_size <- od_comparison |>
  arrange(from_lon) |> pull(from_lon) |> diff() |>
  (\(d) d[d > 1e-6])() |> min() * 111320  # approx degrees -> metres

coords_mat <- st_coordinates(diff_sf)
nb <- dnearneigh(coords_mat, d1 = 0, d2 = cell_size * 1.5)
lw <- nb2listw(nb, style = "W", zero.policy = TRUE)

local_moran <- localmoran(diff_sf$diff, lw, zero.policy = TRUE)

diff_sf <- diff_sf |>
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

# 3c. Population
pop_grid   <- st_read(POP_FILE, quiet = TRUE)
pop_grid_r <- st_transform(pop_grid, st_crs(diff_sf))
diff_sf$working_age_pop <- pop_grid_r$working_age_pop[
  st_nearest_feature(diff_sf, pop_grid_r)
]

# 3d. GTFS stops
gtfs_files <- list.files(GTFS_DIR, pattern = "\\.zip$", full.names = TRUE)
gtfs_list  <- gtfs_files |> set_names(basename(.)) |> map(read_gtfs)

merge_table <- function(gtfs_list, tbl_name) {
  gtfs_list |>
    imap(\(gtfs, fname) {
      tbl <- gtfs[[tbl_name]]
      if (!is.null(tbl)) mutate(tbl, feed = fname) else NULL
    }) |>
    compact() |>
    bind_rows()
}

stops      <- merge_table(gtfs_list, "stops")
trips      <- merge_table(gtfs_list, "trips")
stop_times <- merge_table(gtfs_list, "stop_times")

stops      <- stops      |> mutate(stop_id = paste(feed, stop_id, sep = "_"))
stop_times <- stop_times |>
  select(-feed) |>
  left_join(trips |> select(trip_id, route_id, feed), by = "trip_id") |>
  mutate(stop_id = paste(feed, stop_id, sep = "_"))

stops_poznan <- stops |>
  left_join(stop_times |> count(stop_id, name = "n_departures"), by = "stop_id") |>
  mutate(n_departures = replace_na(n_departures, 0)) |>
  filter(stop_lon >= 16.5, stop_lon <= 17.5,
         stop_lat >= 52.0, stop_lat <= 52.8) |>
  st_as_sf(coords = c("stop_lon", "stop_lat"), crs = 4326) |>
  st_transform(2180)

# 3e. Car zones classification
car_zones <- diff_sf |>
  filter(lisa_type == "High-High (car cluster)") |>
  mutate(
    dist_to_stop_m = as.numeric(
      st_distance(geometry, stops_poznan)[
        cbind(seq_len(nrow(diff_sf |> filter(lisa_type == "High-High (car cluster)"))),
              st_nearest_feature(diff_sf |> filter(lisa_type == "High-High (car cluster)"),
                                 stops_poznan))
      ]
    ),
    n_departures = stops_poznan$n_departures[
      st_nearest_feature(diff_sf |> filter(lisa_type == "High-High (car cluster)"),
                         stops_poznan)
    ],
    pt_accessibility = case_when(
      dist_to_stop_m <  300  ~ "Good (< 300m)",
      dist_to_stop_m <  600  ~ "Moderate (300–600m)",
      dist_to_stop_m < 1000  ~ "Poor (600m–1km)",
      TRUE                   ~ "Very poor (> 1km)"
    ) |> factor(levels = c(
      "Good (< 300m)", "Moderate (300–600m)", "Poor (600m–1km)", "Very poor (> 1km)"
    )),
    freq_service = case_when(
      n_departures == 0                                             ~ "No service",
      n_departures < quantile(stops_poznan$n_departures, 0.25)     ~ "Low frequency",
      n_departures < quantile(stops_poznan$n_departures, 0.75)     ~ "Medium frequency",
      TRUE                                                          ~ "High frequency"
    ) |> factor(levels = c(
      "No service", "Low frequency", "Medium frequency", "High frequency"
    ))
  )

pop_threshold <- quantile(pop_grid_r$working_age_pop, 0.80, na.rm = TRUE)

car_zones <- car_zones |>
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
    ) |> factor(levels = c(
      "High priority — no nearby stop",
      "High priority — infrequent service",
      "Medium priority",
      "Car preference gap",
      "Low priority"
    ))
  )

# Remove pixels inside Poznań city boundary
poz     <- st_read(POZ_FILE, quiet = TRUE)
poz_r   <- st_transform(poz, st_crs(car_zones))
outside <- lengths(st_intersects(car_zones, st_union(poz_r))) == 0
car_zones <- car_zones[outside, ]

cat("\nPriority breakdown:\n")
print(table(car_zones$priority))

# =============================================================================
# 4. Join corridor priority to OD pairs
# =============================================================================
priority_join <- st_join(
  od_sf_3857,
  car_zones |> st_transform(3857) |> select(priority),
  join = st_nearest_feature
)

od_sf_3857$corridor_type_val <- priority_join$priority
od_sf_3857$tt_ratio          <- od_comparison$tt_ratio

cat("\nCorridortype breakdown:\n")
print(table(od_sf_3857$corridor_type_val, useNA = "always"))

# =============================================================================
# 5. Rasterize tt_ratio per priority class
# =============================================================================
r_template <- rast(
  ext  = ext(vect(od_sf_3857)),
  res  = 120,
  crs  = "EPSG:3857"
)

make_ratio_raster <- function(corridor_val, label) {
  pts <- od_sf_3857 |>
    filter(corridor_type_val == corridor_val, !is.na(tt_ratio))
  if (nrow(pts) == 0) return(NULL)
  r <- rasterize(vect(pts), r_template,
                 field = "tt_ratio", fun = "mean", background = NA)
  as.data.frame(project(r, "EPSG:4326"), xy = TRUE) |>
    rename(tt_ratio = mean) |>
    filter(!is.na(tt_ratio)) |>
    mutate(corridor_type = label)
}

priority_levels <- levels(od_sf_3857$corridor_type_val)

df_ratio_facet <- map_dfr(priority_levels, \(lv) make_ratio_raster(lv, lv)) |>
  mutate(corridor_type = factor(corridor_type, levels = priority_levels))

# =============================================================================
# 6. Shared basemap
# =============================================================================
poz_wgs      <- st_transform(poz, 4326)
car_zones_wgs <- st_transform(car_zones, 4326)

bbox_map <- od_sf_3857 |>
  st_transform(4326) |>
  st_bbox() |>
  st_as_sfc() |>
  st_buffer(0.05) |>
  st_transform(3857)

osm_map <- get_tiles(bbox_map, provider = "CartoDB.DarkMatter",
                     zoom = 11, crop = TRUE)

od_map <- od_sf_3857 |>
  filter(!is.na(tt_ratio)) |>
  mutate(
    winner = case_when(
      tt_ratio <= 1.0  ~ "PT faster",
      tt_ratio <= 1.5  ~ "Comparable",
      tt_ratio <= 2.0  ~ "Car faster (1.5–2×)",
      TRUE             ~ "Car much faster (>2×)"
    ) |> factor(levels = c(
      "PT faster", "Comparable",
      "Car faster (1.5–2×)", "Car much faster (>2×)"
    ))
  ) |>
  st_transform(4326) |>
  arrange(desc(tt_ratio))

cat("\nWinner breakdown:\n")
print(table(od_map$winner))

dark_theme <- theme_dark() +
  theme(
    panel.background  = element_rect(fill = "#1a1a1a"),
    plot.background   = element_rect(fill = "#1a1a1a"),
    legend.background = element_rect(fill = "#1a1a1a"),
    legend.key        = element_rect(fill = "#1a1a1a"),
    text              = element_text(color = "white"),
    axis.text         = element_blank(),
    axis.title        = element_blank(),
    panel.grid        = element_blank()
  )

map_limits <- list(
  xlim = st_bbox(od_map)[c("xmin", "xmax")],
  ylim = st_bbox(od_map)[c("ymin", "ymax")]
)

# =============================================================================
# 7. Fig 1 — PT vs car point map
# =============================================================================
ggplot() +
  geom_spatraster_rgb(data = osm_map, alpha = 0.85) +
  geom_sf(data = od_map, aes(colour = winner),
          size = 0.5, alpha = 0.6, shape = 16) +
  scale_colour_manual(
    values = c(
      "PT faster"             = "#2ecc71",
      "Comparable"            = "#f1c40f",
      "Car faster (1.5–2×)"  = "#e67e22",
      "Car much faster (>2×)" = "#c0392b"
    ),
    name = "Travel time"
  ) +
  geom_sf(data = poz_wgs, fill = NA, colour = "white",
          linewidth = 0.5, inherit.aes = FALSE) +
  coord_sf(crs = 4326, xlim = map_limits$xlim, ylim = map_limits$ylim) +
  labs(
    title    = "PT vs car travel time competitiveness",
    subtitle = sprintf(
      "PT faster: %s  |  Comparable: %s  |  Car faster: %s  |  Car much faster: %s",
      comma(sum(od_map$winner == "PT faster")),
      comma(sum(od_map$winner == "Comparable")),
      comma(sum(od_map$winner == "Car faster (1.5–2×)")),
      comma(sum(od_map$winner == "Car much faster (>2×)"))
    )
  ) +
  dark_theme +
  theme(
    legend.title = element_text(size = 12, color = "white"),
    legend.text  = element_text(size = 11, color = "white")
  ) +
  guides(colour = guide_legend(override.aes = list(size = 4, alpha = 1)))

ggsave("Fig_PT_vs_car_travels.png", width = 12, height = 9, dpi = 300)
cat("Saved Fig_PT_vs_car_travels.png\n")

# =============================================================================
# 8. Fig 2 — Hex bin map of median tt_ratio
# =============================================================================
od_coords <- od_map |>
  st_drop_geometry() |>
  bind_cols(st_coordinates(od_map) |> as_tibble() |> rename(lon = X, lat = Y))

ggplot() +
  geom_spatraster_rgb(data = osm_map, alpha = 0.85) +
  stat_summary_hex(
    data  = od_coords,
    aes(x = lon, y = lat, z = tt_ratio),
    fun   = "median",
    bins  = 60,
    alpha = 0.85
  ) +
  scale_fill_gradientn(
    colours = c("#2ecc71", "#f1c40f", "#e67e22", "#c0392b"),
    values  = rescale(c(0.8, 1.0, 1.5, 2.0, 4.0)),
    limits  = c(0.8, quantile(od_coords$tt_ratio, 0.99)),
    oob     = squish,
    name    = "Median\nPT/Car ratio",
    breaks  = c(1.0, 1.5, 2.0),
    labels  = c("1.0×\n(parity)", "1.5×", "2.0×")
  ) +
  geom_sf(data = poz_wgs, fill = NA, colour = "white",
          linewidth = 0.5, inherit.aes = FALSE) +
  coord_sf(crs = 4326, xlim = map_limits$xlim, ylim = map_limits$ylim) +
  labs(
    title    = "PT vs car travel time competitiveness",
    subtitle = sprintf(
      "PT faster: %.1f%%  |  Comparable: %.1f%%  |  Car faster: %.1f%%  |  Car much faster: %.1f%%",
      100 * mean(od_map$winner == "PT faster"),
      100 * mean(od_map$winner == "Comparable"),
      100 * mean(od_map$winner == "Car faster (1.5–2×)"),
      100 * mean(od_map$winner == "Car much faster (>2×)")
    )
  ) +
  dark_theme +
  theme(
    legend.title = element_text(size = 12, color = "white"),
    legend.text  = element_text(size = 11, color = "white")
  ) +
  guides(fill = guide_colourbar(
    barwidth = 10, barheight = 0.8,
    title.position = "top", direction = "horizontal"
  ))

ggsave("Fig_PT_vs_car_travels_HEX.png", width = 12, height = 9, dpi = 300)
cat("Saved Fig_PT_vs_car_travels_HEX.png\n")

# =============================================================================
# 9. Fig 3 — Origin-level mean tt_ratio
# =============================================================================
od_map |>
  st_drop_geometry() |>
  bind_cols(st_coordinates(od_map) |> as_tibble()) |>
  summarise(
    total_od_pairs = n(),
    unique_origins = n_distinct(from_id),
    unique_coords  = n_distinct(paste(round(X, 5), round(Y, 5)))
  ) |>
  print()

od_origins <- od_map |>
  st_drop_geometry() |>
  bind_cols(st_coordinates(od_map) |> as_tibble() |> rename(lon = X, lat = Y)) |>
  group_by(from_id, lon, lat) |>
  summarise(
    n_destinations = n(),
    mean_tt_ratio  = mean(tt_ratio),
    pct_car_faster = mean(tt_ratio > 1.5),
    .groups = "drop"
  ) |>
  st_as_sf(coords = c("lon", "lat"), crs = 4326)

cat("Unique origins:", nrow(od_origins), "\n")

ggplot() +
  geom_spatraster_rgb(data = osm_map, alpha = 0.85) +
  geom_sf(
    data  = od_origins |> arrange(mean_tt_ratio),
    aes(colour = mean_tt_ratio, size = n_destinations),
    alpha = 0.8, shape = 16
  ) +
  scale_colour_gradientn(
    colours = c("#2ecc71", "#f1c40f", "#e67e22", "#c0392b"),
    values  = rescale(c(0.8, 1.3, 2.0, 3.0, 4.0)),
    limits  = c(0.8, quantile(od_origins$mean_tt_ratio, 0.99)),
    oob     = squish,
    name    = "Mean PT/Car\ntime ratio",
    breaks  = c(1.0, 1.5, 2.0),
    labels  = c("1.0×\n(parity)", "1.5×", "2.0×")
  ) +
  scale_size_continuous(range = c(1, 6), name = "N destinations") +
  geom_sf(data = poz_wgs, fill = NA, colour = "white",
          linewidth = 0.5, inherit.aes = FALSE) +
  coord_sf(crs = 4326, xlim = map_limits$xlim, ylim = map_limits$ylim) +
  labs(
    title    = "PT vs car travel time competitiveness by origin",
    subtitle = sprintf(
      "%s unique origins  |  %s total OD pairs  |  Mean ratio: %.2f×",
      comma(nrow(od_origins)),
      comma(nrow(od_map)),
      mean(od_map$tt_ratio)
    )
  ) +
  dark_theme +
  theme(
    legend.title = element_text(size = 11, color = "white"),
    legend.text  = element_text(size = 10, color = "white")
  ) +
  guides(
    colour = guide_colourbar(barwidth = 10, barheight = 0.8,
                             title.position = "top", direction = "horizontal"),
    size   = guide_legend(override.aes = list(colour = "white"))
  )

ggsave("Fig_PT_vs_car_travels_by_origin.png", width = 12, height = 9, dpi = 300)
cat("Saved Fig_PT_vs_car_travels_by_origin.png\n")
