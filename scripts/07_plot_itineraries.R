# =============================================================================
# 07_plot_itineraries.R
#
# Map-based flow-density visualisation of PT vs. car itineraries, plus
# route-level descriptive statistics (duration, distance, transfers,
# PT/car competitiveness breakdown) comparing the two modes per OD pair.
#
# REQUIRES TO RUN:
#   - itineraries_results.rds, pt_itineraries.rds, car_itineraries.rds
#     (all written by 05_read_itineraries.R — run that script first if any
#     is missing)
#   - od_pair_utils.R, sourced automatically below (not run directly)
# OUTPUT : Figures/Fig_cars_pt_itineraries.png
#          Figures/Fig_duration_boxplot_pt_car.png
#          Figures/Fig_distance_boxplot_pt_car.png
#          itinerary_summary_stats.csv
#          itinerary_competitiveness_breakdown.csv
# =============================================================================

library(dplyr)
library(tidyr)
library(tibble)
library(purrr)
library(sf)
library(ggplot2)
library(terra)
library(patchwork)
library(maptiles)
library(tidyterra)

setwd("C:/Users/wozni/Google Drive/UAM/HUB/MobilityPatterns/Data")
source("C:/Users/wozni/OneDrive/Documents/GitHub/MobilityPatterns/scripts/od_pair_utils.R")
dir.create("../Figures", showWarnings = FALSE)

# Read itineraries produced by 05_read_itineraries.R (rasterized at 120m per county)
results <- readRDS("itineraries_results.rds")
cell_size <- 120

poz <- st_read("poz.gpkg", quiet = TRUE) ## Poznan core city boundary

# ── Aggregate PT and Car rasters for visualisation ───────────────────────────

aggregate_flow_raster <- function(df, cell_size, fact = 3, crs_in = 3857) {
  
  pts <- df %>% st_as_sf(coords = c("x", "y"), crs = crs_in)
  
  r_template <- rast(
    ext        = ext(vect(pts)),
    resolution = cell_size,
    crs        = paste0("EPSG:", crs_in)
  )
  
  r_raw <- rasterize(vect(pts), r_template, 
                     field = "freq", fun = "sum", background = NA)
  r_agg <- aggregate(r_raw, fact = fact, fun = "sum")
#  r_wgs <- project(r_agg, "EPSG:4326")
  
  as.data.frame(r_agg, xy = TRUE) %>%
    rename(freq = sum) %>%
    filter(!is.na(freq))
}


# Combine counties & compute log-frequency difference ───────────────────
df_cit <- map_dfr(results, ~ .x$df_cit)
df_pit <- map_dfr(results, ~ .x$df_pit)

# ── Run for both modes ────────────────────────────────────────────────────────
df_plot_pt  <- aggregate_flow_raster(df_pit, cell_size, fact = 1)
df_plot_car <- aggregate_flow_raster(df_cit, cell_size, fact = 1)


poz_3857 <- st_transform(poz, crs = 3857)

# ── Shared basemap, same recipe as 09_OD_comparison.R's Fig_PT_vs_car_travels
# (CartoDB.DarkMatter via maptiles::get_tiles(), drawn with geom_spatraster_rgb())
# -- added 2026-08-26 so this flow-density figure carries the same geographic
# context (real streets/water/built-up area) as that sibling map figure,
# instead of floating on a flat black panel. One shared bbox/tile fetch for
# both panels (rather than two independent ones) so PT and car sit on
# identical basemap coverage and stay directly visually comparable, matching
# how the flow rasters themselves already share one legend fill scale.
combined_xy <- bind_rows(select(df_plot_pt, x, y), select(df_plot_car, x, y))
bbox_flow_3857 <- st_bbox(c(xmin = min(combined_xy$x), xmax = max(combined_xy$x),
                            ymin = min(combined_xy$y), ymax = max(combined_xy$y)),
                          crs = st_crs(3857)) %>%
  st_as_sfc() %>%
  st_buffer(1500) # 1.5km margin, in metres (native 3857 units)

osm_map <- get_tiles(bbox_flow_3857, provider = "CartoDB.DarkMatter",
                      zoom = 11, crop = TRUE)

# coord_equal(expand = FALSE) -- without this, ggplot's default 5% axis
# expansion pads the panel beyond the basemap tile's own extent, showing as
# a visible margin of flat panel.background (#1a1a1a) around the map now
# that the basemap (CartoDB's own, slightly darker #0b0b0b tone) makes that
# boundary visually obvious. This expansion was always happening -- it was
# just invisible before the basemap existed, since na.value="black" on the
# bare flow raster was close enough to panel.background to hide it.

# plot
pt_iti <- ggplot(df_plot_pt) +
  geom_spatraster_rgb(data = osm_map, alpha = 0.9) +
  geom_raster(aes(x = x, y = y, fill = log1p(freq)), alpha = 0.82) +
  # Legend titled "PT frequency" (not "log1p(freq)") -- the log transform is
  # already disclosed in the figure caption, no need to clutter the legend.
  scale_fill_viridis_c(option = "viridis", na.value = "black", name = "PT frequency") +
  coord_equal(expand = FALSE) +
  geom_sf(data = poz_3857, fill = NA, colour = "white",
          linewidth = 0.6, inherit.aes = FALSE) +
  theme_dark() +

  theme(
    panel.background = element_rect(fill = "#1a1a1a"),
    plot.background  = element_rect(fill = "#1a1a1a"),
    legend.background = element_rect(fill = "#1a1a1a"),
    legend.key = element_rect(fill = "#1a1a1a"),

    text = element_text(color = "white"),
    axis.text = element_blank(),
    axis.title = element_blank(),
    axis.ticks = element_blank(),

    legend.title = element_text(size = 20, color = "white"),
    legend.text  = element_text(size = 19, color = "white"),
    # Tightened 2026-08-26: default plot.margin + legend.box.spacing left a
    # visible gap between the map and its own edges/legend once the basemap
    # made the boundary visually obvious (previously invisible against the
    # near-black flow-raster background).
    plot.margin = margin(2, 2, 2, 2),
    legend.box.spacing = unit(2, "pt"),

    panel.grid.major = element_blank(),
    panel.grid.minor = element_blank()
  )


car_iti <- ggplot(df_plot_car) +
  geom_spatraster_rgb(data = osm_map, alpha = 0.9) +
  geom_raster(aes(x = x, y = y, fill = log1p(freq)), alpha = 0.82) +
  scale_fill_viridis_c(option = "viridis", na.value = "black", name = "Car frequency") +
  coord_equal(expand = FALSE) +
  geom_sf(data = poz_3857, fill = NA, colour = "white",
          linewidth = 0.6, inherit.aes = FALSE) +
  theme_dark() +

  theme(
    panel.background = element_rect(fill = "#1a1a1a"),
    plot.background  = element_rect(fill = "#1a1a1a"),
    legend.background = element_rect(fill = "#1a1a1a"),
    legend.key = element_rect(fill = "#1a1a1a"),

    text = element_text(color = "white"),
    axis.text = element_blank(),
    axis.title = element_blank(),
    axis.ticks = element_blank(),

    legend.title = element_text(size = 20, color = "white"),
    legend.text  = element_text(size = 19, color = "white"),
    plot.margin = margin(2, 2, 2, 2),
    legend.box.spacing = unit(2, "pt"),

    panel.grid.major = element_blank(),
    panel.grid.minor = element_blank()
  )

# merge plots -- stacked vertically (PT above car), not side-by-side, per
# 2026-08-26 request. Each panel keeps the same individual size/proportions
# it had in the side-by-side layout (a 6x3.95in slot); only the arrangement
# changed (patchwork's `/` stacks in a column instead of `+`'s row), so
# total canvas is now width=6, height=3.95*2=7.9 instead of width=12, height=3.95.
require(patchwork)
pt_iti / car_iti

ggsave("../Figures/Fig_cars_pt_itineraries.png", width = 6, height = 7.9, dpi = 300)

# =============================================================================
# Descriptive statistics: PT vs. car route characteristics
# =============================================================================
# Route-level attributes (duration, distance, transfers) live on the raw
# itineraries, not the rasterized flow surfaces used for mapping above, so
# these are read separately and collapsed to one row per OD pair.

pt_itineraries  <- readRDS("pt_itineraries.rds")
car_itineraries <- readRDS("car_itineraries.rds")

# Collapse to one row per OD pair and compute tt_ratio/competitive (shared
# with 06/09/10 -- see od_pair_utils.R). Also brings has_rail/modes/
# dist_ratio/tt_diff along, unused here but harmless.
od_summary <- build_od_comparison(pt_itineraries, car_itineraries)

cat(sprintf("\nOD pairs with both PT and car itineraries: %d\n", nrow(od_summary)))

# ── Descriptive stats table (mean/median/sd/IQR) per metric and mode ─────────
describe <- function(x) {
  q <- quantile(x, c(0.25, 0.75), na.rm = TRUE)
  tibble(
    n = sum(!is.na(x)), mean = mean(x, na.rm = TRUE), median = median(x, na.rm = TRUE),
    sd = sd(x, na.rm = TRUE), min = min(x, na.rm = TRUE),
    q25 = q[[1]], q75 = q[[2]], max = max(x, na.rm = TRUE)
  )
}

summary_stats <- bind_rows(
  describe(od_summary$pt_duration_min)  %>% mutate(metric = "duration_min", mode = "PT"),
  describe(od_summary$car_duration_min) %>% mutate(metric = "duration_min", mode = "Car"),
  describe(od_summary$pt_distance_m)    %>% mutate(metric = "distance_m",   mode = "PT"),
  describe(od_summary$car_distance_m)   %>% mutate(metric = "distance_m",   mode = "Car"),
  describe(od_summary$n_transfers)      %>% mutate(metric = "n_transfers",  mode = "PT"),
  describe(od_summary$tt_ratio)         %>% mutate(metric = "tt_ratio",     mode = "PT/Car")
) %>%
  relocate(metric, mode)

cat("\nPT vs. car route descriptive statistics:\n")
print(summary_stats, width = Inf)

write.csv(summary_stats, "itinerary_summary_stats.csv", row.names = FALSE)

# ── Competitiveness breakdown ─────────────────────────────────────────────
# `competitive` already computed by build_od_comparison() above (shared
# bands, used identically by 06/09/10).
competitiveness_breakdown <- od_summary %>%
  count(competitive, name = "n_od_pairs") %>%
  mutate(share = n_od_pairs / sum(n_od_pairs))

cat("\nPT/car competitiveness breakdown:\n")
print(competitiveness_breakdown, width = Inf)
cat(sprintf("\nShare of OD pairs where car is faster by more than 1.5x: %.1f%%\n",
            100 * mean(od_summary$tt_ratio > 1.5, na.rm = TRUE)))

write.csv(competitiveness_breakdown, "itinerary_competitiveness_breakdown.csv", row.names = FALSE)

# ── Boxplots: duration and distance, PT vs. car, per OD pair ─────────────────
# Dark theme (background #1a1a1a, white text/gridlines) added 2026-08-26 to
# match the flow-density maps above and the other dark-themed figures across
# the manuscript (typology/GWR maps in 08_analyse_itineraries.R,
# 13_gwr_analysis.R) -- this pair was the one remaining light-themed figure.
duration_long <- od_summary %>%
  select(pt_duration_min, car_duration_min) %>%
  pivot_longer(everything(), names_to = "mode", values_to = "duration_min") %>%
  mutate(mode = recode(mode, pt_duration_min = "PT", car_duration_min = "Car"))

ggplot(duration_long, aes(x = mode, y = duration_min, fill = mode)) +
  geom_boxplot(colour = "white", outlier.shape = 21, outlier.colour = "white",
               outlier.fill = "grey70", outlier.stroke = 0.3,
               outlier.alpha = 0.35, linewidth = 0.5) +
  # Viridis stops, shared with Figure 7's rail/no-rail palette (06_travel_ratio_analysis.R)
  # for cross-figure coherence: the lower/faster category gets the cooler
  # (low-value) viridis stop, the higher/slower category the warmer
  # (high-value) one -- matching viridis's own low-to-high convention against
  # what's actually being measured, not an arbitrary re-skin.
  scale_fill_manual(values = c(Car = "#9B59B6", PT = "#FDE725")) +
  labs(x = NULL, y = "Duration (min)") +
  theme_dark(base_size = 18) +
  theme(
    panel.background  = element_rect(fill = "#1a1a1a"),
    plot.background   = element_rect(fill = "#1a1a1a", colour = NA),
    legend.position   = "none",
    text              = element_text(color = "white"),
    axis.title        = element_text(size = 20, color = "white"),
    axis.text         = element_text(size = 19, color = "white"),
    panel.grid.major  = element_line(colour = "grey30"),
    panel.grid.minor  = element_blank()
  )

ggsave("../Figures/Fig_duration_boxplot_pt_car.png", width = 6, height = 5, dpi = 300)

distance_long <- od_summary %>%
  select(pt_distance_m, car_distance_m) %>%
  pivot_longer(everything(), names_to = "mode", values_to = "distance_m") %>%
  mutate(mode = recode(mode, pt_distance_m = "PT", car_distance_m = "Car"))

ggplot(distance_long, aes(x = mode, y = distance_m, fill = mode)) +
  geom_boxplot(colour = "white", outlier.shape = 21, outlier.colour = "white",
               outlier.fill = "grey70", outlier.stroke = 0.3,
               outlier.alpha = 0.35, linewidth = 0.5) +
  scale_fill_manual(values = c(Car = "#9B59B6", PT = "#FDE725")) +
  labs(x = NULL, y = "Distance (m)") +
  theme_dark(base_size = 18) +
  theme(
    panel.background  = element_rect(fill = "#1a1a1a"),
    plot.background   = element_rect(fill = "#1a1a1a", colour = NA),
    legend.position   = "none",
    text              = element_text(color = "white"),
    axis.title        = element_text(size = 20, color = "white"),
    axis.text         = element_text(size = 19, color = "white"),
    panel.grid.major  = element_line(colour = "grey30"),
    panel.grid.minor  = element_blank()
  )

ggsave("../Figures/Fig_distance_boxplot_pt_car.png", width = 6, height = 5, dpi = 300)
cat("\nSaved Figures/Fig_duration_boxplot_pt_car.png and Fig_distance_boxplot_pt_car.png\n")
