## Commuting Efficiency and Spatial Inequalities in European Cities: An Open-Data Framework for Evaluating Sustainable Mobility

## About this repository

This repository contains the data processing and analysis pipeline for a
study of public transport (PT) accessibility deficits in the Poznań
metropolitan area, Poland. The project compares PT and car travel times
across the region to identify where public transport is competitive with
private car travel, where it lags significantly, and which areas should
be prioritized for PT investment.

The core workflow combines:

- **Workplace surfaces** derived from BDOT10k topographic data and CEIDG
  business registry records, used to estimate the spatial distribution of
  employment.
- **Working-age population** distributed across a fine-grained spatial
  grid (120 m resolution).
- **Multimodal routing** via [r5r](https://github.com/ipeaGIT/r5r), run in
  batch across municipalities in the Poznań metropolitan area, to generate
  comparable PT and car itineraries for origin–destination pairs.
- **Travel time ratio analysis**, weighting itinerary-level PT/car
  comparisons by population and workplace counts to identify areas of PT
  competitiveness versus deficit.
- **Spatial classification and clustering** (e.g. LISA) to characterize
  the spatial structure of PT deficits and to support a multi-dimensional
  PT investment priority typology.

The output of this pipeline supports a manuscript analyzing modal gaps and
PT accessibility deficits in the Poznań metropolitan area, intended for
transport geography and spatial information science audiences.

### Repository structure

Numbered R scripts (`1_...` through `10_...`) form the main pipeline, run
roughly in sequence — see [Workflow](#workflow) below for details on each
stage and its dependencies.

## Workflow

The scripts are numbered in execution order and form a single end-to-end
pipeline, from raw spatial/population inputs to the final PT vs. car
comparison and priority analysis.

1. **`1_calculate_workplaces.R`** — Derives workplace counts/surfaces from
   source data (e.g. BDOT10k/CEIDG), producing the workplace layer used
   downstream for weighting.
2. **`2_distribute_population.R`** — Distributes working-age population
   across the spatial grid (e.g. 120 m raster cells).
3. **`3_merge_pop_workplaces.R`** — Merges the population and workplace
   layers into a single origin/destination base dataset.
4. **`4_r5r_route_batch.R`** — Runs batch multimodal routing (r5r) across
   municipalities, generating PT and car itineraries for each OD pair.
5. **`5_read_itineraries.R`** — Reads and consolidates the raw routing
   output into a single itineraries dataset.
6. **`6_add_weights_to_itineraries.R`** — Attaches population/workplace
   weights to each itinerary for later aggregation.
7. **`7_explore_travel_ratios.R`** — Exploratory analysis of PT/car travel
   time ratios: population-weighted distributions, rail vs. non-rail
   comparison, competitive vs. improvement-needed itineraries.
8. **`8_plot_itineraries.R`** — Generates map-based visualizations of
   itineraries and travel time ratios.
9. **`9_analyse_itineraries.R`** — Further statistical analysis of
   itinerary-level results (e.g. modal gap measures, deficit
   classification).
10. **`10_OD_comparison.R`** — Standalone comparison of PT vs. car OD
    travel times across counties near Poznań.

### Running the pipeline

Scripts are intended to be run in numeric order, as each stage depends on
outputs from the previous one:

1 → 2 → 3 → 4 → 5 → 6 → {7, 8, 9} → 10
