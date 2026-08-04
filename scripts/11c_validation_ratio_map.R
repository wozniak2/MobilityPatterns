# =============================================================================
# 11c_validation_ratio_map.R
#
# Municipality-level choropleth of the observed/predicted commuting-share
# ratio already reported in the Validation subsection (main.tex) and plotted
# as a slope chart for the 7 town/rural pairs in 11b_town_rural_validation_chart.R.
# This version shows all M=24 matched municipalities spatially, using the
# same ring-municipality polygons the validation script itself already loads
# (ap.gpkg/poz.gpkg) for a completely different purpose (assigning origins to
# municipalities) -- they were never used for display before.
#
# INPUT  : od_validation_neighborhood_to_core.csv (from 11_validate_od_flows.R)
#          ap.gpkg (ring municipalities), poz.gpkg (Poznan core city)
# OUTPUT : Figures/Fig_od_validation_ratio_map.png
# =============================================================================

library(sf)
library(tidyverse)

setwd("C:/Users/wozni/Google Drive/UAM/HUB/MobilityPatterns/Data")
dir.create("../Figures", showWarnings = FALSE)

normalize_name <- function(x) x %>% str_trim() %>% str_squish()
strip_admin_suffix <- function(x) str_remove(x, "\\s*-\\s*gmina (miejska|wiejska)$")

ap  <- st_read("ap.gpkg", quiet = TRUE)
poz <- st_read("poz.gpkg", quiet = TRUE)
municipalities <- bind_rows(ap, poz) %>%
  mutate(muni_name = normalize_name(strip_admin_suffix(JPT_NAZWA_))) %>%
  st_transform(4326)

comparison <- read.csv("od_validation_neighborhood_to_core.csv", stringsAsFactors = FALSE)
matched <- comparison %>% filter(!is.na(synthetic_volume), !is.na(commuters))

total_commuters <- sum(matched$commuters, na.rm = TRUE)
total_synth     <- sum(matched$synthetic_volume, na.rm = TRUE)

ratios <- matched %>%
  mutate(
    census_share = commuters / total_commuters,
    synth_share  = synthetic_volume / total_synth,
    ratio        = census_share / synth_share
  ) %>%
  select(muni_name = home_municipality, ratio)

map_data <- municipalities %>% left_join(ratios, by = "muni_name")

cat("Municipalities with a ratio:", sum(!is.na(map_data$ratio)),
    "| without (excluded from M=24, incl. core):", sum(is.na(map_data$ratio)), "\n")

poz_wgs <- st_transform(poz, 4326)

ggplot(map_data) +
  geom_sf(aes(fill = ratio), colour = "grey30", linewidth = 0.15) +
  geom_sf(data = poz_wgs, fill = NA, colour = "white", linewidth = 0.7) +
  scale_fill_gradient2(
    low = "#2c7fb8", mid = "white", high = "#d95f0e", midpoint = 1,
    na.value = "grey40",
    name = "Observed /\npredicted\nshare ratio"
  ) +
  coord_sf(crs = 4326) +
  theme_dark(base_size = 18) +
  theme(
    panel.background  = element_rect(fill = "#1a1a1a"),
    plot.background   = element_rect(fill = "#1a1a1a"),
    legend.background = element_rect(fill = "#1a1a1a"),
    legend.key        = element_rect(fill = "#1a1a1a"),
    text              = element_text(color = "white"),
    axis.text         = element_blank(),
    axis.title        = element_blank(),
    legend.title      = element_text(size = 17, color = "white"),
    legend.text       = element_text(size = 16, color = "white"),
    panel.grid.major  = element_blank(),
    panel.grid.minor  = element_blank()
  )

ggsave("../Figures/Fig_od_validation_ratio_map.png", width = 9, height = 7, dpi = 300)
cat("Saved Figures/Fig_od_validation_ratio_map.png\n")
