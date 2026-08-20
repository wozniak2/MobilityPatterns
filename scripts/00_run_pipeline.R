# =============================================================================
# 00_run_pipeline.R
#
# Runs the full MobilityPatterns pipeline end-to-end in one execution, in
# dependency order (01-13, which already matches the dependency graph in
# README.md -- see "Dependency graph" section there). Each step runs in its
# own fresh Rscript process rather than being source()'d into this session:
# the pipeline is explicitly file-based, not session-based (every script
# readRDS()/st_read()s its inputs from Data/ and writes its outputs back),
# and isolating each step in its own process also avoids cross-script
# package conflicts that have bitten this repo before (e.g. dplyr::recode()
# vs. car::recode() colliding if both stayed attached in one long session).
#
# Steps 01-05 (workplace/population grids, r5r multimodal routing, itinerary
# consolidation) are the expensive, one-time "data prep" phase -- step 04 in
# particular is a multi-hour r5r batch routing job requiring Java 21 and raw
# OSM/GTFS inputs. Steps 06-12 are the actual analysis: figures, tables,
# regression, validation -- this is what "get all outcomes" means day to
# day, and they always run.
#
# Default (smart) behaviour: if Data/itineraries_results.rds,
# pt_itineraries.rds and car_itineraries.rds all already exist, phase A
# (steps 01-05) is assumed done and SKIPPED entirely; only phase B (06-12)
# runs. Pass --force to redo phase A from scratch regardless (this can take
# hours because of step 04 -- make sure that's actually what you want).
#
# Usage:
#   Rscript 00_run_pipeline.R            # smart mode (recommended day to day)
#   Rscript 00_run_pipeline.R --force    # also rerun 01-05 from scratch
#
# Nothing is captured or hidden -- each step's own console output streams
# through live, since several steps run for minutes and you'll want to see
# progress as it happens. A PASS/FAIL/SKIPPED summary with per-step timings
# prints at the end.
# =============================================================================

SCRIPTS_DIR <- "C:/Users/wozni/OneDrive/Documents/GitHub/MobilityPatterns/scripts"
DATA_DIR    <- "C:/Users/wozni/Google Drive/UAM/HUB/MobilityPatterns/Data"
RSCRIPT_EXE <- "C:/Program Files/R/R-4.4.1/bin/Rscript.exe"  # has `sf` etc. -- NOT the newer R-4.6.0 install

force_all <- "--force" %in% commandArgs(trailingOnly = TRUE)

phase_a_steps <- c(
  "01_calculate_workplaces.R",
  "02_distribute_population.R",
  "03_merge_pop_workplaces.R",
  "04_r5r_route_batch.R",
  "05_read_itineraries.R"
)
phase_b_steps <- c(
  "06_travel_ratio_analysis.R",
  "07_plot_itineraries.R",
  "08_analyse_itineraries.R",
  "09_OD_comparison.R",
  "10_regression_analysis.R",
  "11_validate_od_flows.R",
  "12_spatial_regression_comparison.R",
  "13_gwr_analysis.R"
)

phase_a_markers <- file.path(DATA_DIR, c(
  "itineraries_results.rds", "pt_itineraries.rds", "car_itineraries.rds"
))
phase_a_done <- all(file.exists(phase_a_markers))

run_list <- character(0)
if (force_all || !phase_a_done) {
  run_list <- c(run_list, phase_a_steps)
} else {
  cat("Phase A (steps 01-05: grids + routing + consolidation) already complete\n")
  cat("-- skipping. Pass --force to redo it from scratch (step 04 alone can\n")
  cat("take hours). Proceeding straight to the analysis steps (06-12).\n")
}
run_list <- c(run_list, phase_b_steps)

results <- data.frame(step = character(), status = character(),
                       seconds = numeric(), stringsAsFactors = FALSE)

regression_data_csv <- file.path(DATA_DIR, "regression_data.csv")

for (step_file in run_list) {
  label <- paste0("Step ", substr(step_file, 1, 2), ": ", step_file)

  # 12 and 13 both aggregate step 10's output -- if 10 didn't produce it
  # (e.g. it failed), there's no point trying to run either at all.
  if (step_file %in% c("12_spatial_regression_comparison.R", "13_gwr_analysis.R") &&
      !file.exists(regression_data_csv)) {
    cat("\n", label, "\n", sep = "")
    cat("SKIPPED -- required input missing:", regression_data_csv, "\n")
    results <- rbind(results, data.frame(
      step = label, status = "SKIPPED (missing input)", seconds = 0
    ))
    next
  }

  cat("\n==================================================================\n")
  cat(label, "\n")
  cat("==================================================================\n")

  script_path <- file.path(SCRIPTS_DIR, step_file)
  t0 <- Sys.time()
  exit_code <- system2(RSCRIPT_EXE, args = script_path)
  elapsed <- as.numeric(difftime(Sys.time(), t0, units = "secs"))

  status <- if (identical(exit_code, 0L)) "OK" else paste0("FAILED (exit ", exit_code, ")")
  cat(sprintf("\n%s -- %s in %.1fs\n", label, status, elapsed))
  results <- rbind(results, data.frame(
    step = label, status = status, seconds = round(elapsed, 1)
  ))
}

cat("\n\n================== PIPELINE SUMMARY ==================\n")
print(results, row.names = FALSE)

if (any(grepl("^FAILED", results$status))) {
  cat("\nOne or more steps failed -- see the console output above for the\n")
  cat("actual R error (printed live, in place, by that step).\n")
  quit(status = 1)
}
