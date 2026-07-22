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
  grid (200 m resolution).
- **Multimodal routing** via [r5r](https://github.com/ipeaGIT/r5r), run in
  batch across municipalities in the Poznań metropolitan area, to generate
  comparable PT and car itineraries for origin–destination pairs.
- **Travel time ratio analysis**, weighting itinerary-level PT/car
  comparisons by population and workplace counts to identify areas of PT
  competitiveness versus deficit.
- **Spatial classification and clustering** (LISA) to characterize the
  spatial structure of PT deficits and to support a multi-dimensional PT
  investment priority typology (implemented in `9_analyse_itineraries.R`
  and `10_OD_comparison.R`, sharing logic from `lisa_priority_utils.R`).

The output of this pipeline supports a manuscript analyzing modal gaps and
PT accessibility deficits in the Poznań metropolitan area, intended for
transport geography and spatial information science audiences.

## Requirements

- **R** (version TBD — specify the version you developed against)
- Key packages:
  - `dplyr`, `tidyverse`, `ggplot2`, `patchwork`, `ggnewscale` — data
    wrangling and plotting
  - `sf`, `terra` — spatial/raster data handling
  - `osmdata` — OSM boundary/road/POI queries (live Overpass API calls)
  - `r5r` (+ `rJavaEnv`) — multimodal routing (requires Java 21; see the
    [r5r setup guide](https://ipeagit.github.io/r5r/) for installation
    details)
  - `spdep` — spatial clustering (LISA)
  - `tidytransit` — GTFS feed parsing
  - `maptiles`, `tidyterra` — basemap tiles for final figures (live tile
    server requests)
  - `data.table` — fast grouping in `6_add_weights_to_itineraries.R`
  - `scales` — axis/label formatting in `10_OD_comparison.R`

> **Note:** fill in exact package versions (e.g. via `renv::snapshot()` or
> a `sessionInfo()` dump) once the pipeline is stable, so results are
> reproducible. Steps that call the public Overpass API or basemap tile
> servers (`osmdata`, `maptiles`) are not reproducible offline and depend
> on those services' availability.

## Data availability

- **BDOT10k** — Polish national topographic database; access terms TBD
  (state whether raw data is included, downloadable from a public source,
  or restricted). Used as `Data/work_bdot.gpkg`.
- **CEIDG** — Polish business registry; access terms TBD. Used as
  `Data/ceidg_geocode.csv`.
- **Population data** — source and access terms TBD. Used as
  `Data/pop_geocoded.csv`.
- **GTFS feeds** — one or more `.zip` feeds for the region's PT operators,
  placed under `Data/gtfs/`.
- **r5r routing inputs** (OSM extract `.pbf` + GTFS feeds) — placed under
  `Data/routing/`, per the
  [r5r data requirements](https://ipeagit.github.io/r5r/articles/prepare_inputs_r5r.html).
- **Administrative boundaries** — `Data/ap.gpkg` (Poznań agglomeration),
  `Data/poz.gpkg` (surrounding "donut" of counties), and optionally
  `Data/boundary.gpkg` (Poznań city; fetched from OSM automatically by
  `1_calculate_workplaces.R` if not present).
- **OD flow data** — `Data/OD_flows.csv`, joined to `ap.gpkg` by `JPT_ID`
  in `3_merge_pop_workplaces.R`.

> Specify whether raw input data is included in this repository, provided
> via a separate download link, or restricted due to licensing.

## Repository structure

```
scripts/
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
└── lisa_priority_utils.R   <- shared helpers sourced by 9 and 10
Data/            <- input and intermediate data (see "Data availability")
Output/          <- figures, tables, and derived results (paths TBD)
```

> Adjust the tree above to match your actual folder layout, and confirm
> the `Data/`/`Output/` paths scripts read from and write to.

## Running the pipeline

All scripts assume the **working directory is the repository root** when
launched (e.g. open an RStudio project at the repo root, or run
`Rscript scripts/<name>.R` from the top level) — each script's first line
of substance is `setwd("Data")`, so all file paths inside a script are
relative to `Data/`.

### Dependency graph

```
1 ─┐
   ├─→ 4 → 5 → 6 → 7
2 ─┘        │    └─→ (standalone exploration)
            ├─→ 8
            └─→ 9 ─┐
                    │  (both source lisa_priority_utils.R)
3 (diagnostic, reads outputs of 1 & 2, not required by 4)

10 is standalone: rereads itineraries + GTFS + pop_grid from disk directly,
independent of scripts 5-9.
```

Note that **3 is not on the critical path to 4** — routing in step 4 reads
`pop_grid.gpkg`/`workplace_grid.gpkg` directly from steps 1–2. Step 3
produces a diagnostic combined grid (`pop_workplaces_grid.gpkg`,
`pop_wp_flows_grid.gpkg`) and introductory figures; run it whenever you
want those, but it does not block later steps.

**5 → {6, 8, 9} is now file-based, not session-based.** Step 5 rasterizes
and consolidates the raw per-municipality itinerary files and writes
`itineraries_results.rds`, `pt_itineraries.rds`, and `car_itineraries.rds`
to `Data/`. Steps 6, 8, and 9 each `readRDS()` those files at the top, so
they can be run independently in fresh R sessions, in any order relative
to each other, as long as step 5 has run at least once.

1. **`1_calculate_workplaces.R`** — Derives a 200 m workplace grid from
   BDOT10k building floor area (`work_bdot.gpkg`) and CEIDG small-business
   counts (`ceidg_geocode.csv`), weighted and scaled to the city's total
   workplace count.
   *Output: `workplace_grid.gpkg`*
2. **`2_distribute_population.R`** — Distributes working-age population
   across a 200 m grid, clipped to municipality boundaries.
   *Output: `pop_grid.gpkg`*
3. **`3_merge_pop_workplaces.R`** — Spatially joins the population and
   workplace grids into one combined dataset and produces introductory
   figures (population/workplace density, OD commuter flows). Diagnostic
   step, not required by routing.
   *Output: `pop_workplaces_grid.gpkg`, `pop_wp_flows_grid.gpkg`, `OD_sf.gpkg`*
4. **`4_r5r_route_batch.R`** — Runs batch multimodal routing (r5r) across
   municipalities, generating PT and car itineraries for each OD pair
   above population/workplace cutoffs.
   *Output: `itineraries/{pt,car}_itineraries_<municipality>.gpkg`*
5. **`5_read_itineraries.R`** — Reads and consolidates the raw routing
   output into combined itineraries datasets, and rasterizes per-county
   flow density at 120 m for later mapping.
   *Output: `itineraries_results.rds`, `pt_itineraries.rds`, `car_itineraries.rds`*
6. **`6_add_weights_to_itineraries.R`** — Attaches population/workplace
   weights to each itinerary for later aggregation.
   *Output: `itineraries_weights.csv`*
7. **`7_explore_travel_ratios.R`** — Exploratory analysis of PT/car travel
   time ratios: population-weighted distributions, rail vs. non-rail
   comparison, competitive vs. improvement-needed itineraries.
8. **`8_plot_itineraries.R`** — Generates map-based visualizations of
   itinerary flow density for PT vs. car.
   *Output: `Fig_cars_pt_itineraries.png`*
9. **`9_analyse_itineraries.R`** — LISA clustering of car-vs-PT flow
   density, PT-accessibility classification against GTFS stop frequency,
   and the multi-dimensional PT investment priority typology.
   *Output: `Fig_PT_investment_priority.png`*
10. **`10_OD_comparison.R`** — Standalone, from-scratch OD travel-time
    comparison (PT vs. car) across counties near Poznań, reusing the same
    LISA/priority classification helpers as step 9.
    *Output: `Fig_PT_vs_car_travels.png`, `Fig_PT_vs_car_travels_HEX.png`,
    `Fig_PT_vs_car_travels_by_origin.png`*

Steps 7–9 are exploratory/analytical and can be run independently once
step 6 (for 7) or step 5 (for 8, 9) has produced its output. Step 10 is
fully standalone and does not depend on steps 1–9.

## Citation

If you use this repository or its outputs, please cite:

> [Manuscript citation — TBD, forthcoming]

## License

[TBD — specify a license, e.g. MIT for code, and note any restrictions on
redistributing input data]

## Contact

[Maintainer name / email / affiliation — TBD]
