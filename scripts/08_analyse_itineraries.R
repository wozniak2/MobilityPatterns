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

# Itineraries produced by 05_read_itineraries.R (rasterized at 120m per county)
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

cat("\nLISA cluster breakdown (all cells):\n")
print(table(diff_sf$lisa_type))

poz <- st_read("poz.gpkg", quiet = TRUE) ## Poznan core city boundary

# ── 4b. LISA cluster map (HH/LL/HL/LH) ────────────────────────────────────────
diff_sf_wgs <- st_transform(diff_sf, 4326)
poz_wgs     <- st_transform(poz, 4326)

ggplot() +
  geom_sf(
    data        = diff_sf_wgs %>% filter(lisa_type != "Not significant"),
    aes(colour  = lisa_type),
    size        = 0.5, alpha = 0.8, shape = 15,
    inherit.aes = FALSE
  ) +
  geom_sf(data = poz_wgs, fill = NA, colour = "white",
          linewidth = 0.4, inherit.aes = FALSE) +
  scale_colour_manual(
    values = c(
      "High-High (car cluster)" = "#c0392b",
      "Low-Low (PT cluster)"    = "#2980b9",
      "High-Low (car outlier)"  = "#e67e22",
      "Low-High (PT outlier)"   = "#8e44ad"
    ),
    name = "LISA cluster"
  ) +
  coord_sf(crs = 4326) +
  labs(
    title    = "Spatial clustering of the car/PT modal gap (LISA)",
    subtitle = "Local Moran's I, p < 0.05; non-significant cells omitted"
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
  )

ggsave("../Figures/Fig_LISA_cluster_map.png", width = 12, height = 9, dpi = 300)
cat("Saved Figures/Fig_LISA_cluster_map.png\n")

# ── 5. Assign population to all pixels via nearest GHS-POP grid cell ─────────
pop_grid   <- st_read("pop_grid.gpkg", quiet = TRUE)
pop_grid_r <- st_transform(pop_grid, st_crs(diff_sf))

diff_sf <- diff_sf |>
  st_join(
    pop_grid_r |> select(grid_id, working_age_pop),
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
poz_r <- st_transform(poz, st_crs(car_zones))
outside   <- lengths(st_intersects(car_zones, st_union(poz_r))) == 0
car_zones <- car_zones[outside, ]

cat("\nPriority breakdown:\n")
print(table(car_zones$priority))

# ── 6b. Rail access by investment priority class ─────────────────────────────
# "Unexplained car dominance" cells are, by definition (Table 3 typology),
# already well served on physical accessibility and frequency, so the gap
# there is not explained by stop proximity or departure frequency alone --
# it is left open whether the remaining barrier is behavioural or an
# unmeasured service-quality gap (see manuscript). This checks how much of
# that class is specifically explained by rail vs. bus-only service: a high
# rail share would suggest the remaining barrier persists even where the
# mode itself is rail, while a low rail share is also consistent with rail
# access simply being geometrically scarce in these suburbs, not with either
# reading being confirmed.
rail_by_priority <- car_zones %>%
  st_drop_geometry() %>%
  count(priority, nearest_stop_is_rail) %>%
  group_by(priority) %>%
  mutate(share = n / sum(n)) %>%
  ungroup()

cat("\nRail access by investment priority class:\n")
print(rail_by_priority)
write.csv(rail_by_priority, "rail_access_by_priority.csv", row.names = FALSE)

car_pref_rail_share <- rail_by_priority %>%
  filter(priority == "Unexplained car dominance", nearest_stop_is_rail) %>%
  pull(share)
if (length(car_pref_rail_share) == 0) car_pref_rail_share <- 0

cat(sprintf(
  "\nOf cells classified as 'Unexplained car dominance', %.1f%% already have rail access at the nearest stop.\n",
  100 * car_pref_rail_share
))

# ── 6c. Residents affected by each investment priority class ─────────────────
# working_age_pop is per-raster-pixel (inherited from the nearest 200m
# population grid cell via the st_join in step 5), so simply summing it
# across pixels of a given priority class would grossly over-count actual
# residents: many adjacent 120m pixels share the same underlying 200m
# population cell, and each would re-contribute that cell's full
# population. grid_id (the population cell's own identifier, now carried
# through the step-5 join) is used instead to sum residents once per
# DISTINCT population cell touched by each priority class, not once per
# pixel. A population cell that touches pixels of more than one priority
# class (possible near a class boundary) is counted once in each -- a
# modest, disclosed double-count, but far more defensible than the
# per-pixel sum.
residents_by_priority <- car_zones %>%
  st_drop_geometry() %>%
  distinct(priority, grid_id, working_age_pop) %>%
  group_by(priority) %>%
  summarise(
    n_population_cells = n(),
    residents           = sum(working_age_pop, na.rm = TRUE),
    .groups = "drop"
  )

cat("\nResidents affected by investment priority class (deduplicated by population grid cell):\n")
print(residents_by_priority)
write.csv(residents_by_priority, "residents_by_priority.csv", row.names = FALSE)

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

# Fetch primary, secondary and tertiary roads from OSM. This is a purely
# decorative context layer for the map below (not used in any analysis),
# and the public Overpass endpoint returns occasional 504s under load
# regardless of query size -- rather than let a flaky external call abort
# the whole script (everything analytically important up to this point,
# including residents_by_priority.csv, has already been written), retry
# once against a mirror and fall back to an empty roads layer if both
# fail. The map still renders, just without the grey road overlay.
fetch_osm_roads <- function(bbox, overpass_url) {
  osmdata::set_overpass_url(overpass_url)
  opq(bbox = bbox, timeout = 90) %>%
    add_osm_feature(key = "highway", value = c("primary", "secondary", "tertiary")) %>%
    osmdata_sf() %>%
    .$osm_lines %>%
    st_transform(4326) %>%
    select(osm_id, name, highway)
}

empty_roads_sf <- st_sf(
  osm_id = character(0), name = character(0), highway = character(0),
  geometry = st_sfc(crs = 4326)
)

roads_lines <- tryCatch(
  fetch_osm_roads(st_bbox(car_zones_wgs), "https://overpass-api.de/api/interpreter"),
  error = function(e) {
    message("Primary Overpass endpoint failed (", conditionMessage(e),
            "), retrying with mirror...")
    tryCatch(
      fetch_osm_roads(st_bbox(car_zones_wgs), "https://overpass.kumi.systems/api/interpreter"),
      error = function(e2) {
        message("Overpass mirror also failed (", conditionMessage(e2),
                ") -- map will render without a roads layer.")
        empty_roads_sf
      }
    )
  }
)

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
      "Unexplained car dominance"          = "yellow"
    ),
    name = "Investment priority"
  ) +
  coord_sf(crs = 4326) +
  theme_dark(base_size = 18) +
  theme(
    panel.background  = element_rect(fill = "#1a1a1a"),
    plot.background   = element_rect(fill = "#1a1a1a"),
    legend.background = element_rect(fill = "#1a1a1a"),
    legend.key        = element_rect(fill = "#1a1a1a"),
    text              = element_text(color = "white"),
    axis.text         = element_blank(),
    axis.title        = element_blank(),
    legend.title      = element_text(size = 20, color = "white"),
    legend.text       = element_text(size = 19, color = "white"),
    panel.grid.major  = element_blank(),
    panel.grid.minor  = element_blank()
  ) +
  guides(color = guide_legend(override.aes = list(size = 6)))

print(table(car_zones$priority))

# coord_sf() locks the panel to the map's true aspect ratio, which is narrower
# than the old height=9 canvas at width=12 -- that left an empty top/bottom
# margin (same fill as plot.background) that rendered as solid black bars.
ggsave("../Figures/Fig_PT_investment_priority.png", width = 12, height = 6.56, dpi = 300)

# ── 9. Robustness check: population/workplace-weighted modal gap surface ────
# The modal gap surface above (step 1) counts raw ROUTES through each pixel
# -- a route from a near-empty grid cell counts the same as one from a
# densely populated cell. This rebuilds the same log-difference surface but
# weights each itinerary by working_age_pop(origin) x workplaces(destination)
# before rasterizing, then re-runs LISA, to check whether the car-dominant
# (HH) clusters reported above are genuinely demand-driven or partly an
# artifact of raw route presence in low-demand cells.
cat("\n=== Robustness check: population/workplace-weighted modal gap ===\n")

# itineraries_results.rds (loaded at the top) only carries the pre-rasterized
# counts, not the route geometries needed to rasterize by weight instead of
# unit count -- load the raw itineraries (also written by
# 05_read_itineraries.R) for that.
pt_itineraries  <- readRDS("pt_itineraries.rds")
car_itineraries <- readRDS("car_itineraries.rds")

work_grid <- st_read("workplace_grid.gpkg", quiet = TRUE)
pop_grid_2180  <- pop_grid_r  # already population grid transformed to 2180 (step 5)
work_grid_2180 <- st_transform(work_grid, 2180)

# Per-OD-pair weight, joined by nearest-feature (confirmed to match
# st_intersects exactly for these grid-derived coordinates -- see
# 11_validate_od_flows.R diagnostics; nearest-feature used here so a point
# can never fail to match).
od_weights <- bind_rows(
  car_itineraries %>% st_drop_geometry() %>%
    distinct(from_id, to_id, from_lon, from_lat, to_lon, to_lat),
  pt_itineraries  %>% st_drop_geometry() %>%
    distinct(from_id, to_id, from_lon, from_lat, to_lon, to_lat)
) %>%
  distinct(from_id, to_id, .keep_all = TRUE)

origin_pts <- od_weights %>% distinct(from_id, from_lon, from_lat) %>%
  st_as_sf(coords = c("from_lon", "from_lat"), crs = 4326) %>% st_transform(2180)
dest_pts <- od_weights %>% distinct(to_id, to_lon, to_lat) %>%
  st_as_sf(coords = c("to_lon", "to_lat"), crs = 4326) %>% st_transform(2180)

origin_pop <- tibble(
  from_id = origin_pts$from_id,
  origin_pop = pop_grid_2180$working_age_pop[st_nearest_feature(origin_pts, pop_grid_2180)]
)
dest_wp <- tibble(
  to_id = dest_pts$to_id,
  dest_workplaces = work_grid_2180$workplaces[st_nearest_feature(dest_pts, work_grid_2180)]
)

od_weights <- od_weights %>%
  left_join(origin_pop, by = "from_id") %>%
  left_join(dest_wp, by = "to_id") %>%
  mutate(weight = origin_pop * dest_workplaces) %>%
  select(from_id, to_id, weight)

pt_itineraries_w  <- pt_itineraries  %>% left_join(od_weights, by = c("from_id", "to_id"))
car_itineraries_w <- car_itineraries %>% left_join(od_weights, by = c("from_id", "to_id"))

# Per-county rasterization, mirroring 05_read_itineraries.R's process_county()
# exactly -- a single global rasterize() over every itinerary in the metro
# area (all counties at once) does not scale (line-in-polygon accumulation
# over ~1M+ geometries against one huge extent ran for 2+ hours without
# finishing). Each county's extent and feature count is much smaller, which
# is why 05 already processes counties one at a time for the unweighted
# surface. County-level pixel grids don't need to align across counties --
# diff_sf_w is built from the resulting (x, y) points directly, the same way
# step 1 above combines df_cit/df_pit across counties.
rasterize_weighted_county <- function(itin_sf, resolution) {
  itin_3857 <- st_transform(itin_sf, 3857)
  v <- vect(itin_3857)
  r <- rast(ext(v), resolution = resolution, crs = "EPSG:3857")
  rasterize(v, r, field = "weight", fun = "sum", background = NA)
}

rasterize_weighted_all_counties <- function(itin_sf, resolution) {
  counties <- unique(itin_sf$county)
  map_dfr(counties, function(cty) {
    sub <- itin_sf %>% filter(county == cty)
    if (nrow(sub) == 0) return(NULL)
    cat("  rasterizing county:", cty, "(", nrow(sub), "rows )\n")
    r <- rasterize_weighted_county(sub, resolution)
    as.data.frame(r, xy = TRUE) %>% rename(weight = 3)
  })
}

cat("Rasterizing weighted car itineraries by county...\n")
df_cit_w <- rasterize_weighted_all_counties(car_itineraries_w, cell_size)
cat("Rasterizing weighted PT itineraries by county...\n")
df_pit_w <- rasterize_weighted_all_counties(pt_itineraries_w, cell_size)

diff_df_w <- full_join(
  df_cit_w %>% mutate(log_freq = log1p(weight)) %>% select(x, y, log_freq),
  df_pit_w %>% mutate(log_freq = log1p(weight)) %>% select(x, y, log_freq),
  by     = c("x", "y"),
  suffix = c("_car", "_pt")
) %>%
  mutate(
    across(starts_with("log_freq"), ~replace_na(.x, 0)),
    diff = log_freq_car - log_freq_pt
  )

diff_sf_w <- diff_df_w %>%
  filter(!is.na(diff)) %>%
  st_as_sf(coords = c("x", "y"), crs = 3857) %>%
  st_transform(2180)

diff_sf_w <- compute_lisa(diff_sf_w, cell_size)

cat("\nWeighted LISA cluster breakdown:\n")
print(table(diff_sf_w$lisa_type))
cat("\nUnweighted LISA cluster breakdown (for comparison):\n")
print(table(diff_sf$lisa_type))

# Cross-tab via nearest-feature match (grids from the two rasterization
# passes aren't guaranteed pixel-aligned, so match by location rather than
# assuming identical x/y grids).
nearest_w <- st_nearest_feature(diff_sf, diff_sf_w)
diff_sf$lisa_type_weighted <- diff_sf_w$lisa_type[nearest_w]

cat("\nCross-tab: unweighted vs. population/workplace-weighted LISA classification:\n")
lisa_crosstab <- table(unweighted = diff_sf$lisa_type, weighted = diff_sf$lisa_type_weighted)
print(lisa_crosstab)
write.csv(as.data.frame(lisa_crosstab), "lisa_weighted_robustness_crosstab.csv", row.names = FALSE)

agreement <- mean(diff_sf$lisa_type == diff_sf$lisa_type_weighted)
cat(sprintf("\nOverall classification agreement: %.1f%%\n", 100 * agreement))

hh_original <- diff_sf %>% st_drop_geometry() %>% filter(lisa_type == "High-High (car cluster)")
hh_agreement <- mean(hh_original$lisa_type_weighted == "High-High (car cluster)")
cat(sprintf(
  "Of cells originally classified as car-dominant (HH), %.1f%% remain so once weighted by population/workplaces.\n",
  100 * hh_agreement
))
