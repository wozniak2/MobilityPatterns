library(sf)

setwd("/Users/wozni/Google Drive/UAM/HUB/MobilityPatterns/Data")

# boundry for Poznan agglomeration
ap <- st_read("ap.gpkg")

# Remove rows with any missing values
pop_geocoded <- pop_geocoded[complete.cases(pop_geocoded$g_dlug), ]

## sf object
pop_geocoded <- st_as_sf(
  pop_geocoded,
  coords = c("g_dlug", "g_szer"),
  crs = 4326
)

## plot
ggplot()+
  geom_sf(data = pop_geocoded, aes(color = WIEK_26_DO_60), size = 0.3, alpha = 0.2) +
  geom_sf(data = ap, fill = NA) +
  scale_color_viridis_c(n.breaks = 4, begin = 0.2, end = 1)
