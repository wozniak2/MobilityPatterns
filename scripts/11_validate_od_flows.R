# =============================================================================
# 11_validate_od_flows.R
#
# Validates synthetic (r5r-routed) commuting connections against empirical
# census origin-destination commuting flows (LAU-to-LAU), restricted to
# neighborhood -> core commuting: flows from the municipalities surrounding
# Poznań into the Poznań core itself (the classic suburb-to-centre commute
# this study is actually about, not core-internal or core-to-core flows).
#
# Synthetic itineraries carry no modelled trip volume -- r5r only tells you
# whether a grid-cell pair is routable, not how many people use it -- so we
# proxy volume with a population x workplace gravity weight, deflated by a
# distance-decay term (travel_time_min^beta) per surviving grid-cell OD pair,
# aggregated to the municipality level, and compare that against census
# commuter counts via rank correlation (Spearman): since the proxy is not on
# the same scale as a literal commuter count, only a monotonic relationship
# (and relative share across municipalities) is defensible to claim -- not
# absolute magnitude. Several decay exponents are tested (step 8) rather than
# assumed, and whichever fits best (highest Spearman rho) is used for the
# headline plots; beta = 0 recovers the plain undecayed pop x workplaces
# proxy as a baseline.
#
# Ring-to-ring and core-to-ring flows are NOT validated even though
# OD_flows.csv has them, because workplace_grid.gpkg (01_calculate_workplaces.R)
# is clipped to the Poznan city boundary only -- there is essentially no
# modelled workplace mass anywhere in the ring, so a pop x workplaces proxy
# for a ring destination would be meaningless. Neighborhood -> core is the
# only comparison the synthetic data actually supports.
#
# CORE / NEIGHBORHOOD: verified directly against the two boundary files
# (see below), not assumed from their filenames. ap.gpkg contains the ring
# of municipalities surrounding Poznan and NO Poznan polygon at all; poz.gpkg
# contains exactly the Poznan core city and none of the ring -- the opposite
# of what their names and earlier comments in this codebase ("agglomeration"
# for ap, "donut" for poz) suggested. This was confirmed by grepping both
# files directly: known ring municipality names (Swarzedz, Kornik, Mosina,
# Lubon, etc.) each appear in ap.gpkg and never in poz.gpkg; "Poznan" appears
# in poz.gpkg and never in ap.gpkg.
#
# This also explains a previous bug in this script: an earlier version
# classified BOTH origins and destinations against `ap` alone. Since `ap` has
# no Poznan polygon, every destination point (all genuinely inside the core)
# was nearest-feature-matched to whichever RING municipality happened to be
# geographically closest -- which is why "core" was once (wrongly) detected
# as Lubon. The fix is to classify against the union of ap (ring) and poz
# (core) together, and to take the core's name directly from poz.gpkg rather
# than inferring it.
#
# INPUT  : pt_itineraries.rds, car_itineraries.rds (from 05_read_itineraries.R)
#          pop_grid.gpkg, workplace_grid.gpkg (from steps 1-2)
#          ap.gpkg (ring municipalities), poz.gpkg (Poznan core city)
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

# ap.gpkg/poz.gpkg's JPT_NAZWA_ carries the full official form with an
# administrative-type suffix (e.g. "Luboń - gmina miejska", "Poznań - gmina
# miejska"), while OD_flows.csv's home_name/work_name use the plain
# municipality name ("Luboń", "Poznań") -- confirmed directly against the
# CSV. Without stripping this suffix, every neighborhood/core name fails to
# match OD_flows and the neighborhood -> core filter silently returns 0 rows.
strip_admin_suffix <- function(x) str_remove(x, "\\s*-\\s*gmina (miejska|wiejska)$")

# ── 1. Load synthetic itineraries and base grids ─────────────────────────────
pt_itineraries  <- readRDS("pt_itineraries.rds")
car_itineraries <- readRDS("car_itineraries.rds")

pop_grid  <- st_read("pop_grid.gpkg", quiet = TRUE)       %>% st_transform(2180)
work_grid <- st_read("workplace_grid.gpkg", quiet = TRUE) %>% st_transform(2180)

# Municipality boundaries: ap = ring surrounding Poznan, poz = Poznan core
# city alone (see header note -- verified directly, not assumed). Both are
# needed to classify origin/destination points correctly: using ap alone
# would leave destination points inside the core with no matching polygon.
ap <- st_read("ap.gpkg", quiet = TRUE) %>%
  select(JPT_NAZWA_) %>%
  st_transform(2180) %>%
  mutate(JPT_NAZWA_ = normalize_name(JPT_NAZWA_) %>% strip_admin_suffix())

poz <- st_read("poz.gpkg", quiet = TRUE) %>%
  select(JPT_NAZWA_) %>%
  st_transform(2180) %>%
  mutate(JPT_NAZWA_ = normalize_name(JPT_NAZWA_) %>% strip_admin_suffix())

if (nrow(poz) != 1) {
  stop(
    "Expected poz.gpkg to contain exactly one municipality (the Poznan ",
    "core), found ", nrow(poz), ": ", paste(poz$JPT_NAZWA_, collapse = " | ")
  )
}

municipalities <- bind_rows(ap, poz)

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

# ── 2b. Travel-time impedance for each grid-cell OD pair ─────────────────────
# Car routing succeeds almost everywhere (the same reason the car/PT union is
# used above as the proxy for "all attempted pairs"), so car duration is the
# primary impedance measure; the rare car-unreachable pair (routed only by
# PT) falls back to its PT duration. Used below to add distance decay to the
# gravity proxy -- without it, a pop x workplaces product treats a pair 5
# minutes apart the same as one 80 minutes apart, which is not how commuting
# mass actually distributes.
car_duration <- car_itineraries %>% st_drop_geometry() %>%
  group_by(from_id, to_id) %>%
  summarise(car_duration_min = min(total_duration), .groups = "drop")

pt_duration <- pt_itineraries %>% st_drop_geometry() %>%
  group_by(from_id, to_id) %>%
  summarise(pt_duration_min = min(total_duration), .groups = "drop")

od_pairs <- od_pairs %>%
  left_join(car_duration, by = c("from_id", "to_id")) %>%
  left_join(pt_duration,  by = c("from_id", "to_id")) %>%
  mutate(travel_time_min = coalesce(car_duration_min, pt_duration_min))

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
    home_municipality = municipalities$JPT_NAZWA_[st_nearest_feature(origin_sf, municipalities)],
    work_municipality = municipalities$JPT_NAZWA_[st_nearest_feature(dest_sf, municipalities)]
  )

# ── 4. Restrict to neighborhood -> core flows ─────────────────────────────────
# Core = the single municipality in poz.gpkg (verified above to be exactly
# one row -- Poznan). Neighborhood = every municipality in ap.gpkg (the ring;
# ap.gpkg contains no Poznan polygon, so no exclusion is needed).
core_name <- poz$JPT_NAZWA_
neighborhood_names <- unique(ap$JPT_NAZWA_)

cat("Core municipality:", core_name, "\n")
cat("Neighborhood municipalities (ring):", length(neighborhood_names), "\n")

# Diagnostic: with both ap and poz now in the classification layer, the
# plurality of destination points should land in the core. If it doesn't,
# workplace_grid.gpkg may not be cleanly clipped to the Poznan city boundary
# in 01_calculate_workplaces.R and is worth re-checking.
most_destinations <- names(sort(table(od_pairs$work_municipality), decreasing = TRUE))[1]
if (most_destinations != core_name) {
  cat("\nWARNING: the municipality with the most destination points is '",
      most_destinations, "', not the core ('", core_name, "'), even with ",
      "both ap.gpkg and poz.gpkg in the classification layer. ",
      "workplace_grid.gpkg is likely not cleanly clipped to the Poznan city ",
      "boundary -- check the st_intersection(workplace_grid, boundary) step ",
      "in 01_calculate_workplaces.R and the contents of boundary.gpkg.\n", sep = "")
}

od_pairs <- od_pairs %>%
  filter(home_municipality %in% neighborhood_names,
         work_municipality == core_name)

cat("Grid-cell OD pairs, neighborhood -> core only:", nrow(od_pairs), "\n")

# ── 5. Aggregate to per-municipality synthetic "volume" into the core ────────
# Gravity-style proxy: population(origin) x workplaces(destination) / travel
# time^beta, summed over every surviving grid-cell pair between each
# neighborhood municipality and the core. beta = 0 recovers the original
# undecayed pop x workplaces proxy; beta > 0 progressively down-weights
# distant connections. Rather than assuming a decay exponent, several values
# are computed here and compared against census commuters below (step 8) to
# pick whichever actually fits best.
gravity_betas <- c(0, 0.5, 1, 1.5, 2)

synthetic_flows <- od_pairs %>%
  group_by(home_municipality) %>%
  summarise(synthetic_connections = n(), .groups = "drop")

for (beta in gravity_betas) {
  col_name <- paste0("synthetic_volume_beta_", beta)
  vol <- od_pairs %>%
    group_by(home_municipality) %>%
    summarise(
      volume = sum(working_age_pop * workplaces / travel_time_min^beta, na.rm = TRUE),
      .groups = "drop"
    )
  names(vol)[names(vol) == "volume"] <- col_name
  synthetic_flows <- left_join(synthetic_flows, vol, by = "home_municipality")
}

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
  sum(!is.na(comparison$synthetic_volume_beta_0) & !is.na(comparison$commuters)),
  sum(!is.na(comparison$synthetic_volume_beta_0) &  is.na(comparison$commuters)),
  sum( is.na(comparison$synthetic_volume_beta_0) & !is.na(comparison$commuters))
))

# ── 8. Distance-decay sensitivity: which beta best matches census commuters ──
# Spearman rank correlation and a log-log OLS fit (R^2) are computed for each
# decay exponent tested in step 5, rather than assuming one a priori. Beta is
# selected by log-log R^2, not Spearman rho: rho is coarse (rank-only, so it
# ties across nearby beta values -- 0.5 and 1 tied at rho = 0.903 here) and
# R^2 is the more appropriate continuous goodness-of-fit measure for choosing
# a continuous parameter, since it's already the metric implied by fitting
# the proxy in log-log form. Whichever beta maximises R^2 becomes the
# headline "synthetic_volume" proxy used for the plots below.
beta_results <- map_dfr(gravity_betas, function(beta) {
  col <- paste0("synthetic_volume_beta_", beta)
  m <- comparison %>%
    filter(!is.na(.data[[col]]), !is.na(commuters)) %>%
    mutate(volume = .data[[col]])
  cor_test <- cor.test(m$volume, m$commuters, method = "spearman")
  ols <- lm(log(commuters) ~ log(volume), data = m)
  tibble(
    beta = beta,
    n = nrow(m),
    spearman_rho = unname(cor_test$estimate),
    p_value = cor_test$p.value,
    loglog_r2 = summary(ols)$r.squared
  )
})

cat("\nGravity proxy performance across distance-decay exponents (beta = 0 is undecayed):\n")
print(beta_results)
write.csv(beta_results, "od_validation_beta_sensitivity.csv", row.names = FALSE)

best_beta <- beta_results$beta[which.max(beta_results$loglog_r2)]
cat(sprintf(
  "\nBest-performing decay exponent: beta = %s (log-log R^2 = %.3f, Spearman rho = %.3f)\n",
  best_beta, max(beta_results$loglog_r2),
  beta_results$spearman_rho[beta_results$beta == best_beta]
))

comparison <- comparison %>%
  mutate(synthetic_volume = .data[[paste0("synthetic_volume_beta_", best_beta)]])

write.csv(comparison, "od_validation_neighborhood_to_core.csv", row.names = FALSE)

# ── 8b. Headline rank correlation, using the best-fitting decay exponent ────
matched <- comparison %>% filter(!is.na(synthetic_volume), !is.na(commuters))

od_cor <- cor.test(matched$synthetic_volume, matched$commuters, method = "spearman")
cat(sprintf(
  "\nSpearman correlation (synthetic volume, beta = %s, vs. census commuters, neighborhood -> core):\n",
  best_beta
))
print(od_cor)

# ── 9. Scatter plot (relationship check) ──────────────────────────────────────
# Dark theme (background #1a1a1a, white text/gridlines) added 2026-08-26 to
# match the rest of the manuscript's dark-themed figures. Trend-line colour
# (#FDE725) is the same "higher-value" viridis stop used as the shared
# accent in Figures 3/7 (07_plot_itineraries.R, 06_travel_ratio_analysis.R)
# for cross-figure coherence; points recoloured to the shared purple.
#
# Enhanced further, same session: a shaded 95% CI band (se = TRUE, was
# FALSE) and an in-plot rho/R^2 annotation, recomputed here directly from
# `matched` rather than hardcoded so it can't drift from the real numbers.
# GOTCHA: annotate(x = -Inf, y = Inf, ...) -- the usual "top-left corner"
# trick -- does NOT work on log-scaled axes: scale_x_log10()'s transform
# computes log10(-Inf), which is NaN in R (unlike a linear scale, where
# Inf/-Inf pass through untransformed), so the label silently vanishes
# (geom_text warns "Removed 1 row containing missing values" -- easy to
# miss). Fixed by computing a real position from the data's own log-range.
rho_val <- cor.test(matched$synthetic_volume, matched$commuters, method = "spearman")$estimate
r2_val  <- summary(lm(log(commuters) ~ log(synthetic_volume), data = matched))$r.squared

xr <- range(log10(matched$commuters))
yr <- range(log10(matched$synthetic_volume))
label_x <- 10^(xr[1] + 0.02 * diff(xr))
label_y <- 10^(yr[1] + 0.97 * diff(yr))

ggplot(matched, aes(x = commuters, y = synthetic_volume)) +
  geom_smooth(method = "lm", se = TRUE, colour = "#FDE725", fill = "white",
              alpha = 0.15, linewidth = 1) +
  geom_point(shape = 21, size = 3.2, colour = "white", fill = "#9B59B6",
             stroke = 0.4, alpha = 0.9) +
  annotate("text", x = label_x, y = label_y,
           label = sprintf("atop(rho[s] == %.3f, R^2 == %.3f)", rho_val, r2_val),
           parse = TRUE, colour = "white", size = 5.2, hjust = 0, vjust = 1) +
  scale_x_log10() +
  scale_y_log10() +
  labs(
    x = "Census commuters (log scale)",
    y = "Synthetic volume proxy (log scale)"
  ) +
  theme_dark(base_size = 17) +
  theme(
    panel.background  = element_rect(fill = "#1a1a1a"),
    plot.background   = element_rect(fill = "#1a1a1a", colour = NA),
    text              = element_text(color = "white"),
    axis.title        = element_text(size = 19, color = "white"),
    axis.text         = element_text(size = 18, color = "white"),
    panel.grid.major  = element_line(colour = "grey30"),
    panel.grid.minor  = element_blank(),
    plot.margin       = margin(t = 10, r = 15, b = 10, l = 10)
  )

ggsave("../Figures/Fig_od_validation_scatter.png", width = 8, height = 6, dpi = 300)
cat("Saved Figures/Fig_od_validation_scatter.png\n")

# ── 10. Ranked share-by-municipality bar chart ────────────────────────────────
# synthetic_volume and commuters are on different scales (a distance-decayed
# gravity proxy vs. actual people), so only their SHARE of the total
# neighborhood -> core flow is directly comparable across the two sources.
synthetic_label <- "Synthetic proxy"

plot_data <- matched %>%
  mutate(
    synthetic_share = synthetic_volume / sum(synthetic_volume),
    census_share    = commuters / sum(commuters)
  ) %>%
  select(home_municipality, synthetic_share, census_share) %>%
  pivot_longer(cols = c(synthetic_share, census_share),
               names_to = "source", values_to = "share") %>%
  mutate(source = dplyr::recode(source,
                          synthetic_share = synthetic_label,
                          census_share    = "Census"))

# Dark theme + shared viridis palette, same rationale as the scatter plot
# above: Census (the reference/ground truth, matching Car's and rail's role
# in Figures 3/7) gets the purple stop; Synthetic proxy (the model construct
# under evaluation, matching PT's and no-rail's role) gets yellow.
ggplot(plot_data, aes(x = reorder(home_municipality, share), y = share, fill = source)) +
  geom_col(position = "dodge") +
  coord_flip() +
  scale_y_continuous(labels = percent) +
  scale_fill_manual(values = c(Census = "#9B59B6", "Synthetic proxy" = "#FDE725")) +
  labs(
    x = NULL, y = NULL, fill = NULL
  ) +
  theme_dark(base_size = 16) +
  theme(
    panel.background  = element_rect(fill = "#1a1a1a"),
    plot.background   = element_rect(fill = "#1a1a1a", colour = NA),
    legend.background = element_rect(fill = "#1a1a1a"),
    legend.key        = element_rect(fill = "#1a1a1a"),
    text              = element_text(color = "white"),
    axis.text         = element_text(size = 15, color = "white"),
    legend.text       = element_text(size = 16, color = "white"),
    legend.position   = "top",
    panel.grid.major  = element_line(colour = "grey30"),
    panel.grid.minor  = element_blank()
  )

ggsave("../Figures/Fig_od_validation_share_by_municipality.png", width = 8, height = 8.5, dpi = 300)
cat("Saved Figures/Fig_od_validation_share_by_municipality.png\n")
