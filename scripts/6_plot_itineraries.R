library(dplyr)
library(sf)
library(ggplot2)
library(terra)
library(patchwork)

setwd("/Users/wozni/Google Drive/UAM/HUB/MobilityPatterns/Data")

pt <- st_read("pt_itineraries_rokietnica.gpkg")
car <- st_read("car_itineraries_Rokietnica.gpkg")

pit <- st_transform(pt, 3857)  # metric CRS
cit <- st_transform(car, 3857)  

# column to sum frequencies
pit$freq <- 1
cit$freq <- 1


# convert to raster
vpit <- vect(pit)
vcit <- vect(cit)

rpit <- rast(
  ext(vpit),
  resolution = 120
)

rcit <- rast(
  ext(vcit),
  resolution = 120 
)

# sum frequencies for each cell
rpit_flow <- rasterize(vpit, rpit, field = "freq", fun = "sum", background = NA)
rcit_flow <- rasterize(vcit, rcit, field = "freq", fun = "sum", background = NA)

df_pit <- as.data.frame(rpit_flow, xy = TRUE)
df_cit <- as.data.frame(rcit_flow, xy = TRUE)

# plot
pt_iti <- ggplot(df_pit) +
  geom_raster(aes(x = x, y = y, fill = log1p(freq))) +
  scale_fill_viridis_c(option = "viridis", na.value = "black") +
  coord_equal() +
  theme_dark(base_size = 14) +
  ggtitle("Public transport") +
  
  theme(
    panel.background = element_rect(fill = "#1a1a1a"),
    plot.background  = element_rect(fill = "#1a1a1a"),
    legend.background = element_rect(fill = "#1a1a1a"),
    legend.key = element_rect(fill = "#1a1a1a"),
    
    text = element_text(color = "white"),
    axis.text = element_blank(),
    axis.title = element_blank(),
    
    legend.title = element_text(size = 14, color = "white"),
    legend.text  = element_text(size = 14, color = "white"),
    
    panel.grid.major = element_blank(),
    panel.grid.minor = element_blank()
  )


car_iti <- ggplot(df_cit) +
  geom_raster(aes(x = x, y = y, fill = log1p(freq))) +
  scale_fill_viridis_c(option = "viridis", na.value = "black") +
  coord_equal() +
  theme_dark(base_size = 14) +
  ggtitle("Cars") +
  
  theme(
    panel.background = element_rect(fill = "#1a1a1a"),
    plot.background  = element_rect(fill = "#1a1a1a"),
    legend.background = element_rect(fill = "#1a1a1a"),
    legend.key = element_rect(fill = "#1a1a1a"),
    
    text = element_text(color = "white"),
    axis.text = element_blank(),
    axis.title = element_blank(),
    
    legend.title = element_text(size = 14, color = "white"),
    legend.text  = element_text(size = 14, color = "white"),
    
    panel.grid.major = element_blank(),
    panel.grid.minor = element_blank()
  )

# merge plots
pt_iti + car_iti
