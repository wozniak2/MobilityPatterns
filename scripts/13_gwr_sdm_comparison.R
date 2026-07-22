# =============================================================================
# 13_gwr_sdm_comparison.R
#
# Formally tests which spatial specification best fits the origin-zone
# PT/car travel-time ratio, motivated by the significant global Moran's I
# found on the modal gap surface in 09_analyse_itineraries.R (I = 0.182,
# z = 595.09, p < 2.2e-16): OLS residuals are not spatially independent, so
# plain lm() understates uncertainty and cannot capture spatial dependence.
#
# Workflow (standard spatial econometrics practice, LeSage & Pace-style):
#   1. Fit OLS, run Lagrange Multiplier tests (lm.LMtests: LMerr/LMlag and
#      their robust versions) to diagnose whether the data supports a
#      spatial LAG process, a spatial ERROR process, or both, before
#      committing to a specification.
#   2. Fit the three nested spatial regressions this points to: SAR (lag
#      only), SEM (error only), and SDM (Durbin -- lag + spatially lagged
#      predictors, nests SAR when the lagged-X coefficients are zero, and
#      nests SEM under the "common factor" restriction).
#   3. Likelihood-ratio test SDM against SAR and SEM to confirm the extra
#      Durbin complexity is actually justified rather than assumed.
#   4. Compare all four (+ GWR) on AIC, pseudo-R^2, and residual Moran's I.
#
# GWR is fit too, but for a DIFFERENT question than SAR/SEM/SDM answer: it
# tests spatial NON-STATIONARITY (do relationships vary by place), not
# spatial DEPENDENCE (are values correlated with neighbours). A prior run
# showed GWR's local R^2 is much higher than OLS's, but its residual
# Moran's I (0.383) was far WORSE than SDM's (0.054) -- high local fit does
# not mean the dependence problem is solved, because GWR has no lag/error
# term. GWR is kept here for its local coefficient maps (useful for RQ3 --
# which zones need which type of intervention), not as a competitor to
# SAR/SEM/SDM for "which spatial model is correct".
#
# DESIGN CHOICE: regression_data.csv is one row per OD pair, but these
# models need one observation per spatial location. Rows are aggregated to
# one per ORIGIN grid cell (mean tt_ratio across that origin's
# destinations); predictors that are already origin-constant
# (dist_to_stop_m, daily_departures, origin_dist_centre_km,
# nearest_stop_is_rail, origin_working_age_pop) average to their exact
# original value, so this loses no information for those. Predictors that
# vary by destination (dest_dist_centre_km, dest_working_age_pop,
# car_directness, walk_share, n_transfers) become an origin-level mean
# across its destinations.
#
# pt_duration_min and car_speed_kmh are deliberately excluded from the
# formula: tt_ratio = pt_duration_min / car_duration_min, so pt_duration_min
# is the outcome's own numerator (near-circular as a predictor), and
# car_speed_kmh is derived from car_duration_min, the outcome's denominator.
# car_directness (car_distance_m / straightline_m) is used instead as a
# distance-only proxy for car route quality, with no duration term shared
# with the outcome.
#
# INPUT  : regression_data.csv (from 11_regression_analysis.R, must include
#          from_lon/from_lat)
# OUTPUT : gwr_sdm_comparison.csv       -- AIC/pseudo-R2/Moran's I, all 5 models
#          spatial_dependence_tests.csv -- LM tests (OLS) + LR tests (SDM vs SAR/SEM)
#          sdm_impacts.csv              -- SDM direct/indirect/total effects
#          gwr_local_coefficients.csv
#          Figures/Fig_GWR_local_R2.png
#          Figures/Fig_GWR_coef_dist_to_stop.png
# =============================================================================

library(dplyr)
library(sf)
library(sp)
library(spdep)
library(spatialreg)
library(GWmodel)
library(ggplot2)

setwd("C:/Users/wozni/Google Drive/UAM/HUB/MobilityPatterns/Data")
dir.create("../Figures", showWarnings = FALSE)
set.seed(42)

model_formula <- tt_ratio ~ n_transfers + walk_share + daily_departures +
  dist_to_stop_m + origin_dist_centre_km + dest_dist_centre_km +
  origin_working_age_pop + dest_working_age_pop + nearest_stop_is_rail +
  car_directness

# ── 1. Load regression data & aggregate to one row per origin zone ───────────
regression_data <- read.csv("regression_data.csv")
cat("regression_data.csv rows:", nrow(regression_data), "\n")

required_cols <- c("from_id", "from_lon", "from_lat", all.vars(model_formula))
missing_cols  <- setdiff(required_cols, names(regression_data))
if (length(missing_cols) > 0) {
  stop(
    "regression_data.csv is missing column(s): ", paste(missing_cols, collapse = ", "),
    ". This usually means it was written by an older version of ",
    "11_regression_analysis.R -- re-run that script to regenerate regression_data.csv, ",
    "then re-run this script."
  )
}
if (nrow(regression_data) == 0) {
  stop(
    "regression_data.csv has 0 rows. 11_regression_analysis.R's own filter() ",
    "already dropped everything before this script ever ran -- check that ",
    "script's console output (row counts printed after each join/filter step) ",
    "to see where rows were lost."
  )
}

# Diagnostic: non-finite counts per formula variable, BEFORE aggregation --
# every one of these already passed 11_regression_analysis.R's own filter(),
# so none of them should show non-finite values here.
formula_vars <- all.vars(model_formula)
cat("\nNon-finite counts per column, in regression_data (pre-aggregation):\n")
print(sapply(regression_data[formula_vars], function(x) sum(!is.finite(as.numeric(x)))))

origin_data_raw <- regression_data %>%
  dplyr::group_by(from_id, from_lon, from_lat) %>%
  dplyr::summarise(
    tt_ratio                = mean(tt_ratio, na.rm = TRUE),
    n_transfers              = mean(n_transfers, na.rm = TRUE),
    walk_share                = mean(walk_share, na.rm = TRUE),
    daily_departures          = mean(daily_departures, na.rm = TRUE),
    dist_to_stop_m            = mean(dist_to_stop_m, na.rm = TRUE),
    origin_dist_centre_km     = mean(origin_dist_centre_km, na.rm = TRUE),
    dest_dist_centre_km       = mean(dest_dist_centre_km, na.rm = TRUE),
    origin_working_age_pop    = mean(origin_working_age_pop, na.rm = TRUE),
    dest_working_age_pop      = mean(dest_working_age_pop, na.rm = TRUE),
    nearest_stop_is_rail      = mean(nearest_stop_is_rail, na.rm = TRUE),
    car_directness             = mean(car_directness, na.rm = TRUE),
    n_destinations             = dplyr::n(),
    .groups = "drop"
  )

cat("\nOrigin zones before finiteness filter:", nrow(origin_data_raw), "\n")
cat("Non-finite counts per column, AFTER aggregation (origin_data_raw):\n")
print(sapply(origin_data_raw, function(x) sum(!is.finite(x))))

# Verbs namespaced (dplyr::) below: sp/spdep/spatialreg/GWmodel/ggplot2 are all
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
    "issue upstream in 11_regression_analysis.R)."
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

# ── 4. Spatial Autoregressive (lag) model ─────────────────────────────────────
sar_model <- lagsarlm(model_formula, data = origin_data, listw = lw, type = "lag")
cat("\n--- SAR (spatial lag) ---\n")
print(summary(sar_model))

cat("\nMoran's I on SAR residuals:\n")
print(moran.test(residuals(sar_model), lw))

# ── 5. Spatial Error Model ────────────────────────────────────────────────────
sem_model <- errorsarlm(model_formula, data = origin_data, listw = lw)
cat("\n--- SEM (spatial error) ---\n")
print(summary(sem_model))

cat("\nMoran's I on SEM residuals:\n")
print(moran.test(residuals(sem_model), lw))

# ── 6. Spatial Durbin Model ────────────────────────────────────────────────────
sdm_model <- lagsarlm(model_formula, data = origin_data, listw = lw, type = "Durbin")
cat("\n--- Spatial Durbin Model ---\n")
print(summary(sdm_model))

cat("\nMoran's I on SDM residuals:\n")
print(moran.test(residuals(sdm_model), lw))

# ── 7. Likelihood-ratio tests: is the extra Durbin complexity justified? ─────
# SDM vs SAR: tests whether the spatially-lagged-X coefficients are jointly
# zero (if so, the simpler SAR is preferred).
# SDM vs SEM: the "common factor" test (theta = -rho*beta); if it fails to
# reject, the simpler SEM is preferred.
#
# Computed manually via logLik() rather than spatialreg::LR.sarlm(), since
# that function's availability/name has shifted across spatialreg versions
# (some versions only expose the test via anova(model1, model2)). logLik()
# is a base S3 method that already works here -- it's what AIC() uses
# internally, and AIC() already succeeded on all three models above.
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

cat("\nLR test: SDM vs. SAR (are the spatially-lagged predictors needed?):\n")
lr_sdm_sar_df <- lr_test_manual(sdm_model, sar_model, "SDM_vs_SAR")

cat("\nLR test: SDM vs. SEM (common factor test):\n")
lr_sdm_sem_df <- lr_test_manual(sdm_model, sem_model, "SDM_vs_SEM")

lr_tests_df <- rbind(lr_sdm_sar_df, lr_sdm_sem_df)

write.csv(rbind(lm_tests_df, lr_tests_df), "spatial_dependence_tests.csv", row.names = FALSE)

# ── 8. SDM impact decomposition (direct/indirect/total effects) ──────────────
# The main reason to prefer SDM over SAR/SEM for planning implications
# (RQ3), if the LR tests above support it: does improving PT at one origin
# measurably help its neighbours, or is the effect purely local? SAR/SEM
# don't decompose spillovers this way.
cat("\nSDM impact decomposition (direct/indirect/total effects):\n")
sdm_impacts <- impacts(sdm_model, listw = lw, R = 500)
print(summary(sdm_impacts, zstats = TRUE))  # full output incl. z-stats/p-values, console only

# Point estimates only, from the stable base impacts() slots (summary.lagImpact's
# internal structure has changed across spatialreg versions, so avoid relying on it)
sdm_impacts_df <- data.frame(
  variable = names(sdm_impacts$direct),
  direct   = sdm_impacts$direct,
  indirect = sdm_impacts$indirect,
  total    = sdm_impacts$total
)
write.csv(sdm_impacts_df, "sdm_impacts.csv", row.names = FALSE)

# ── 9. Geographically Weighted Regression (secondary/exploratory -- see
#      header note: addresses spatial non-stationarity, not dependence) ─────
origin_sp <- as(origin_sf, "Spatial")

bw <- bw.gwr(model_formula, data = origin_sp, approach = "AICc",
             kernel = "bisquare", adaptive = TRUE)
cat("\nGWR adaptive bandwidth (n neighbours):", bw, "\n")

gwr_model <- gwr.basic(model_formula, data = origin_sp, bw = bw,
                        kernel = "bisquare", adaptive = TRUE)
print(gwr_model)

gwr_sf <- st_as_sf(gwr_model$SDF) %>% st_transform(4326)

cat("\nMoran's I on GWR residuals:\n")
print(moran.test(gwr_model$SDF$residual, lw))

write.csv(st_drop_geometry(gwr_sf), "gwr_local_coefficients.csv", row.names = FALSE)

# ── 10. Model comparison: OLS vs. SAR vs. SEM vs. SDM vs. GWR ────────────────
pseudo_r2 <- function(observed, fitted) cor(observed, fitted, use = "complete.obs")^2

comparison <- data.frame(
  model = c("OLS", "SAR (lag)", "SEM (error)", "SDM (Durbin)", "GWR"),
  aic = c(AIC(ols_model), AIC(sar_model), AIC(sem_model), AIC(sdm_model),
          gwr_model$GW.diagnostic$AICc),
  pseudo_r2 = c(
    pseudo_r2(origin_data$tt_ratio, fitted(ols_model)),
    pseudo_r2(origin_data$tt_ratio, sar_model$fitted.values),
    pseudo_r2(origin_data$tt_ratio, sem_model$fitted.values),
    pseudo_r2(origin_data$tt_ratio, sdm_model$fitted.values),
    pseudo_r2(origin_data$tt_ratio, gwr_model$SDF$yhat)
  ),
  moran_i_residuals = c(
    lm.morantest(ols_model, lw)$estimate[["Moran I statistic"]],
    moran.test(residuals(sar_model), lw)$estimate[["Moran I statistic"]],
    moran.test(residuals(sem_model), lw)$estimate[["Moran I statistic"]],
    moran.test(residuals(sdm_model), lw)$estimate[["Moran I statistic"]],
    moran.test(gwr_model$SDF$residual, lw)$estimate[["Moran I statistic"]]
  )
)

cat("\n--- Model comparison: OLS vs. SAR vs. SEM vs. SDM vs. GWR ---\n")
print(comparison)
write.csv(comparison, "gwr_sdm_comparison.csv", row.names = FALSE)

# ── 11. Maps: local model fit and one policy-relevant local coefficient ──────
ggplot(gwr_sf) +
  geom_sf(aes(colour = Local_R2), size = 1.5) +
  scale_colour_viridis_c(option = "plasma") +
  labs(
    title    = "GWR local R-squared",
    subtitle = "Spatial variation in model fit across origin zones"
  ) +
  theme_minimal()

ggsave("../Figures/Fig_GWR_local_R2.png", width = 8, height = 6, dpi = 300)

ggplot(gwr_sf) +
  geom_sf(aes(colour = dist_to_stop_m), size = 1.5) +
  scale_colour_gradient2(low = "#2980b9", mid = "grey90", high = "#c0392b", midpoint = 0,
                          name = "Local coefficient") +
  labs(
    title    = "GWR local coefficient: distance to nearest stop",
    subtitle = "Positive = longer stop distance locally associated with a worse PT/car ratio"
  ) +
  theme_minimal()

ggsave("../Figures/Fig_GWR_coef_dist_to_stop.png", width = 8, height = 6, dpi = 300)

cat("\nSaved gwr_sdm_comparison.csv, spatial_dependence_tests.csv, sdm_impacts.csv,\n",
    "gwr_local_coefficients.csv, Figures/Fig_GWR_local_R2.png,\n",
    "Figures/Fig_GWR_coef_dist_to_stop.png\n")
