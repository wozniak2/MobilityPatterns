library(sf)
library(dplyr) 
#library(terra)

setwd("/Users/wozni/Google Drive/UAM/HUB/MobilityPatterns/Data")

## read files
OD_flows <- read.csv("OD_flows.csv")
pop_wp_grid <- st_read("pop_workplaces_grid.gpkg")
# boundry for Poznan agglomeration
ap <- st_read("ap.gpkg") ## city
pop_wp_flows <- st_read("pop_wp_flows_grid.gpkg") ## output of "3_merge_pop_workplaces.R"

# some sums
sum(ff_grid$total_workplaces, na.rm=T)
sum(ff_grid$population, na.rm=T)
sum(OD_sf$commuters, na.rm=T)

# add Poznan to sf
pop_wp_flows$home_name[is.na(pop_wp_flows$home_name)] <- "Poznan"

# assign probabilities based on population and locations
df_norm <- pop_wp_flows %>%
  group_by(home_name) %>%
  mutate(prob = population / sum(population, na.rm = TRUE))

# assign origins based on commuter numbers and probabilities
origins_distributed <- df_norm %>%
  group_by(home_name) %>%
  mutate(com_num = round(prob * mean(commuters, na.rm = TRUE)), digits = 0)


# Plot distributed origins
ggplot(data = origins_distributed) +
  geom_sf(aes(fill = com_num), color="black", lwd = 0.1, alpha = 0.9) +
  scale_fill_viridis_c(begin = 0.1, end = 1, option = "plasma", na.value = "transparent") +
  theme_bw() +
  theme(legend.background = element_rect(fill = "transparent"),
        legend.box.background = element_rect(fill = "transparent"),
        panel.background = element_rect(fill = "transparent"),
        panel.grid.major = element_blank(),
        panel.grid.minor = element_blank(),
        plot.background = element_rect(fill = "transparent",
                                       color = NA))

# how many non-empty origins point
sum(origins_distributed$com_num > 0, na.rm = TRUE) 

# write final grid to file
st_write(origins_distributed, "origins_distributed.gpkg", append = FALSE)
