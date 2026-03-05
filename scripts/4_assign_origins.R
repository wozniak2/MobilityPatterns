library(sf)
library(dplyr) 
#library(terra)

setwd("/Users/wozni/Google Drive/UAM/HUB/MobilityPatterns/Data")

## read files
OD_flows <- read.csv("OD_flows.csv")
pop_wp_grid <- st_read("pop_workplaces_grid.gpkg")
# boundry for Poznan agglomeration
ap <- st_read("ap.gpkg") ## city
pop_wp_flows <- st_read("pop_wp_flows_grid.gpkg")

# some sums
sum(ff_grid$total_workplaces, na.rm=T)
sum(ff_grid$population, na.rm=T)
sum(OD_sf$commuters, na.rm=T)

# correlation between population size and OD flows
cor(ff_grid$population, ff_grid$commuters, use = "complete.obs")

# add Poznan
pop_wp_flows$home_name[is.na(pop_wp_flows$home_name)] <- "Poznan"

# assign probabilities based on population and location
df_norm <- pop_wp_flows %>%
  group_by(home_name) %>%
  mutate(prob = population / sum(population, na.rm = TRUE))

# assign origins based on commuters numbers and probabilities
origins_distributed <- df_norm %>%
  group_by(home_name) %>%
  mutate(com_num = round(prob * mean(commuters, na.rm = TRUE)), digits = 0)




