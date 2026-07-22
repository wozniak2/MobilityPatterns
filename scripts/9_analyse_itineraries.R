library(tidyverse)
library(sf)
library(spdep)
library(tidytransit)
library(maptiles)
library(tidyterra)
library(terra)
library(osmdata)

setwd("C:/Users/wozni/Google Drive/UAM/HUB/MobilityPatterns/Data")
source("C:/Users/wozni/OneDrive/Documents/GitHub/MobilityPatterns/scripts/lisa_priority_utils.R")
dir.create("../Figures", showWarnings = FALSE)

# Itineraries produced by 5_read_itineraries.R (rasterized at 120m per county)
results <- readRDS("itineraries_results.rds")

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
stops_poznan <- load_gtfs_stops("gtfs")

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

coords_mat <- st_coordinates(diff_sf)
nb <- dnearneigh(coords_mat, d1 = 0, d2 = cell_size * 1.5)
lw <- nb2listw(nb, style = "W", zero.policy = TRUE)

moran_result <- moran.test(diff_sf$diff, lw, zero.policy = TRUE)
print(moran_result)

# ── 4. Local Moran's I (LISA) — locate significant clusters ──────────────────
diff_sf <- compute_lisa(diff_sf, cell_size)

# ── 5. Assign population to all pixels via nearest GHS-POP grid cell ─────────
pop_grid   <- st_read("pop_grid.gpkg", quiet = TRUE)
pop_grid_r <- st_transform(pop_grid, st_crs(diff_sf))

diff_sf <- diff_sf |>
  st_join(
    pop_grid_r |> select(working_age_pop),
    join = st_intersects
  )

# ── 6. Extract car-dominated zones & classify PT accessibility/priority ──────
cat("\nDeparture frequency summary:\n")
print(summary(stops_poznan$n_departures))

pop_threshold <- quantile(pop_grid_r$working_age_pop, 0.80, na.rm = TRUE)
cat("Population threshold (80th pct):", pop_threshold, "\n")

car_zones <- diff_sf %>%
  filter(lisa_type == "High-High (car cluster)") %>%
  classify_car_zones(stops_poznan, pop_threshold)

# Remove pixels inside Poznań city boundary (focus on suburban gaps)
poz <- st_read("poz.gpkg") ## donut
poz_r <- st_transform(poz, st_crs(car_zones))
outside   <- lengths(st_intersects(car_zones, st_union(poz_r))) == 0
car_zones <- car_zones[outside, ]

cat("\nPriority breakdown:\n")
print(table(car_zones$priority))

# ── 7. Diagnostic heatmap — frequency vs distance ────────────────────────────
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

# ── 8. Final map ─────────────────────────────────────────────────────────────
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
osmdata::set_overpass_url("https://overpass-api.de/api/interpreter")
roads_lines <- opq(bbox = st_bbox(car_zones_wgs), timeout = 60) %>%
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

print(table(car_zones$priority))

ggsave("../Figures/Fig_PT_investment_priority.png", width = 12, height = 9, dpi = 300)
