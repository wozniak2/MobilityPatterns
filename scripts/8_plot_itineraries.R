library(dplyr)
library(sf)
library(ggplot2)
library(terra)
library(patchwork)

# !!! This script requires the 'results' object produced by '5_read_itineraries.R' !!!

setwd("/Users/wozni/Google Drive/UAM/HUB/MobilityPatterns/Data")

# ── Aggregate PT and Car rasters for visualisation ───────────────────────────

aggregate_flow_raster <- function(df, cell_size, fact = 3, crs_in = 3857) {
  
  pts <- df %>% st_as_sf(coords = c("x", "y"), crs = crs_in)
  
  r_template <- rast(
    ext        = ext(vect(pts)),
    resolution = cell_size,
    crs        = paste0("EPSG:", crs_in)
  )
  
  r_raw <- rasterize(vect(pts), r_template, 
                     field = "freq", fun = "sum", background = NA)
  r_agg <- aggregate(r_raw, fact = fact, fun = "sum")
#  r_wgs <- project(r_agg, "EPSG:4326")
  
  as.data.frame(r_agg, xy = TRUE) %>%
    rename(freq = sum) %>%
    filter(!is.na(freq))
}


# Combine counties & compute log-frequency difference ───────────────────
df_cit <- map_dfr(results, ~ .x$df_cit)
df_pit <- map_dfr(results, ~ .x$df_pit)

# ── Run for both modes ────────────────────────────────────────────────────────
df_plot_pt  <- aggregate_flow_raster(df_pit, cell_size, fact = 1)
df_plot_car <- aggregate_flow_raster(df_cit, cell_size, fact = 1)


poz_3857 <- st_transform(poz, crs = 3857)

# plot
pt_iti <- ggplot(df_plot_pt) +
  geom_raster(aes(x = x, y = y, fill = log1p(freq))) +
  scale_fill_viridis_c(option = "viridis", na.value = "black") +
  coord_equal() +
  geom_sf(data = poz_3857, fill = NA, colour = "red",
          linewidth = 0.4, inherit.aes = FALSE) +
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


car_iti <- ggplot(df_plot_car) +
  geom_raster(aes(x = x, y = y, fill = log1p(freq))) +
  scale_fill_viridis_c(option = "viridis", na.value = "black") +
  coord_equal() +
  geom_sf(data = poz_3857, fill = NA, colour = "red",
          linewidth = 0.4, inherit.aes = FALSE) +
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
require(patchwork)
pt_iti + car_iti

ggsave("Fig_cars_pt_itineraries.png", width = 12, height = 9, dpi = 300)
