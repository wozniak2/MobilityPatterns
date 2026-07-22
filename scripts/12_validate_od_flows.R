# =============================================================================
# 12_validate_od_flows.R
#
# Validates synthetic (r5r-routed) commuting connections against empirical
# census origin-destination commuting flows (LAU-to-LAU), restricted to
# neighborhood -> core commuting: flows from the municipalities surrounding
# Poznań into the Poznań core itself (the classic suburb-to-centre commute
# this study is actually about, not core-internal or core-to-core flows).
#
# Synthetic itineraries carry no modelled trip volume -- r5r only tells you
# whether a grid-cell pair is routable, not how many people use it -- so we
# proxy volume with a population x workplace gravity weight per surviving
# grid-cell OD pair, aggregated to the municipality level, and compare that
# against census commuter counts via rank correlation (Spearman): since the
# proxy is not on the same scale as a literal commuter count, only a
# monotonic relationship (and relative share across municipalities) is
# defensible to claim -- not absolute magnitude.
#
# CORE DETECTION: workplace_grid.gpkg is itself clipped to the Poznań city
# boundary (see 01_calculate_workplaces.R), so "core" is detected empirically
# as whichever municipality nearly all destination points fall into, rather
# than hardcoding a name string. "Neighborhood" = the other municipalities in
# ap.gpkg (the tightly-integrated agglomeration ring), since pop_grid.gpkg is
# itself clipped to `ap` -- the wider poz.gpkg "donut" ring has no synthetic
# coverage at all and is not part of "neighborhood" here.
#
# INPUT  : pt_itineraries.rds, car_itineraries.rds (from 05_read_itineraries.R)
#          pop_grid.gpkg, workplace_grid.gpkg (from steps 1-2)
#          ap.gpkg (municipality boundaries, core + immediate ring)
#          OD_flows.csv (census LAU-to-LAU commuting matrix)
# OUTPUT : od_validation_neighborhood_to_core.csv
#          Figures/Fig_od_validation_scatter.png
#          Figures/Fig_od_validation_share_by_municipality.png
# =============================================================================

library(sf)
library(tidyverse)
library(scales)

setwd("C:/Users/wozni/Google Drive/UAM/HUB/MobilityPatterns/Data")
dir.create("../Figures", showWarnings = FALSE)

normalize_name <- function(x) x %>% str_trim() %>% str_squish()

# ── 1. Load synthetic itineraries and base grids ─────────────────────────────
pt_itineraries  <- readRDS("pt_itineraries.rds")
car_itineraries <- readRDS("car_itineraries.rds")

pop_grid  <- st_read("pop_grid.gpkg", quiet = TRUE)       %>% st_transform(2180)
work_grid <- st_read("workplace_grid.gpkg", quiet = TRUE) %>% st_transform(2180)

# Municipality boundaries: the agglomeration ring (core + immediate neighbors)
ap <- st_read("ap.gpkg", quiet = TRUE) %>%
  select(JPT_NAZWA_) %>%
  st_transform(2180) %>%
  mutate(JPT_NAZWA_ = normalize_name(JPT_NAZWA_))

# ── 2. Distinct grid-cell OD pairs actually routed ────────────────────────────
# Car routing succeeds almost everywhere on the road network, so the union of
# car- and PT-reachable pairs is the best proxy for "all attempted pairs"
# after the population/workplace cutoffs applied in 4_r5r_route_batch.R.
od_pairs <- bind_rows(
  car_itineraries %>% st_drop_geometry() %>%
    distinct(from_id, to_id, from_lon, from_lat, to_lon, to_lat),
  pt_itineraries  %>% st_drop_geometry() %>%
    distinct(from_id, to_id, from_lon, from_lat, to_lon, to_lat)
) %>%
  distinct(from_id, to_id, .keep_all = TRUE)

cat("Distinct grid-cell OD pairs:", nrow(od_pairs), "\n")

# ── 3. Attach population (origin), workplaces (destination), municipality ───
origin_sf <- od_pairs %>%
  st_as_sf(coords = c("from_lon", "from_lat"), crs = 4326) %>%
  st_transform(2180)

dest_sf <- od_pairs %>%
  st_as_sf(coords = c("to_lon", "to_lat"), crs = 4326) %>%
  st_transform(2180)

od_pairs <- od_pairs %>%
  mutate(
    working_age_pop   = pop_grid$working_age_pop[st_nearest_feature(origin_sf, pop_grid)],
    workplaces         = work_grid$workplaces[st_nearest_feature(dest_sf, work_grid)],
    home_municipality = ap$JPT_NAZWA_[st_nearest_feature(origin_sf, ap)],
    work_municipality = ap$JPT_NAZWA_[st_nearest_feature(dest_sf, ap)]
  )

# ── 4. Restrict to neighborhood -> core flows ─────────────────────────────────
core_name <- names(sort(table(od_pairs$work_municipality), decreasing = TRUE))[1]
neighborhood_names <- setdiff(unique(ap$JPT_NAZWA_), core_name)

cat("Detected core municipality:", core_name, "\n")
cat("Neighborhood municipalities (ap ring, excluding core):",
    length(neighborhood_names), "\n")

od_pairs <- od_pairs %>%
  filter(home_municipality %in% neighborhood_names,
         work_municipality == core_name)

cat("Grid-cell OD pairs, neighborhood -> core only:", nrow(od_pairs), "\n")

# ── 5. Aggregate to per-municipality synthetic "volume" into the core ────────
# Gravity-style proxy: population(origin) x workplaces(destination), summed
# over every surviving grid-cell pair between each neighborhood municipality
# and the core.
synthetic_flows <- od_pairs %>%
  group_by(home_municipality) %>%
  summarise(
    synthetic_connections = n(),
    synthetic_volume = sum(working_age_pop * workplaces, na.rm = TRUE),
    .groups = "drop"
  )

# ── 6. Load & filter census flows to neighborhood -> core only ───────────────
od_flows <- read_csv("OD_flows.csv", show_col_types = FALSE) %>%
  mutate(home_name = normalize_name(home_name),
         work_name = normalize_name(work_name))

unmatched_names <- setdiff(c(neighborhood_names, core_name),
                            unique(c(od_flows$home_name, od_flows$work_name)))
if (length(unmatched_names) > 0) {
  cat("\nWARNING: municipality names with no match in OD_flows.csv",
      "(check naming convention / encoding):\n")
  print(unmatched_names)
}

od_flows_n2c <- od_flows %>%
  filter(home_name %in% neighborhood_names, work_name == core_name)

cat("Census pairs, neighborhood -> core only:", nrow(od_flows_n2c), "\n")

# ── 7. Join synthetic vs. census per-municipality flows into the core ────────
comparison <- full_join(
  synthetic_flows,
  od_flows_n2c %>% select(home_name, commuters) %>% rename(home_municipality = home_name),
  by = "home_municipality"
)

cat(sprintf(
  "\nMatched municipalities: %d | synthetic-only: %d | census-only: %d\n",
  sum(!is.na(comparison$synthetic_volume) & !is.na(comparison$commuters)),
  sum(!is.na(comparison$synthetic_volume) &  is.na(comparison$commuters)),
  sum( is.na(comparison$synthetic_volume) & !is.na(comparison$commuters))
))

write.csv(comparison, "od_validation_neighborhood_to_core.csv", row.names = FALSE)

# ── 8. Rank correlation on matched municipalities ─────────────────────────────
matched <- comparison %>% filter(!is.na(synthetic_volume), !is.na(commuters))

od_cor <- cor.test(matched$synthetic_volume, matched$commuters, method = "spearman")
cat("\nSpearman correlation (synthetic volume vs. census commuters, neighborhood -> core):\n")
print(od_cor)

# ── 9. Scatter plot (relationship check) ──────────────────────────────────────
ggplot(matched, aes(x = commuters, y = synthetic_volume)) +
  geom_point(size = 2.5, alpha = 0.7) +
  geom_smooth(method = "lm", se = FALSE, colour = "#c0392b") +
  scale_x_log10() +
  scale_y_log10() +
  labs(
    title = "Neighborhood -> core commuting: synthetic vs. census",
    subtitle = sprintf("Spearman rho = %.2f, n = %d municipalities -> %s",
                        od_cor$estimate, nrow(matched), core_name),
    x = "Census commuters (log scale)",
    y = "Synthetic volume proxy: pop x workplaces (log scale)"
  ) +
  theme_minimal()

ggsave("../Figures/Fig_od_validation_scatter.png", width = 8, height = 6, dpi = 300)
cat("Saved Figures/Fig_od_validation_scatter.png\n")

# ── 10. Ranked share-by-municipality bar chart ────────────────────────────────
# synthetic_volume and commuters are on different scales (an unweighted
# gravity proxy vs. actual people), so only their SHARE of the total
# neighborhood -> core flow is directly comparable across the two sources.
plot_data <- matched %>%
  mutate(
    synthetic_share = synthetic_volume / sum(synthetic_volume),
    census_share    = commuters / sum(commuters)
  ) %>%
  select(home_municipality, synthetic_share, census_share) %>%
  pivot_longer(cols = c(synthetic_share, census_share),
               names_to = "source", values_to = "share") %>%
  mutate(source = recode(source,
                          synthetic_share = "Synthetic (pop x workplaces)",
                          census_share    = "Census"))

ggplot(plot_data, aes(x = reorder(home_municipality, share), y = share, fill = source)) +
  geom_col(position = "dodge") +
  coord_flip() +
  scale_y_continuous(labels = percent) +
  labs(
    title = paste("Neighborhood -> core commuting share:", core_name),
    subtitle = "Share of total neighborhood-to-core flow, by origin municipality",
    x = NULL, y = NULL, fill = NULL
  ) +
  theme_minimal()

ggsave("../Figures/Fig_od_validation_share_by_municipality.png", width = 8, height = 6, dpi = 300)
cat("Saved Figures/Fig_od_validation_share_by_municipality.png\n")
