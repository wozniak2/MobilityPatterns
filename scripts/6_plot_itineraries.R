library(dplyr)
library(sf)
# library(spatstat)
library(ggplot2)
library(digest)

setwd("/Users/wozni/Google Drive/UAM/HUB/MobilityPatterns/Data")

pt <- st_read("pt_itineraries_rokietnica.gpkg")
car <- st_read("car_itineraries_Rokietnica.gpkg")

pit <- st_transform(pt, 3857)  # metric CRS
cit <- st_transform(car, 3857)  

# snap to 10-meter precision and convert to WKB and hash for faster computing
# public transportation
pit_snap <- st_set_precision(pit, 10)
pit_snap <- st_make_valid(pit_snap)
#it_snap$geom_id <- st_as_text(it_snap$geom)
pit_snap$geom_id <- vapply(
  st_as_binary(pit_snap$geom),
  digest,
  character(1)
)

# cars
cit_snap <- st_set_precision(cit, 10)
cit_snap <- st_make_valid(cit_snap)
cit_snap$geom_id <- vapply(
  st_as_binary(cit_snap$geom),
  digest,
  character(1)
)

# count frequency of road segments for public transport
pt_segment_freq <- pit_snap %>%
  group_by(geom_id) %>%
  summarise(
    n = n(),
    geometry = first(geom)
  ) %>%
  st_as_sf()

# simplify feature for faster plotting
pt_segment_freq_s <- st_simplify(pt_segment_freq, dTolerance = 15)

# count frequency of road segments for cars (max freq is 4!!)
car_segment_freq <- cit_snap %>%
  group_by(geom_id) %>%
  summarise(
    n = n(),
    geometry = first(geom)
  ) %>%
  st_as_sf()

# simplify feature for faster plotting
car_segment_freq_s <- st_simplify(car_segment_freq, dTolerance = 15)

# plot public transportation segments frequencies
ggplot(pt_segment_freq_s) +
  geom_sf(aes(color = n), lwd = 1, alpha = 0.8) +
  scale_color_viridis_c(trans = "log") +
  theme_dark(base_size = 14) +
  theme(
    panel.background = element_rect(fill = "#1a1a1a"),
    plot.background  = element_rect(fill = "#1a1a1a"),
    legend.background = element_rect(fill = "#1a1a1a"),
    legend.key = element_rect(fill = "#1a1a1a"),
    
    text = element_text(color = "white"),
    axis.text = element_text(color = "white"),
    axis.title = element_text(color = "white"),
    
    legend.title = element_text(size = 14, color = "white"),
    legend.text  = element_text(size = 14, color = "white"),
    
    panel.grid.major = element_line(color = "grey30"),
    panel.grid.minor = element_line(color = "grey20")
  )

# plot car segments frequencies
ggplot(car_segment_freq_s) +
  geom_sf(aes(color = n), lwd = 1, alpha = 0.8) +
  scale_color_viridis_c() +
#  scale_size(range = c(0.3, 4), trans = "log") +
  theme_dark(base_size = 14) +
  theme(
    panel.background = element_rect(fill = "#1a1a1a"),
    plot.background  = element_rect(fill = "#1a1a1a"),
    legend.background = element_rect(fill = "#1a1a1a"),
    legend.key = element_rect(fill = "#1a1a1a"),
    
    text = element_text(color = "white"),
    axis.text = element_text(color = "white"),
    axis.title = element_text(color = "white"),
    
    legend.title = element_text(size = 14, color = "white"),
    legend.text  = element_text(size = 14, color = "white"),
    
    panel.grid.major = element_line(color = "grey30"),
    panel.grid.minor = element_line(color = "grey20")
  )

# alternative: tmap should be even a little faster
library(tmap)
tm_shape(car_segment_freq_s) +
  tm_lines(col = "n", palette = "viridis")

## require(patchwork)
## cit_plot + it_plot
  