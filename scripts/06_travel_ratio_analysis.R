# =============================================================================
# 06_travel_ratio_analysis.R
#
# Attaches population/workplace weights to commuting itineraries, then
# explores the resulting PT/car travel-time ratios: population-weighted
# distributions (the "what share of residents experience ratio X" view,
# rather than treating every OD pair as equally important regardless of who
# lives there), rail vs. non-rail comparison, and competitive/improvement-
# needed itineraries by municipality.
#
# Merged 2026-07-27 from two former scripts (06_add_weights_to_itineraries.R
# + 07_explore_travel_ratios.R): itineraries_weights.csv, written by the
# first half below, had exactly one consumer -- the second half, in the
# very next script -- so splitting the weight-attachment and the analysis
# that immediately reads it back in was pure indirection. Still written to
# disk (as an audit artifact you can inspect directly), but the analysis
# below uses the in-memory object rather than re-reading the CSV.
#
# REQUIRES TO RUN:
#   - pt_itineraries.rds, car_itineraries.rds (written by 05_read_itineraries.R
#     — run that script first if either file is missing)
#   - pop_grid.gpkg (02_distribute_population.R), workplace_grid.gpkg
#     (01_calculate_workplaces.R)
#   - od_pair_utils.R, sourced automatically below (not run directly)
# OUTPUT : itineraries_weights.csv
#          Figures/Fig_travelratio_density.png
#          Figures/Fig_travelratio_density_rail.png
#          Figures/Fig_travelratio_density_norail.png
#          Figures/Fig_travelratio_density_rail_vs_norail.png
#          Figures/Fig_travelratio_cumulative_population.png
#          Figures/Fig_travelratio_cumulative_population_rail_vs_norail.png
#          competitive_by_municipality.csv
#          improvement_by_municipality.csv
# =============================================================================

library(data.table)
library(dplyr)
library(sf)
library(ggplot2)

setwd("C:/Users/wozni/Google Drive/UAM/HUB/MobilityPatterns/Data")
source("C:/Users/wozni/OneDrive/Documents/GitHub/MobilityPatterns/scripts/od_pair_utils.R")
dir.create("../Figures", showWarnings = FALSE)

# =============================================================================
# Part 1 — attach population/workplace weights to itineraries
# =============================================================================

#Read itineraries produced by 05_read_itineraries.R
pt_itineraries  <- readRDS("pt_itineraries.rds")
car_itineraries <- readRDS("car_itineraries.rds")

#Read & prepare grids
pop_grid <- st_read("pop_grid.gpkg")
workplace_grid <- st_read("workplace_grid.gpkg")

workplace_grid <- st_transform(workplace_grid, crs = st_crs(pop_grid))

pop_grid$area <- st_area(pop_grid)
pop_grid <- setDT(pop_grid)[, .SD[which.max(area)], by=grid_id] #Remove cells with duplicate IDs on municipal boundaries
pop_grid <- st_as_sf(pop_grid)

# Collapse itineraries to one row per OD pair and compute PT/car ratios
# (shared with 07/09/10 -- see od_pair_utils.R). Renamed to this script's
# pre-existing column names (total_duration/total_distance/car_duration/
# car_distance/time_ratio) so itineraries_weights.csv's schema is unchanged.
od_combined <- build_od_comparison(pt_itineraries, car_itineraries) |>
  rename(
    total_duration = pt_duration_min,
    total_distance  = pt_distance_m,
    car_duration    = car_duration_min,
    car_distance    = car_distance_m,
    time_ratio      = tt_ratio
  )

# Origin weight — population
itineraries_pop <- od_combined |>
  st_as_sf(coords = c("from_lon", "from_lat"), crs = 4326) |>
  st_transform(st_crs(pop_grid)) |>
  st_join(pop_grid |> select(grid_id, working_age_pop), join = st_intersects) |>
  mutate(
    from_lon = st_coordinates(geometry)[, 1],  # ← extract before dropping
    from_lat = st_coordinates(geometry)[, 2]
  ) |>
  st_drop_geometry() |>
  filter(!is.na(working_age_pop))

cat("After pop join:", nrow(itineraries_pop), "rows\n")

# Destination weight — workplaces
# After the final st_drop_geometry(), add coordinates back explicitly
itineraries_weights <- itineraries_pop |>
  st_as_sf(coords = c("to_lon", "to_lat"), crs = 4326) |>
  st_transform(st_crs(workplace_grid)) |>
  st_join(workplace_grid |> select(workplaces), join = st_intersects) |>
  mutate(                              # ← extract coords before dropping
    to_lon = st_coordinates(geometry)[, 1],
    to_lat = st_coordinates(geometry)[, 2]
  ) |>
  st_drop_geometry() |>
  filter(!is.na(workplaces))

cat("After workplace join:", nrow(itineraries_weights), "rows\n")

write.csv(itineraries_weights, "itineraries_weights.csv", row.names = FALSE)

# =============================================================================
# Part 2 — explore the weighted travel-time ratios
# =============================================================================
# Uses itineraries_weights directly (in memory) rather than re-reading the
# CSV just written above.
itineraries <- itineraries_weights

# has_rail is already computed by build_od_comparison() in Part 1
# (has_rail = any(mode == "RAIL") per OD pair) -- reused directly here rather
# than re-deriving it from the `modes` string a second time.

#Calculate travel time ratios averaged by workplaces
w_ratio <- itineraries %>%
  group_by(from_id, working_age_pop) %>%
  summarise(weighted_ratio = weighted.mean(x = time_ratio, w = workplaces)) %>%
  arrange(weighted_ratio) %>%
  ungroup() %>%
  mutate(sum_pop = cumsum(working_age_pop))

#Only itineraries that include rail
w_ratio_rail <- itineraries %>%
  filter(has_rail == 1) %>%
  group_by(from_id, working_age_pop) %>%
  summarise(weighted_ratio = weighted.mean(x = time_ratio, w = workplaces)) %>%
  arrange(weighted_ratio) %>%
  ungroup() %>%
  mutate(sum_pop = cumsum(working_age_pop),
         rail = "rail")

#Other itineraries
w_ratio_other <- itineraries %>%
  filter(has_rail == 0) %>%
  group_by(from_id, working_age_pop) %>%
  summarise(weighted_ratio = weighted.mean(x = time_ratio, w = workplaces)) %>%
  arrange(weighted_ratio) %>%
  ungroup() %>%
  mutate(sum_pop = cumsum(working_age_pop),
         rail = "no rail")

w_ratio_combined <- rbind(w_ratio_rail, w_ratio_other)

#Plot histogram of travel time ratios averaged by workplaces and weighted by population
ggplot(w_ratio, aes(x = weighted_ratio, y = ..density.., weight = working_age_pop)) +
  geom_histogram() +
  labs(
    title = "Population-weighted distribution of PT/car travel-time ratio",
    x = "Workplace-weighted PT/car travel-time ratio (per origin)",
    y = "Density (weighted by working-age population)"
  ) +
  theme_minimal()

ggsave("../Figures/Fig_travelratio_density.png", width = 8, height = 6, dpi = 300)
cat("Saved Figures/Fig_travelratio_density.png\n")

#Only rail
ggplot(w_ratio_rail, aes(x = weighted_ratio, y = ..density.., weight = working_age_pop)) +
  geom_histogram() +
  labs(
    title = "Population-weighted PT/car ratio -- rail-served origins only",
    x = "Workplace-weighted PT/car travel-time ratio (per origin)",
    y = "Density (weighted by working-age population)"
  ) +
  theme_minimal()

ggsave("../Figures/Fig_travelratio_density_rail.png", width = 8, height = 6, dpi = 300)
cat("Saved Figures/Fig_travelratio_density_rail.png\n")

#Other
ggplot(w_ratio_other, aes(x = weighted_ratio, y = ..density.., weight = working_age_pop)) +
  geom_histogram() +
  labs(
    title = "Population-weighted PT/car ratio -- non-rail origins only",
    x = "Workplace-weighted PT/car travel-time ratio (per origin)",
    y = "Density (weighted by working-age population)"
  ) +
  theme_minimal()

ggsave("../Figures/Fig_travelratio_density_norail.png", width = 8, height = 6, dpi = 300)
cat("Saved Figures/Fig_travelratio_density_norail.png\n")

#Rail vs. other
ggplot(w_ratio_combined,
       aes(x = weighted_ratio,
           y = ..density..,
           weight = working_age_pop,
           colour = rail,
           fill = rail)) +
  geom_histogram(position = "identity", alpha = 0.5) +
  labs(
    x = "Workplace-weighted PT/car travel-time ratio (per origin)",
    y = "Density (weighted by working-age population)",
    colour = NULL, fill = NULL
  ) +
  theme_minimal(base_size = 18) +
  theme(
    axis.title  = element_text(size = 19),
    axis.text   = element_text(size = 18),
    legend.text = element_text(size = 18),
    legend.position = "top"
  )

ggsave("../Figures/Fig_travelratio_density_rail_vs_norail.png", width = 8, height = 6, dpi = 300)
cat("Saved Figures/Fig_travelratio_density_rail_vs_norail.png\n")

#Plot cumulative sum of population by workplace-averaged travel time ratio
working_age_pop_sum <- sum(w_ratio$working_age_pop)

#All
ggplot(w_ratio, aes(x = weighted_ratio, y = sum_pop/working_age_pop_sum)) +
  geom_line() +
  expand_limits(x = 0, y = 0) +
  scale_y_continuous(labels = scales::percent) +
  labs(
    title = "Cumulative population share by PT/car travel-time ratio",
    x = "Workplace-weighted PT/car travel-time ratio (per origin)",
    y = "Cumulative share of working-age population"
  ) +
  theme_minimal()

ggsave("../Figures/Fig_travelratio_cumulative_population.png", width = 8, height = 6, dpi = 300)
cat("Saved Figures/Fig_travelratio_cumulative_population.png\n")

#Rail vs. no rail
ggplot(w_ratio_combined, aes(x = weighted_ratio, y = sum_pop/working_age_pop_sum, colour = rail)) +
  geom_line(linewidth = 1) +
  expand_limits(x = 0, y = 0) +
  scale_y_continuous(labels = scales::percent) +
  labs(
    x = "Workplace-weighted PT/car travel-time ratio (per origin)",
    y = "Cumulative share of working-age population",
    colour = NULL
  ) +
  theme_minimal(base_size = 18) +
  theme(
    axis.title  = element_text(size = 19),
    axis.text   = element_text(size = 18),
    legend.text = element_text(size = 18),
    legend.position = "top"
  )

ggsave("../Figures/Fig_travelratio_cumulative_population_rail_vs_norail.png", width = 8, height = 6, dpi = 300)
cat("Saved Figures/Fig_travelratio_cumulative_population_rail_vs_norail.png\n")

#Take a look at the most competitive itineraries
competitive <- itineraries %>% filter(time_ratio < 1.5)
competitive_by_muni <- table(competitive$county) %>% as.data.frame() %>% arrange(-Freq)
names(competitive_by_muni) <- c("county", "n_competitive_itineraries")
print(competitive_by_muni)
write.csv(competitive_by_muni, "competitive_by_municipality.csv", row.names = FALSE)

#Take a look at the least competitive itineraries (to be improved)
improvement <- itineraries %>% filter(time_ratio > 2.5)
improvement_by_muni <- table(improvement$county) %>% as.data.frame() %>% arrange(-Freq)
names(improvement_by_muni) <- c("county", "n_improvement_itineraries")
print(improvement_by_muni)
write.csv(improvement_by_muni, "improvement_by_municipality.csv", row.names = FALSE)

cat("\nSaved competitive_by_municipality.csv and improvement_by_municipality.csv\n")

#Identify high priority itineraries for improvement (?)
high_priority <- itineraries %>%
  filter(working_age_pop > quantile(working_age_pop, probs = 0.75)) %>%
  filter(workplaces > quantile(workplaces, probs = 0.75)) %>%
  filter(time_ratio > quantile(time_ratio, probs = 0.75))

#TBD: identify routes most prevalent in competitive/to be improved itineraries
