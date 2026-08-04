# =============================================================================
# 11b_town_rural_validation_chart.R
#
# Turns the town/rural under-prediction pattern already reported in prose
# (main.tex, Validation subsection) into a paired slope chart: for each of
# the seven ring municipalities administratively split into a miasto (town)
# and obszar wiejski (rural) unit, plots the observed/predicted share ratio
# for both units side by side, connected by a line, so the "rural exceeds
# town in all seven pairs" claim is visible at a glance rather than only
# readable as a list of numbers.
#
# INPUT  : od_validation_neighborhood_to_core.csv (from 11_validate_od_flows.R)
# OUTPUT : Figures/Fig_od_validation_town_rural.png
# =============================================================================

library(tidyverse)
library(ggrepel)

setwd("C:/Users/wozni/Google Drive/UAM/HUB/MobilityPatterns/Data")
dir.create("../Figures", showWarnings = FALSE)

comparison <- read.csv("od_validation_neighborhood_to_core.csv", stringsAsFactors = FALSE)
matched <- comparison %>% filter(!is.na(synthetic_volume), !is.na(commuters))

total_commuters <- sum(matched$commuters, na.rm = TRUE)
total_synth     <- sum(matched$synthetic_volume, na.rm = TRUE)

pairs <- c("Kórnik", "Kostrzyn", "Mosina", "Murowana Goślina", "Pobiedziska", "Stęszew", "Swarzędz")

plot_data <- matched %>%
  mutate(
    census_share = commuters / total_commuters,
    synth_share  = synthetic_volume / total_synth,
    ratio = census_share / synth_share,
    base = str_remove(home_municipality, " - (miasto|obszar wiejski)$"),
    unit_type = case_when(
      str_detect(home_municipality, "miasto$") ~ "Town",
      str_detect(home_municipality, "obszar wiejski$") ~ "Rural",
      TRUE ~ NA_character_
    )
  ) %>%
  filter(base %in% pairs, !is.na(unit_type)) %>%
  select(base, unit_type, ratio)

cat("Town/rural ratio pairs:\n")
print(as.data.frame(plot_data))

ggplot(plot_data, aes(x = unit_type, y = ratio, group = base)) +
  geom_hline(yintercept = 1, linetype = "dashed", colour = "grey50") +
  geom_line(colour = "grey60", linewidth = 0.7) +
  geom_point(aes(colour = unit_type), size = 4) +
  geom_text_repel(
    data = plot_data %>% filter(unit_type == "Rural"),
    aes(label = base), hjust = 1, direction = "y", nudge_x = -0.15,
    segment.color = "grey70", size = 6.5, colour = "grey20", seed = 1
  ) +
  scale_colour_manual(values = c("Town" = "#2c7fb8", "Rural" = "#d95f0e"), guide = "none") +
  scale_x_discrete(expand = expansion(add = c(0.9, 0.3))) +
  scale_y_continuous(breaks = scales::pretty_breaks()) +
  labs(x = NULL, y = "Observed / predicted share ratio") +
  theme_minimal(base_size = 17) +
  theme(
    axis.title = element_text(size = 19),
    axis.text  = element_text(size = 17),
    panel.grid.minor = element_blank()
  )

ggsave("../Figures/Fig_od_validation_town_rural.png", width = 7.5, height = 6.5, dpi = 300)
cat("Saved Figures/Fig_od_validation_town_rural.png\n")
