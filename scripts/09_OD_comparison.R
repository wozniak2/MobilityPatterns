# =============================================================================
# 09_OD_comparison.R
# OD travel time comparison: PT vs car
# REQUIRES TO RUN: pt_itineraries.rds, car_itineraries.rds (written by
#   05_read_itineraries.R — run that script first if either is missing),
#   poz.gpkg, and od_pair_utils.R (sourced automatically below, not run
#   directly)
# Produces: Fig_PT_vs_car_travels.png
#           Fig_PT_vs_car_travels_HEX.png
#           Fig_PT_vs_car_travels_by_origin.png
# =============================================================================

library(sf)
library(tidyverse)
library(terra)
library(tidyr)
library(maptiles)
library(tidyterra)
library(scales)

# ── 0. Paths — edit here only ─────────────────────────────────────────────────
setwd("C:/Users/wozni/Google Drive/UAM/HUB/MobilityPatterns/Data")
source("C:/Users/wozni/OneDrive/Documents/GitHub/MobilityPatterns/scripts/od_pair_utils.R")
dir.create("../Figures", showWarnings = FALSE)

POZ_FILE  <- "poz.gpkg"

# =============================================================================
# 1. Load itineraries produced by 05_read_itineraries.R
# =============================================================================
pt_itineraries  <- readRDS("pt_itineraries.rds")
car_itineraries <- readRDS("car_itineraries.rds")

cat(sprintf("PT rows : %d\nCar rows: %d\n",
            nrow(pt_itineraries), nrow(car_itineraries)))

# =============================================================================
# 2. Build OD comparison table (shared with 06/07/10 -- see od_pair_utils.R)
# =============================================================================
od_comparison <- build_od_comparison(pt_itineraries, car_itineraries)

od_sf_3857 <- od_comparison |>
  st_as_sf(coords = c("from_lon", "from_lat"), crs = 4326) |>
  st_transform(3857)

cat("OD pairs:", nrow(od_sf_3857), "\n")
cat("Lon range:", range(od_comparison$from_lon), "\n")
cat("Lat range:", range(od_comparison$from_lat), "\n")

# =============================================================================
# 3. Shared basemap
# =============================================================================
poz     <- st_read(POZ_FILE, quiet = TRUE)
poz_wgs <- st_transform(poz, 4326)

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
# 4. Fig 1 — PT vs car point map
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

ggsave("../Figures/Fig_PT_vs_car_travels.png", width = 12, height = 9, dpi = 300)
cat("Saved Fig_PT_vs_car_travels.png\n")

# =============================================================================
# 5. Fig 2 — Hex bin map of median tt_ratio
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

ggsave("../Figures/Fig_PT_vs_car_travels_HEX.png", width = 12, height = 9, dpi = 300)
cat("Saved Fig_PT_vs_car_travels_HEX.png\n")

# =============================================================================
# 6. Fig 3 — Origin-level mean tt_ratio
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

ggsave("../Figures/Fig_PT_vs_car_travels_by_origin.png", width = 12, height = 9, dpi = 300)
cat("Saved Fig_PT_vs_car_travels_by_origin.png\n")
