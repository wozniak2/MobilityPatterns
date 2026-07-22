library(dplyr)
library(ggplot2)

setwd("C:/Users/wozni/Google Drive/UAM/HUB/MobilityPatterns/Data")
itineraries <- read.csv("itineraries_weights.csv")

itineraries$has_rail <- ifelse(grepl("RAIL", itineraries$modes), 1, 0)

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
  theme_minimal()

#Only rail
ggplot(w_ratio_rail, aes(x = weighted_ratio, y = ..density.., weight = working_age_pop)) + 
  geom_histogram() +
  theme_minimal()

#Other
ggplot(w_ratio_other, aes(x = weighted_ratio, y = ..density.., weight = working_age_pop)) + 
  geom_histogram() +
  theme_minimal()

#Rail vs. other
ggplot(w_ratio_combined, 
       aes(x = weighted_ratio, 
           y = ..density.., 
           weight = working_age_pop, 
           colour = rail,
           fill = rail)) + 
  geom_histogram(position = "identity", alpha = 0.5) +
  theme_minimal()

#Plot cumulative sum of population by workplace-averaged travel time ratio
working_age_pop_sum <- sum(w_ratio$working_age_pop)

#All
ggplot(w_ratio, aes(x = weighted_ratio, y = sum_pop/working_age_pop_sum)) +
  geom_line() +
  expand_limits(x = 0, y = 0) +
  scale_y_continuous(labels = scales::percent) +
  theme_minimal()

#Rail vs. no rail
ggplot(w_ratio_combined, aes(x = weighted_ratio, y = sum_pop/working_age_pop_sum, colour = rail)) +
  geom_line() +
  expand_limits(x = 0, y = 0) +
  scale_y_continuous(labels = scales::percent) +
  theme_minimal()

#Take a look at the most competitive itineraries
competitive <- itineraries %>% filter(time_ratio < 1.5)
competitive_by_muni <- table(competitive$county) %>% as.data.frame() %>% arrange(-Freq)
competitive_by_muni

#Take a look at the least competitive itineraries (to be improved)
improvement <- itineraries %>% filter(time_ratio > 2.5)
improvement_by_muni <- table(improvement$county) %>% as.data.frame() %>% arrange(-Freq)
improvement_by_muni

#Identify high priority itineraries for improvement (?)
high_priority <- itineraries %>% 
  filter(working_age_pop > quantile(working_age_pop, probs = 0.75)) %>% 
  filter(workplaces > quantile(workplaces, probs = 0.75)) %>%
  filter(time_ratio > quantile(time_ratio, probs = 0.75))

#TBD: identify routes most prevalent in competitive/to be improved itineraries
