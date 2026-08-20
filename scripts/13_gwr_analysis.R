# =============================================================================
# 13_gwr_analysis.R
#
# Geographically weighted regression (GWR) on the same origin-level PT/car
# travel-time ratio model as 12_spatial_regression_comparison.R -- a
# complement to that script's global-coefficient OLS/SEM/SDM comparison,
# testing whether any predictor's association with the ratio is spatially
# uniform or varies in strength across the metropolitan area. Unlike SAR/
# SEM/SDM (which model spatial DEPENDENCE -- how nearby observations/errors
# correlate, under one global coefficient), GWR models spatial NON-
# STATIONARITY -- whether the coefficient itself differs by location. See
# the manuscript's Section 3.5/4.3 for the reported result (departure
# frequency only) and https://... [GWR investigation memory, not public] for
# the full methodological trail behind the choices below.
#
# WHY ONLY departure frequency GETS A MAP: of the four predictors with a
# significant TOTAL effect in the SDM (12_spatial_regression_comparison.R's
# sdm_impacts.csv), daily_departures is the only one a planner can directly
# act on -- origin/dest_dist_centre_km are fixed geography, dist_to_stop_m
# is only actionable via siting a new stop (already handled categorically
# by the investment-priority typology in 08_analyse_itineraries.R). This
# script computes local coefficients for ALL nine predictors (saved to
# gwr_local_coefficients.csv, in case a future analysis wants them) but only
# maps the one that's both significant, actionable, AND passed the
# robustness check below.
#
# WHY BISQUARE / bw=501, NOT MULTISCALE GWR: multiscale GWR (separate
# bandwidth per predictor) was tried extensively and abandoned. AICc/CV
# bandwidth selection has a structural bias toward tiny, overfit
# bandwidths, and it's far worse for MGWR's per-variable initialization
# (fitting one predictor alone, trivially easy to overfit) than for this
# classic GWR's jointly-fit 9-predictor model, which stays honest because
# a bandwidth too small to estimate 10 parameters simply fails outright
# rather than quietly overfitting. bisquare's compact support crashing at
# tiny bandwidths turned out to be doing useful work (fencing the search
# away from the degenerate region) that smooth kernels (gaussian,
# exponential) don't provide -- they slid to n=15-18 neighbours with
# R^2>0.93, pure noise. AIC and CV independently agreed on bw=501 for the
# classic (jointly-fit) model; neither agreement nor stability was ever
# achieved for MGWR's per-variable bandwidths without an artificial floor
# that just relocated the same problem.
#
# ROBUSTNESS CHECK (not reproduced by this script -- see the note below):
# each predictor's local coefficients from THIS script were cross-checked
# against an independent local estimator (multiscale GWR back-fitting held
# at this same fixed bw=501 for every term, via GWmodel::gwr.multiscale()
# with bw.seled=TRUE, force.armadillo=TRUE -- the only code path that
# actually honours bw.seled; the default execution path silently ignores
# it, a real GWmodel 2.4.1 quirk found via source inspection). Eight of
# nine predictors agreed closely (correlation 0.85-0.96); nearest_stop_is_
# rail did not (correlation 0.09) and should not be mapped or interpreted
# locally -- consistent with its already-borderline status in the global
# SDM. That comparison run took 532.66 minutes (~8.9 hours) because
# force.armadillo=TRUE routes through a much slower plain-R back-fitting
# loop. It is NOT re-run by this script and is not part of the numbered
# pipeline -- see gwr_robustness_check.R (no number prefix, deliberately
# excluded from 00_run_pipeline.R) if it ever needs reproducing.
#
# INPUT  : regression_data.csv (from 10_regression_analysis.R), poz.gpkg
# OUTPUT : gwr_local_coefficients.csv -- all 9 predictors' local coefficients,
#          one row per origin zone
#          Figures/Fig_GWR_departures_local_coef.png
# =============================================================================

suppressMessages({
  library(dplyr)
  library(sf)
  library(GWmodel)
  library(ggplot2)
})

setwd("C:/Users/wozni/Google Drive/UAM/HUB/MobilityPatterns/Data")
set.seed(42)

model_formula <- tt_ratio ~ n_transfers + walk_share + daily_departures +
  dist_to_stop_m + origin_dist_centre_km + dest_dist_centre_km +
  origin_working_age_pop + nearest_stop_is_rail + car_directness

regression_data <- read.csv("regression_data.csv")
cat("regression_data.csv rows:", nrow(regression_data), "\n")

# Same workplace-weighted-mean aggregation as 12_spatial_regression_comparison.R
# (kept identical deliberately, not sourced as a shared helper -- see that
# script's own header for the full rationale on why destination-varying vs.
# origin-constant predictors are weighted differently).
wmean <- function(x, w) {
  if (!is.finite(sum(w, na.rm = TRUE)) || sum(w, na.rm = TRUE) == 0) {
    return(mean(x, na.rm = TRUE))
  }
  stats::weighted.mean(x, w, na.rm = TRUE)
}

origin_data <- regression_data %>%
  dplyr::group_by(from_id, from_lon, from_lat) %>%
  dplyr::summarise(
    tt_ratio                = wmean(tt_ratio, dest_workplaces),
    n_transfers              = wmean(n_transfers, dest_workplaces),
    walk_share                = wmean(walk_share, dest_workplaces),
    daily_departures          = mean(daily_departures, na.rm = TRUE),
    dist_to_stop_m            = mean(dist_to_stop_m, na.rm = TRUE),
    origin_dist_centre_km     = mean(origin_dist_centre_km, na.rm = TRUE),
    dest_dist_centre_km       = wmean(dest_dist_centre_km, dest_workplaces),
    origin_working_age_pop    = mean(origin_working_age_pop, na.rm = TRUE),
    nearest_stop_is_rail      = mean(nearest_stop_is_rail, na.rm = TRUE),
    car_directness             = wmean(car_directness, dest_workplaces),
    .groups = "drop"
  ) %>%
  dplyr::filter(dplyr::if_all(dplyr::everything(), is.finite))

cat("Origin zones for GWR:", nrow(origin_data), "\n")

origin_sf <- origin_data %>%
  st_as_sf(coords = c("from_lon", "from_lat"), crs = 4326, remove = FALSE)
origin_sp <- as(origin_sf, "Spatial")

# ── Bandwidth: re-derive via AIC search rather than hardcoding 501, so this
# script stays correct if regression_data.csv is ever regenerated with a
# materially different sample. Confirmed (2026-08-19/20) that AIC and CV
# converge on the identical bandwidth for this jointly-fit model -- only
# AIC is run here to keep this step fast (a few seconds).
cat("\nSelecting GWR bandwidth (adaptive bisquare, AIC)...\n")
bw <- bw.gwr(model_formula, data = origin_sp, approach = "AIC",
             kernel = "bisquare", adaptive = TRUE)
cat("Selected bandwidth:", bw, "nearest neighbours (",
    round(100 * bw / nrow(origin_data), 1), "% of sample)\n")

gwr_fit <- gwr.basic(model_formula, data = origin_sp, bw = bw,
                       kernel = "bisquare", adaptive = TRUE)
cat("\nLocal model R^2:", round(gwr_fit$GW.diagnostic$gw.R2, 4),
    " vs. global OLS R^2:",
    round(summary(lm(model_formula, data = origin_data))$r.squared, 4), "\n")

coef_names <- c("Intercept", all.vars(model_formula)[-1])
sdf <- gwr_fit$SDF

local_coefs <- origin_data %>%
  dplyr::select(from_id, from_lon, from_lat) %>%
  dplyr::bind_cols(as.data.frame(sdf)[coef_names])

write.csv(local_coefs, "gwr_local_coefficients.csv", row.names = FALSE)
cat("\nSaved gwr_local_coefficients.csv (", nrow(local_coefs),
    "rows x", length(coef_names), "predictors)\n")

cat("\n=== Local coefficient summary, all predictors (min / median / max) ===\n")
summ <- t(sapply(coef_names, function(v) {
  x <- sdf[[v]]
  c(min = min(x), median = median(x), max = max(x), pct_negative = mean(x < 0) * 100)
}))
print(round(summ, 4))
cat("\nNote: nearest_stop_is_rail's local coefficients are computed and saved\n")
cat("above like every other predictor, but should NOT be mapped or\n")
cat("interpreted spatially -- the robustness check (see header comment)\n")
cat("found correlation 0.09 against an independent local estimator at this\n")
cat("same bandwidth, an order of magnitude below every other predictor.\n")

# ── Map: departure frequency's local coefficient only (see header comment
# for why this is the one predictor that earns a figure). Dark theme
# matching the manuscript's other map figures (08_analyse_itineraries.R).
poz <- st_read("poz.gpkg", quiet = TRUE)
poz_wgs <- st_transform(poz, 4326)
origin_sf$gwr_dep_coef <- sdf[["daily_departures"]]

p <- ggplot() +
  geom_sf(data = origin_sf, aes(colour = gwr_dep_coef), size = 1.1, alpha = 0.85) +
  geom_sf(data = poz_wgs, fill = NA, colour = "white", linewidth = 0.4, inherit.aes = FALSE) +
  scale_colour_viridis_c(name = "Local GWR\ncoefficient") +
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
    axis.line         = element_blank(),
    axis.ticks        = element_blank(),
    legend.title      = element_text(size = 18, color = "white"),
    legend.text       = element_text(size = 15, color = "white"),
    panel.grid.major  = element_blank(),
    panel.grid.minor  = element_blank(),
    panel.border      = element_blank(),
    plot.margin       = margin(0, 0, 0, 0)
  )

dir.create("../Figures", showWarnings = FALSE)
ggsave("../Figures/Fig_GWR_departures_local_coef.png", plot = p,
       width = 9, height = 7.2, dpi = 300, bg = "#1a1a1a")
cat("\nSaved Figures/Fig_GWR_departures_local_coef.png\n")
