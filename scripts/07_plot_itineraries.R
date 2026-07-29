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

# plot
pt_iti <- ggplot(df_plot_pt) +
  geom_raster(aes(x = x, y = y, fill = log1p(freq))) +
  scale_fill_viridis_c(option = "viridis", na.value = "black") +
  coord_equal() +
  geom_sf(data = poz_3857, fill = NA, colour = "red",
          linewidth = 0.4, inherit.aes = FALSE) +
  theme_dark(base_size = 20) +

  theme(
    panel.background = element_rect(fill = "#1a1a1a"),
    plot.background  = element_rect(fill = "#1a1a1a"),
    legend.background = element_rect(fill = "#1a1a1a"),
    legend.key = element_rect(fill = "#1a1a1a"),

    text = element_text(color = "white"),
    axis.text = element_blank(),
    axis.title = element_blank(),

    legend.title = element_text(size = 20, color = "white"),
    legend.text  = element_text(size = 19, color = "white"),

    panel.grid.major = element_blank(),
    panel.grid.minor = element_blank()
  )


car_iti <- ggplot(df_plot_car) +
  geom_raster(aes(x = x, y = y, fill = log1p(freq))) +
  scale_fill_viridis_c(option = "viridis", na.value = "black") +
  coord_equal() +
  geom_sf(data = poz_3857, fill = NA, colour = "red",
          linewidth = 0.4, inherit.aes = FALSE) +
  theme_dark(base_size = 20) +

  theme(
    panel.background = element_rect(fill = "#1a1a1a"),
    plot.background  = element_rect(fill = "#1a1a1a"),
    legend.background = element_rect(fill = "#1a1a1a"),
    legend.key = element_rect(fill = "#1a1a1a"),

    text = element_text(color = "white"),
    axis.text = element_blank(),
    axis.title = element_blank(),

    legend.title = element_text(size = 20, color = "white"),
    legend.text  = element_text(size = 19, color = "white"),

    panel.grid.major = element_blank(),
    panel.grid.minor = element_blank()
  )

# merge plots
require(patchwork)
pt_iti + car_iti

# Both panels use coord_equal() on a near-square extent (data x:y aspect ~1.05-1.10),
# so at width=12in the map area only needs ~4in of height to fill the canvas --
# height=9 left a large empty top/bottom margin (same fill colour as the panel
# background, so it rendered as solid black bars).
ggsave("../Figures/Fig_cars_pt_itineraries.png", width = 12, height = 3.95, dpi = 300)

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
duration_long <- od_summary %>%
  select(pt_duration_min, car_duration_min) %>%
  pivot_longer(everything(), names_to = "mode", values_to = "duration_min") %>%
  mutate(mode = recode(mode, pt_duration_min = "PT", car_duration_min = "Car"))

ggplot(duration_long, aes(x = mode, y = duration_min, fill = mode)) +
  geom_boxplot(outlier.alpha = 0.2) +
  scale_fill_manual(values = c(PT = "#2980b9", Car = "#c0392b")) +
  labs(x = NULL, y = "Duration (min)") +
  theme_minimal(base_size = 18) +
  theme(
    legend.position = "none",
    axis.title  = element_text(size = 20),
    axis.text   = element_text(size = 19)
  )

ggsave("../Figures/Fig_duration_boxplot_pt_car.png", width = 6, height = 5, dpi = 300)

distance_long <- od_summary %>%
  select(pt_distance_m, car_distance_m) %>%
  pivot_longer(everything(), names_to = "mode", values_to = "distance_m") %>%
  mutate(mode = recode(mode, pt_distance_m = "PT", car_distance_m = "Car"))

ggplot(distance_long, aes(x = mode, y = distance_m, fill = mode)) +
  geom_boxplot(outlier.alpha = 0.2) +
  scale_fill_manual(values = c(PT = "#2980b9", Car = "#c0392b")) +
  labs(x = NULL, y = "Distance (m)") +
  theme_minimal(base_size = 18) +
  theme(
    legend.position = "none",
    axis.title  = element_text(size = 20),
    axis.text   = element_text(size = 19)
  )

ggsave("../Figures/Fig_distance_boxplot_pt_car.png", width = 6, height = 5, dpi = 300)
cat("\nSaved Figures/Fig_duration_boxplot_pt_car.png and Fig_distance_boxplot_pt_car.png\n")
