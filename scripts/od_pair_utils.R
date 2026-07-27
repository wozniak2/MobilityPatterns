# =============================================================================
# od_pair_utils.R
#
# NOT a standalone script — do not run this file directly, it has no
# executable top level (only library() calls and a function definition).
#
# Shared helper for collapsing the raw, segment-level itineraries produced
# by 05_read_itineraries.R (pt_itineraries.rds, car_itineraries.rds) down
# to one row per OD pair with a PT/car travel-time comparison. Used by
# 06_travel_ratio_analysis.R, 07_plot_itineraries.R, 09_OD_comparison.R,
# and 10_regression_analysis.R, which previously each re-implemented this
# same collapsing step independently (with minor, accidental
# inconsistencies between copies — see the 2026-07-27 deduplication note
# in each of those scripts' headers). Each of those scripts loads it via
# source("<path to this file>") near the top — just run them as normal,
# you never need to source this yourself.
#
# REQUIRES AS INPUT: pt_itineraries.rds and car_itineraries.rds, both
# written by 05_read_itineraries.R — run that script first if either file
# is missing from the working directory.
# =============================================================================

library(dplyr)
library(sf)

#' Collapse raw PT and car itineraries to one row per OD pair and compute
#' the PT/car travel-time ratio.
#'
#' Returns one row per (from_id, to_id) pair present in BOTH pt_itineraries
#' and car_itineraries (inner join — an OD pair routable in only one mode
#' cannot be compared), with columns:
#'   from_id, to_id, from_lon, from_lat, to_lon, to_lat, county  (identifiers,
#'     taken from the PT side; county is assigned identically on both sides
#'     by 05_read_itineraries.R, so either would do)
#'   pt_duration_min, pt_distance_m, n_transfers, has_rail, modes  (PT side)
#'   car_duration_min, car_distance_m                              (car side)
#'   tt_ratio, tt_diff, dist_ratio                                  (PT/car comparison)
#'   competitive  (four-band factor: "PT faster" / "Comparable (< 1.5x)" /
#'     "PT slower (1.5–2x)" / "PT much slower (> 2x)")
#'
#' Callers that don't need every column (e.g. 07_plot_itineraries.R doesn't
#' use has_rail/modes/dist_ratio) can simply ignore the extras — carrying
#' a few unused columns through is harmless and keeps this function usable
#' by all four callers without a parametrised subset.
#'
#' @param pt_itineraries  sf/tibble of PT itinerary segments (one row per
#'   segment; must have from_id, to_id, from_lon, from_lat, to_lon, to_lat,
#'   county, total_duration, total_distance, segment, mode).
#' @param car_itineraries sf/tibble of car itinerary segments (from_id,
#'   to_id, total_duration, total_distance).
build_od_comparison <- function(pt_itineraries, car_itineraries) {
  pt_summary <- pt_itineraries %>%
    st_drop_geometry() %>%
    group_by(from_id, to_id, from_lon, from_lat, to_lon, to_lat, county) %>%
    summarise(
      pt_duration_min = min(total_duration, na.rm = TRUE),
      pt_distance_m   = min(total_distance, na.rm = TRUE),
      n_transfers     = max(segment, na.rm = TRUE) - 1,
      has_rail        = any(mode == "RAIL"),
      modes           = paste(unique(mode), collapse = "+"),
      .groups = "drop"
    )

  car_summary <- car_itineraries %>%
    st_drop_geometry() %>%
    group_by(from_id, to_id) %>%
    summarise(
      car_duration_min = min(total_duration, na.rm = TRUE),
      car_distance_m   = min(total_distance, na.rm = TRUE),
      .groups = "drop"
    )

  inner_join(pt_summary, car_summary, by = c("from_id", "to_id")) %>%
    mutate(
      tt_ratio   = pt_duration_min / car_duration_min,
      tt_diff    = pt_duration_min - car_duration_min,
      dist_ratio = pt_distance_m   / car_distance_m,
      competitive = case_when(
        tt_ratio <= 1.0 ~ "PT faster",
        tt_ratio <= 1.5 ~ "Comparable (< 1.5x)",
        tt_ratio <= 2.0 ~ "PT slower (1.5–2x)",
        TRUE            ~ "PT much slower (> 2x)"
      ) %>% factor(levels = c(
        "PT faster", "Comparable (< 1.5x)",
        "PT slower (1.5–2x)", "PT much slower (> 2x)"
      ))
    )
}
