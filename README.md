# Commuting Efficiency and PT Accessibility Deficits in the Poznań Metropolitan Area

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
  PT investment priority typology (implemented in
  `9_analyse_itineraries.R`).

The output of this pipeline supports a manuscript analyzing modal gaps and
PT accessibility deficits in the Poznań metropolitan area, intended for
transport geography and spatial information science audiences.

## Requirements

- **R** (version TBD — specify the version you developed against)
- Key packages:
  - `dplyr`, `ggplot2` — data wrangling and plotting
  - `sf` — spatial data handling
  - `r5r` — multimodal routing (requires Java; see the
    [r5r setup guide](https://ipeagit.github.io/r5r/) for installation
    details)
  - `spdep` — spatial clustering (e.g. LISA)
  - packages used for raster/grid handling (e.g. `terra` or `raster`) —
    specify which

> **Note:** fill in exact package versions (e.g. via `renv::snapshot()` or
> a `sessionInfo()` dump) once the pipeline is stable, so results are
> reproducible.

## Data availability

- **BDOT10k** — Polish national topographic database; access terms TBD
  (state whether raw data is included, downloadable from a public source,
  or restricted).
- **CEIDG** — Polish business registry; access terms TBD.
- **Population data** — source and access terms TBD.

> Specify whether raw input data is included in this repository, provided
> via a separate download link, or restricted due to licensing.

## Repository structure

```
├── 1_calculate_workplaces.R
├── 2_distribute_population.R
├── 3_merge_pop_workplaces.R
├── 4_r5r_route_batch.R
├── 5_read_itineraries.R
├── 6_add_weights_to_itineraries.R
├── 7_explore_travel_ratios.R
├── 8_plot_itineraries.R
├── 9_analyse_itineraries.R
├── 10_OD_comparison.R
├── Data/            <- input and intermediate data (paths TBD)
└── Output/          <- figures, tables, and derived results (paths TBD)
```

> Adjust the tree above to match your actual folder layout, and confirm
> the `Data/`/`Output/` paths scripts read from and write to.

## Workflow

The scripts are numbered in execution order and form a single end-to-end
pipeline, from raw spatial/population inputs to the final PT vs. car
comparison and priority analysis.

1. **`1_calculate_workplaces.R`** — Derives workplace counts/surfaces from
   source data (BDOT10k/CEIDG), producing the workplace layer used
   downstream for weighting.
   *Output: TBD (e.g. workplace surface as CSV/RDS/raster)*
2. **`2_distribute_population.R`** — Distributes working-age population
   across the spatial grid (120 m raster cells).
   *Output: TBD*
3. **`3_merge_pop_workplaces.R`** — Merges the population and workplace
   layers into a single origin/destination base dataset.
   *Output: TBD*
4. **`4_r5r_route_batch.R`** — Runs batch multimodal routing (r5r) across
   municipalities, generating PT and car itineraries for each OD pair.
   *Output: TBD (raw routing results per municipality)*
5. **`5_read_itineraries.R`** — Reads and consolidates the raw routing
   output into a single itineraries dataset.
   *Output: TBD (e.g. `itineraries.csv`)*
6. **`6_add_weights_to_itineraries.R`** — Attaches population/workplace
   weights to each itinerary for later aggregation.
   *Output: TBD (e.g. `itineraries_weights.csv`)*
7. **`7_explore_travel_ratios.R`** — Exploratory analysis of PT/car travel
   time ratios: population-weighted distributions, rail vs. non-rail
   comparison, competitive vs. improvement-needed itineraries.
8. **`8_plot_itineraries.R`** — Generates map-based visualizations of
   itineraries and travel time ratios.
9. **`9_analyse_itineraries.R`** — Further statistical analysis of
   itinerary-level results, including modal gap measures, PT deficit
   classification, and the multi-dimensional PT investment priority
   typology.
10. **`10_OD_comparison.R`** — Standalone comparison of PT vs. car OD
    travel times across counties near Poznań.

### Running the pipeline

Scripts are intended to be run in numeric order, as each stage depends on
outputs from the previous one:

```
1 → 2 → 3 → 4 → 5 → 6 → {7, 8, 9} → 10
```

Steps 7–9 are exploratory/analytical and can be run independently once
step 6 has produced the weighted itineraries dataset. Step 10 is a
standalone analysis and does not depend on steps 1–9.

## Citation

If you use this repository or its outputs, please cite:

> [Manuscript citation — TBD, forthcoming]

## License

[TBD — specify a license, e.g. MIT for code, and note any restrictions on
redistributing input data]

## Contact

[Maintainer name / email / affiliation — TBD]
