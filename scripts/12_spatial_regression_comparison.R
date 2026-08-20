# =============================================================================
# 12_spatial_regression_comparison.R
#
# Formally tests which spatial specification best fits the origin-zone
# PT/car travel-time ratio, motivated by the significant global Moran's I
# found on the route density gap surface in 08_analyse_itineraries.R (I = 0.182,
# z = 595.09, p < 2.2e-16): OLS residuals are not spatially independent, so
# plain lm() understates uncertainty and cannot capture spatial dependence.
#
# Workflow (standard spatial econometrics practice, LeSage & Pace-style):
#   1. Fit OLS, run Lagrange Multiplier tests (lm.LMtests: LMerr/LMlag and
#      their robust versions) to diagnose whether the data supports a
#      spatial LAG process, a spatial ERROR process, or both, before
#      committing to a specification.
#   2. Fit the two nested spatial regressions this points to: SEM (error
#      only) and SDM (Durbin -- lag + spatially lagged predictors, nests
#      SEM under the "common factor" restriction).
#   3. Likelihood-ratio test SDM against SEM to confirm the extra Durbin
#      complexity is actually justified rather than assumed.
#   4. Compare all three (OLS, SEM, SDM) on AIC, pseudo-R^2, and residual
#      Moran's I, and report the SDM effect decomposition.
#
# NOTE (2026-08-20): SAR (spatial lag only) was removed from this script --
# it was already excluded from the manuscript's results table back on
# 2026-07-28 (dominated by SEM: AIC 362.55 vs. 26.27, residual Moran's I
# 0.161 vs. 0.050) but was still being formally fitted and LR-tested here,
# which had drifted out of sync with the manuscript's Methods text (which
# now explicitly says "two nested spatial specifications were estimated").
# The LM tests for a lag process (step 1 above) are unaffected -- they're
# a diagnostic on OLS residuals, not dependent on SAR itself being fit.
#
# NOTE (2026-07-28, GWR removed; 2026-08-20, GWR is back, differently): a
# GWR fit and its two figures were removed from this script on 2026-07-28
# because GWR wasn't part of what the study reported at the time. GWR is
# back as of 2026-08-20, but as its own separate script,
# `13_gwr_analysis.R` -- not revived here. It answers a different question
# (does a predictor's effect vary spatially) than this script's OLS/SEM/SDM
# comparison (does spatial dependence exist, and how is it structured), so
# it was kept separate rather than folded back into this one.
#
# DESIGN CHOICE: regression_data.csv is one row per OD pair, but these
# models need one observation per spatial location. Rows are aggregated to
# one per ORIGIN grid cell; predictors that are already origin-constant
# (dist_to_stop_m, daily_departures, origin_dist_centre_km,
# nearest_stop_is_rail, origin_working_age_pop) average to their exact
# original value regardless of weighting, so a plain mean() is used for
# those. Predictors that vary by destination (tt_ratio itself,
# dest_dist_centre_km, car_directness, walk_share,
# n_transfers) are instead aggregated as a workplace-weighted mean
# (weighted.mean(..., w = dest_workplaces)): an origin reachable to one
# destination with 5,000 jobs and one with 5 jobs should have its outcome
# dominated by the former, not averaged with it unweighted -- a plain
# mean() implicitly treats every reachable destination cell as equally
# important regardless of how many people actually commute there.
# dest_workplaces itself is not a model predictor (destinations are already
# selected on a >=150-workplace cutoff in 04_r5r_route_batch.R, so its
# variation mostly reflects that cutoff), it is used only as the weight.
#
# pt_duration_min and car_speed_kmh are deliberately excluded from the
# formula: tt_ratio = pt_duration_min / car_duration_min, so pt_duration_min
# is the outcome's own numerator (near-circular as a predictor), and
# car_speed_kmh is derived from car_duration_min, the outcome's denominator.
# car_directness (car_distance_m / straightline_m) is used instead as a
# distance-only proxy for car route quality, with no duration term shared
# with the outcome.
#
# INPUT  : regression_data.csv (from 10_regression_analysis.R, must include
#          from_lon/from_lat)
# OUTPUT : spatial_regression_comparison.csv -- AIC/pseudo-R2/Moran's I, all 3 models
#          spatial_dependence_tests.csv      -- LM tests (OLS) + LR test (SDM vs SEM)
#          sdm_impacts.csv                   -- SDM direct/indirect/total effects + p-values
#          regression_vif.csv                -- VIF on the reported origin-level OLS model
# =============================================================================

library(dplyr)
library(sf)
library(spdep)
library(spatialreg)

setwd("C:/Users/wozni/Google Drive/UAM/HUB/MobilityPatterns/Data")
dir.create("../Figures", showWarnings = FALSE)
set.seed(42)

# dest_working_age_pop removed 2026-07-28 (manuscript revision): it was
# previously in this formula and was, in the SDM effect decomposition, one
# of only two predictors whose total effect survived decomposition. Removed
# per explicit instruction, not a data-driven decision (e.g. not for
# collinearity -- its VIF was 2.82, well under the concern threshold).
model_formula <- tt_ratio ~ n_transfers + walk_share + daily_departures +
  dist_to_stop_m + origin_dist_centre_km + dest_dist_centre_km +
  origin_working_age_pop + nearest_stop_is_rail +
  car_directness

# ── 1. Load regression data & aggregate to one row per origin zone ───────────
regression_data <- read.csv("regression_data.csv")
cat("regression_data.csv rows:", nrow(regression_data), "\n")

required_cols <- c("from_id", "from_lon", "from_lat", "dest_workplaces", all.vars(model_formula))
missing_cols  <- setdiff(required_cols, names(regression_data))
if (length(missing_cols) > 0) {
  stop(
    "regression_data.csv is missing column(s): ", paste(missing_cols, collapse = ", "),
    ". This usually means it was written by an older version of ",
    "10_regression_analysis.R -- re-run that script to regenerate regression_data.csv, ",
    "then re-run this script."
  )
}
if (nrow(regression_data) == 0) {
  stop(
    "regression_data.csv has 0 rows. 10_regression_analysis.R's own filter() ",
    "already dropped everything before this script ever ran -- check that ",
    "script's console output (row counts printed after each join/filter step) ",
    "to see where rows were lost."
  )
}

# Diagnostic: non-finite counts per formula variable, BEFORE aggregation --
# every one of these already passed 10_regression_analysis.R's own filter(),
# so none of them should show non-finite values here.
formula_vars <- c(all.vars(model_formula), "dest_workplaces")
cat("\nNon-finite counts per column, in regression_data (pre-aggregation):\n")
print(sapply(regression_data[formula_vars], function(x) sum(!is.finite(as.numeric(x)))))

# Workplace-weighted mean for destination-varying variables (see header note
# above); origin-constant variables use a plain mean() since weighting can't
# change their (already-identical-within-group) value.
#
# dest_workplaces should never legitimately be 0 -- 04_r5r_route_batch.R only
# routes to destinations with workplaces > 150 -- but a small fraction of
# rows have it anyway (spurious st_nearest_feature() snaps to an adjacent
# low/zero-workplace cell in 10_regression_analysis.R's join). If every
# destination reachable from a given origin happens to hit this, sum(w) = 0
# and weighted.mean() returns NaN, which then fails the is.finite() filter
# below and silently drops that origin row -- if it happens broadly enough,
# origin_data collapses to 0 rows. Fall back to an unweighted mean for that
# origin rather than propagating NaN.
wmean <- function(x, w) {
  if (!is.finite(sum(w, na.rm = TRUE)) || sum(w, na.rm = TRUE) == 0) {
    return(mean(x, na.rm = TRUE))
  }
  stats::weighted.mean(x, w, na.rm = TRUE)
}

origin_data_raw <- regression_data %>%
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
    n_destinations             = dplyr::n(),
    .groups = "drop"
  )

cat("\nOrigin zones before finiteness filter:", nrow(origin_data_raw), "\n")
cat("Non-finite counts per column, AFTER aggregation (origin_data_raw):\n")
print(sapply(origin_data_raw, function(x) sum(!is.finite(x))))

# Verbs namespaced (dplyr::) below: sp/spdep/spatialreg/ggplot2 are all
# loaded after dplyr, and if any of them also export filter()/group_by()/
# summarise(), the unqualified call would silently resolve to the wrong
# function instead of erroring -- exactly the kind of bug that can zero out
# every row without any warning.
origin_data <- origin_data_raw %>% dplyr::filter(dplyr::if_all(dplyr::everything(), is.finite))

cat("\nOrigin zones for spatial modelling:", nrow(origin_data), "\n")
if (nrow(origin_data) == 0) {
  stop(
    "0 origin zones survived aggregation. See the non-finite counts printed ",
    "above: whichever column(s) show a non-zero count are the cause -- most ",
    "likely NA/Inf introduced during the group_by/summarise step above (e.g. ",
    "if a column that's supposed to be origin-constant, like nearest_stop_is_rail ",
    "or dist_to_stop_m, actually varies within an origin group due to a join ",
    "issue upstream in 10_regression_analysis.R)."
  )
}

origin_sf <- origin_data %>%
  st_as_sf(coords = c("from_lon", "from_lat"), crs = 4326) %>%
  st_transform(2180)

coords <- st_coordinates(origin_sf)

# ── 2. Spatial weights (k-nearest-neighbours; origin zones are not on a
#      regular raster, unlike the 120m grid used for LISA, so a distance-band
#      neighbourhood risks islands with zero neighbours) ────────────────────
nb <- knn2nb(knearneigh(coords, k = 8))
lw <- nb2listw(nb, style = "W")

# ── 3. OLS baseline + Lagrange Multiplier tests ───────────────────────────────
ols_model <- lm(model_formula, data = origin_data)
cat("\n--- OLS (origin-level baseline) ---\n")
print(summary(ols_model))

# Multicollinearity check on the model actually reported (Table 4), not the
# raw pseudo-replicated OD-pair data checked in 10_regression_analysis.R
# (that earlier check is a variable-selection diagnostic at the wrong
# granularity for inference; this one is on the exact predictor set and row
# granularity the OLS/SEM/SDM coefficients in the manuscript come from).
cat("\nVIF on the origin-level OLS model (car::vif):\n")
vif_vals <- car::vif(ols_model)
print(sort(vif_vals, decreasing = TRUE))
write.csv(data.frame(variable = names(vif_vals), vif = as.numeric(vif_vals)),
          "regression_vif.csv", row.names = FALSE)

cat("\nMoran's I on OLS residuals:\n")
print(lm.morantest(ols_model, lw))

# LM tests diagnose whether the data supports a spatial LAG process, an
# ERROR process, or both, before committing to a specification. The robust
# versions (RLMerr/RLMlag) remain valid even when both forms of dependence
# are present, so they're the ones to read first.
cat("\nLagrange Multiplier tests for spatial dependence (OLS residuals):\n")
lm_tests <- lm.LMtests(ols_model, lw, test = c("LMerr", "LMlag", "RLMerr", "RLMlag"))
print(lm_tests)

lm_tests_df <- do.call(rbind, lapply(names(lm_tests), function(nm) {
  ht <- lm_tests[[nm]]
  data.frame(type = "LM", test = nm,
             statistic = unname(ht$statistic), df = unname(ht$parameter),
             p_value = ht$p.value)
}))

# ── 4. Spatial Error Model ────────────────────────────────────────────────────
sem_model <- errorsarlm(model_formula, data = origin_data, listw = lw)
cat("\n--- SEM (spatial error) ---\n")
print(summary(sem_model))

cat("\nMoran's I on SEM residuals:\n")
print(moran.test(residuals(sem_model), lw))

# ── 5. Spatial Durbin Model ────────────────────────────────────────────────────
sdm_model <- lagsarlm(model_formula, data = origin_data, listw = lw, type = "Durbin")
cat("\n--- Spatial Durbin Model ---\n")
print(summary(sdm_model))

cat("\nMoran's I on SDM residuals:\n")
print(moran.test(residuals(sdm_model), lw))

# ── 6. Likelihood-ratio test: is the extra Durbin complexity justified? ─────
# SDM vs SEM: the "common factor" test (theta = -rho*beta); if it fails to
# reject, the simpler SEM is preferred.
#
# Computed manually via logLik() rather than spatialreg::LR.sarlm(), since
# that function's availability/name has shifted across spatialreg versions
# (some versions only expose the test via anova(model1, model2)). logLik()
# is a base S3 method that already works here -- it's what AIC() uses
# internally, and AIC() already succeeded on both models above.
lr_test_manual <- function(model_full, model_reduced, label) {
  ll_full    <- as.numeric(logLik(model_full))
  ll_reduced <- as.numeric(logLik(model_reduced))
  df_full    <- attr(logLik(model_full), "df")
  df_reduced <- attr(logLik(model_reduced), "df")
  statistic  <- 2 * (ll_full - ll_reduced)
  df         <- df_full - df_reduced
  p_value    <- pchisq(statistic, df = df, lower.tail = FALSE)
  cat(sprintf(
    "%s: logLik full = %.3f (df=%d), logLik reduced = %.3f (df=%d)\n  LR statistic = %.3f, df = %d, p-value = %s\n",
    label, ll_full, df_full, ll_reduced, df_reduced, statistic, df,
    format.pval(p_value, digits = 4)
  ))
  data.frame(type = "LR", test = label, statistic = statistic, df = df, p_value = p_value)
}

cat("\nLR test: SDM vs. SEM (common factor test):\n")
lr_sdm_sem_df <- lr_test_manual(sdm_model, sem_model, "SDM_vs_SEM")

write.csv(rbind(lm_tests_df, lr_sdm_sem_df), "spatial_dependence_tests.csv", row.names = FALSE)

# ── 7. SDM impact decomposition (direct/indirect/total effects) ──────────────
# The main reason to prefer SDM over SEM for planning implications (RQ3),
# if the LR test above supports it: does improving PT at one origin
# measurably help its neighbours, or is the effect purely local? SEM
# doesn't decompose spillovers this way.
cat("\nSDM impact decomposition (direct/indirect/total effects):\n")
sdm_impacts <- impacts(sdm_model, listw = lw, R = 500)
sdm_impacts_summary <- summary(sdm_impacts, zstats = TRUE)
print(sdm_impacts_summary)  # full output incl. z-stats/p-values, console only

# BUG FIX (found 2026-07-28, via external manuscript review): point estimates
# live under sdm_impacts$res$direct/$indirect/$total, NOT sdm_impacts$direct/
# $indirect/$total directly -- the previous version of this code read the
# latter, which don't exist on a "LagImpact" object in this spatialreg version
# (1.4.3), so every field silently resolved to NULL and write.csv() wrote an
# empty file with no warning or error. p-values (from the R=500 simulation)
# are taken from summary(sdm_impacts, zstats=TRUE)$pzmat, whose three columns
# are, in order, Direct/Indirect/Total (matching the console print above).
# SECOND BUG FIX (found 2026-07-28, same day, after dropping a predictor):
# names(sdm_impacts$res$direct) is not reliably populated (returned character(0)
# once the predictor count changed from 10 to 9), even though the point
# estimates themselves are fine -- use rownames(sdm_impacts_summary$pzmat)
# instead, which is always populated (it's what the console print above
# relies on) and is guaranteed to be in the same variable order as $res.
sdm_impacts_df <- data.frame(
  variable   = rownames(sdm_impacts_summary$pzmat),
  direct     = sdm_impacts$res$direct,
  indirect   = sdm_impacts$res$indirect,
  total      = sdm_impacts$res$total,
  direct_p   = sdm_impacts_summary$pzmat[, 1],
  indirect_p = sdm_impacts_summary$pzmat[, 2],
  total_p    = sdm_impacts_summary$pzmat[, 3]
)
write.csv(sdm_impacts_df, "sdm_impacts.csv", row.names = FALSE)

# ── 8. Model comparison: OLS vs. SEM vs. SDM ─────────────────────────────────
pseudo_r2 <- function(observed, fitted) cor(observed, fitted, use = "complete.obs")^2

comparison <- data.frame(
  model = c("OLS", "SEM (error)", "SDM (Durbin)"),
  aic = c(AIC(ols_model), AIC(sem_model), AIC(sdm_model)),
  pseudo_r2 = c(
    pseudo_r2(origin_data$tt_ratio, fitted(ols_model)),
    pseudo_r2(origin_data$tt_ratio, sem_model$fitted.values),
    pseudo_r2(origin_data$tt_ratio, sdm_model$fitted.values)
  ),
  # Indexed positionally (not by name): lm.morantest() labels this element
  # "Observed Moran I" while moran.test() labels the same quantity "Moran I
  # statistic" -- a naming inconsistency between the two spdep functions,
  # not a difference in what's being reported. Both put it first in $estimate.
  moran_i_residuals = c(
    lm.morantest(ols_model, lw)$estimate[[1]],
    moran.test(residuals(sem_model), lw)$estimate[[1]],
    moran.test(residuals(sdm_model), lw)$estimate[[1]]
  )
)

cat("\n--- Model comparison: OLS vs. SEM vs. SDM ---\n")
print(comparison)
write.csv(comparison, "spatial_regression_comparison.csv", row.names = FALSE)

cat("\nSaved spatial_regression_comparison.csv, spatial_dependence_tests.csv,\n",
    "sdm_impacts.csv, regression_vif.csv\n")
