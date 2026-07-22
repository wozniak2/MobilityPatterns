# =============================================================================
# 13_gwr_sdm_comparison.R
#
# Compares two spatial extensions of the OLS regression in
# 11_regression_analysis.R: Geographically Weighted Regression (GWR, local
# coefficients per zone) and a Spatial Durbin Model (SDM, global spatial
# dependence + spillover decomposition). Both are motivated by the
# significant global Moran's I found on the modal gap surface in
# 09_analyse_itineraries.R (I = 0.182, z = 595.09, p < 2.2e-16): OLS residuals
# are not spatially independent, so plain lm() understates uncertainty and
# cannot capture spatial spillovers or spatially varying effects.
#
# DESIGN CHOICE: regression_data.csv is one row per OD pair, but GWR/SDM need
# one observation per spatial location. Rows are aggregated to one per ORIGIN
# grid cell (mean tt_ratio across that origin's destinations); predictors
# that are already origin-constant (dist_to_stop_m, daily_departures,
# origin_dist_centre_km, nearest_stop_is_rail, origin_working_age_pop)
# average to their exact original value, so this loses no information for
# those. Predictors that vary by destination (dest_dist_centre_km,
# dest_working_age_pop, car_directness, walk_share, n_transfers) become an
# origin-level mean across its destinations.
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
# OUTPUT : gwr_sdm_comparison.csv
#          gwr_local_coefficients.csv
#          sdm_impacts.csv
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

origin_data <- regression_data %>%
  group_by(from_id, from_lon, from_lat) %>%
  summarise(
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
    n_destinations             = n(),
    .groups = "drop"
  ) %>%
  filter(if_all(everything(), is.finite))

cat("Origin zones for spatial modelling:", nrow(origin_data), "\n")

origin_sf <- origin_data %>%
  st_as_sf(coords = c("from_lon", "from_lat"), crs = 4326) %>%
  st_transform(2180)

coords <- st_coordinates(origin_sf)

# ── 2. Spatial weights (k-nearest-neighbours; origin zones are not on a
#      regular raster, unlike the 120m grid used for LISA, so a distance-band
#      neighbourhood risks islands with zero neighbours) ────────────────────
nb <- knn2nb(knearneigh(coords, k = 8))
lw <- nb2listw(nb, style = "W")

# ── 3. OLS baseline (refit at origin level for a fair comparison) ────────────
ols_model <- lm(model_formula, data = origin_data)
cat("\n--- OLS (origin-level baseline) ---\n")
print(summary(ols_model))

cat("\nMoran's I on OLS residuals:\n")
print(lm.morantest(ols_model, lw))

# ── 4. Spatial Durbin Model ───────────────────────────────────────────────────
sdm_model <- lagsarlm(model_formula, data = origin_data, listw = lw, type = "Durbin")
cat("\n--- Spatial Durbin Model ---\n")
print(summary(sdm_model))

cat("\nMoran's I on SDM residuals:\n")
print(moran.test(residuals(sdm_model), lw))

# Direct/indirect/total effects (spillover decomposition) -- the main reason
# to prefer SDM over OLS/GWR for planning implications (RQ3): does improving
# PT at one origin measurably help its neighbours, or is the effect purely local?
cat("\nSDM impact decomposition (direct/indirect/total effects):\n")
sdm_impacts <- impacts(sdm_model, listw = lw, R = 200)
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

# ── 5. Geographically Weighted Regression ─────────────────────────────────────
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

# ── 6. Model comparison ───────────────────────────────────────────────────────
pseudo_r2 <- function(observed, fitted) cor(observed, fitted, use = "complete.obs")^2

comparison <- data.frame(
  model = c("OLS", "SDM (Durbin)", "GWR"),
  aic = c(AIC(ols_model), AIC(sdm_model), gwr_model$GW.diagnostic$AICc),
  pseudo_r2 = c(
    pseudo_r2(origin_data$tt_ratio, fitted(ols_model)),
    pseudo_r2(origin_data$tt_ratio, sdm_model$fitted.values),
    pseudo_r2(origin_data$tt_ratio, gwr_model$SDF$yhat)
  ),
  moran_i_residuals = c(
    lm.morantest(ols_model, lw)$estimate[["Moran I statistic"]],
    moran.test(residuals(sdm_model), lw)$estimate[["Moran I statistic"]],
    moran.test(gwr_model$SDF$residual, lw)$estimate[["Moran I statistic"]]
  )
)

cat("\n--- Model comparison: OLS vs. SDM vs. GWR ---\n")
print(comparison)
write.csv(comparison, "gwr_sdm_comparison.csv", row.names = FALSE)

# ── 7. Maps: local model fit and one policy-relevant local coefficient ───────
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

cat("\nSaved gwr_sdm_comparison.csv, gwr_local_coefficients.csv, sdm_impacts.csv,\n",
    "Figures/Fig_GWR_local_R2.png, Figures/Fig_GWR_coef_dist_to_stop.png\n")
