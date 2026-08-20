# =============================================================================
# gwr_robustness_check.R
#
# NOT part of the numbered pipeline and NOT run by 00_run_pipeline.R --
# deliberately excluded, same as lisa_priority_utils.R/od_pair_utils.R are
# excluded for being shared helpers rather than pipeline steps, but for a
# different reason here: this script's main run took 532.66 minutes
# (~8.9 hours) on 2026-08-19/20 hardware. Run it manually, and only if the
# robustness-check numbers reported in 13_gwr_analysis.R's header comment
# and the manuscript (Section 4.3) ever need reproducing from scratch --
# e.g. after regression_data.csv changes materially, or to sanity-check a
# GWmodel package upgrade.
#
# WHAT THIS CHECKS: 13_gwr_analysis.R fits classic GWR (one joint local
# regression per origin zone, all 9 predictors together). This script fits
# the SAME model with the SAME fixed bandwidth via a structurally different
# estimator -- multiscale GWR's iterative back-fitting (each predictor's
# local coefficient estimated from partial residuals, one at a time, then
# iterated to convergence) -- and checks whether the two methods agree.
# Where they don't, a predictor's local coefficients are noise-sensitive to
# the estimation method, not a trustworthy spatial finding, however
# reasonable either method's numbers look in isolation.
#
# A REAL GWmodel 2.4.1 BUG, FOUND VIA SOURCE INSPECTION (getFromNamespace
# ("gwr.multiscale","GWmodel")): the default execution path (parallel.
# method=FALSE, force.armadillo=FALSE) routes to a compiled C++ backend,
# new_multiscale(), whose argument list does not include bw.seled at all --
# it's accepted by the R wrapper, validated, documented, then silently
# dropped before reaching code that would use it. Only force.armadillo=
# TRUE routes through the plain-R back-fitting loop that actually checks
# bw.seled and can hold a bandwidth fixed rather than re-searching it every
# iteration. THIS IS WHY force.armadillo=TRUE IS REQUIRED BELOW, and also
# why this script is ~50-100x slower than a normal gwr.multiscale() call --
# the plain-R loop is dramatically slower than the compiled default path.
# If GWmodel is ever upgraded, re-check whether this is still true before
# assuming the runtime estimate above still holds.
#
# WHY NOT MGWR'S OWN (SEARCHED) BANDWIDTHS: earlier attempts letting
# gwr.multiscale() search each predictor's bandwidth independently all
# failed -- AICc/CV bandwidth selection has a structural bias toward tiny,
# overfit bandwidths, far worse for a single-predictor sub-model (1-2
# parameters, trivially overfit) than for classic GWR's jointly-fit
# 9-predictor model. Holding every predictor at the SAME bandwidth classic
# GWR already validated (via bw.gwr(), see 13_gwr_analysis.R) isolates the
# back-fitting-vs-joint-estimation question cleanly, without reopening the
# bandwidth-selection instability.
#
# INPUT  : regression_data.csv, poz.gpkg
# OUTPUT : gwr_robustness_check.csv -- correlation + mean abs diff per
#          predictor, classic GWR vs. MGWR back-fitting at the identical bw
# =============================================================================

suppressMessages({
  library(dplyr)
  library(sf)
  library(GWmodel)
})

setwd("C:/Users/wozni/Google Drive/UAM/HUB/MobilityPatterns/Data")
set.seed(42)

model_formula <- tt_ratio ~ n_transfers + walk_share + daily_departures +
  dist_to_stop_m + origin_dist_centre_km + dest_dist_centre_km +
  origin_working_age_pop + nearest_stop_is_rail + car_directness

regression_data <- read.csv("regression_data.csv")

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

origin_sf <- origin_data %>% st_as_sf(coords = c("from_lon", "from_lat"), crs = 4326)
origin_sp <- as(origin_sf, "Spatial")

coef_names <- c("Intercept", all.vars(model_formula)[-1])

cat("Fitting classic (jointly-estimated) GWR for comparison...\n")
bw <- bw.gwr(model_formula, data = origin_sp, approach = "AIC",
             kernel = "bisquare", adaptive = TRUE)
classic_fit <- gwr.basic(model_formula, data = origin_sp, bw = bw,
                           kernel = "bisquare", adaptive = TRUE)
classic_sdf <- classic_fit$SDF
cat("Classic GWR bandwidth:", bw, "\n")

cat("\nFitting multiscale GWR back-fitting, EVERY predictor held fixed at\n")
cat("bw =", bw, "(force.armadillo=TRUE, bw.seled=TRUE -- see header comment).\n")
cat("This will take a long time (~9 hours on 2026-08-19/20 hardware).\n")
t0 <- Sys.time()
mgwr_fit <- gwr.multiscale(
  model_formula, data = origin_sp,
  kernel = "bisquare", adaptive = TRUE,
  criterion = "dCVR", approach = "CV",
  max.iterations = 300, threshold = 1e-5,
  nlower = bw,
  bws0 = rep(bw, length(coef_names)),
  bw.seled = rep(TRUE, length(coef_names)),
  force.armadillo = TRUE,
  verbose = TRUE
)
cat("\nMGWR back-fitting took:",
    round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 2), "minutes\n")

mgwr_sdf <- mgwr_fit$SDF

comparison <- do.call(rbind, lapply(coef_names, function(v) {
  data.frame(
    predictor      = v,
    correlation    = cor(classic_sdf[[v]], mgwr_sdf[[v]]),
    mean_abs_diff  = mean(abs(classic_sdf[[v]] - mgwr_sdf[[v]]))
  )
}))

cat("\n=== Robustness check: classic GWR vs. MGWR back-fitting, same bandwidth ===\n")
print(comparison, digits = 4)

write.csv(comparison, "gwr_robustness_check.csv", row.names = FALSE)
cat("\nSaved gwr_robustness_check.csv\n")
cat("Reference values from 2026-08-19/20: daily_departures 0.955, ")
cat("dest_dist_centre_km 0.939, Intercept 0.938, walk_share 0.937, ")
cat("car_directness 0.920, n_transfers 0.913, origin_dist_centre_km 0.885, ")
cat("origin_working_age_pop 0.880, dist_to_stop_m 0.851, ")
cat("nearest_stop_is_rail 0.090 (the one predictor excluded from local ")
cat("reporting in the manuscript and in 13_gwr_analysis.R).\n")
