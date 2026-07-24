# =============================================================================
# 07_explore_travel_ratios.R
#
# Exploratory analysis of PT/car travel-time ratios: population-weighted
# distributions (the "what share of residents experience ratio X" view,
# rather than treating every OD pair as equally important regardless of who
# lives there), rail vs. non-rail comparison, and competitive/improvement-
# needed itineraries by municipality.
#
# INPUT  : itineraries_weights.csv (from 06_add_weights_to_itineraries.R)
# OUTPUT : Figures/Fig_travelratio_density.png
#          Figures/Fig_travelratio_density_rail.png
#          Figures/Fig_travelratio_density_norail.png
#          Figures/Fig_travelratio_density_rail_vs_norail.png
#          Figures/Fig_travelratio_cumulative_population.png
#          Figures/Fig_travelratio_cumulative_population_rail_vs_norail.png
#          competitive_by_municipality.csv
#          improvement_by_municipality.csv
# =============================================================================

library(dplyr)
library(ggplot2)

setwd("C:/Users/wozni/Google Drive/UAM/HUB/MobilityPatterns/Data")
dir.create("../Figures", showWarnings = FALSE)

itineraries <- read.csv("itineraries_weights.csv")

# has_rail is already computed in 06_add_weights_to_itineraries.R
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
    title = "Population-weighted PT/car ratio: rail vs. non-rail origins",
    x = "Workplace-weighted PT/car travel-time ratio (per origin)",
    y = "Density (weighted by working-age population)",
    colour = NULL, fill = NULL
  ) +
  theme_minimal()

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
  geom_line() +
  expand_limits(x = 0, y = 0) +
  scale_y_continuous(labels = scales::percent) +
  labs(
    title = "Cumulative population share by PT/car ratio: rail vs. non-rail",
    x = "Workplace-weighted PT/car travel-time ratio (per origin)",
    y = "Cumulative share of working-age population",
    colour = NULL
  ) +
  theme_minimal()

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
