setwd("/home/adam/Dokumenty/commuting_patterns")

library(elevatr)
library(rJavaEnv)
library(dplyr)
library(r5r)
library(sf)
library(tidyr)
library(tmap)


# =============================================================================
# LOAD SHARED DATA ONCE
# =============================================================================

message("Reading origins (pop_grid.gpkg) ...")
origins <- st_read("pop_grid.gpkg", quiet = TRUE)
origins <- st_centroid(origins)
if (st_crs(origins)$epsg != 4326) {
  origins <- st_transform(origins, crs = 4326)
}
origins$id <- seq_len(nrow(origins))

message("Reading destinations (workplace_grid.gpkg) ...")
destinations <- st_read("workplace_grid.gpkg", quiet = TRUE)
destinations <- st_centroid(destinations)
if (st_crs(destinations)$epsg != 4326) {
  destinations <- st_transform(destinations, crs = 4326)
}
destinations$id <- seq_len(nrow(destinations))

# =============================================================================
# CONFIGURATION
# =============================================================================

# List of municipality short names – must match values in the
# municipality_short column of pop_grid.gpkg / workplace_grid.gpkg

unique(pop_grid$municipality)

municipalities <- c(unique(pop_grid$municipality_short))

workplace_cutoff <- 150
pop_cutoff       <- 30

# Output folder for .gpkg files
output_dir <- "./itineraries"
dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)



# =============================================================================
# BUILD NETWORK ONCE
# =============================================================================

use_java(version = "21")
options(java.parameters = "-Xmx16G")

message("Building r5r network ...")
r5r_network <- build_network(data_path = "./routing",
                             elevation = "MINETTI",
                             verbose   = FALSE)
message("Network ready.\n")

# =============================================================================
# MAIN LOOP
# =============================================================================

results_log <- list()

for (muni in municipalities) {
  
  message("\n", strrep("=", 60))
  message("Processing: ", muni)
  message(strrep("=", 60))
  
  out_car <- file.path(output_dir, paste0("car_itineraries_", muni, ".gpkg"))
  out_pt  <- file.path(output_dir, paste0("pt_itineraries_",  muni, ".gpkg"))
  
  # Filter origins & destinations for this municipality
  orig_muni <- subset(origins,      municipality_short == muni & working_age_pop > pop_cutoff)
  dest_muni <- subset(destinations, workplaces > workplace_cutoff)
  
  if (nrow(orig_muni) == 0) {
    warning("No origins found for: ", muni, " - skipping.")
    results_log[[muni]] <- "SKIPPED - no origins after filter"
    next
  }
  if (nrow(dest_muni) == 0) {
    warning("No destinations found after cutoff filter - skipping: ", muni)
    results_log[[muni]] <- "SKIPPED - no destinations after filter"
    next
  }
  
  message("  Origins: ", nrow(orig_muni), " | Destinations: ", nrow(dest_muni))
  
  tryCatch({
    
    # 1. CAR itineraries
    message("  Calculating CAR itineraries ...")
    system.time(
      itineraries_car <- detailed_itineraries(
        r5r_network    = r5r_network,
        origins        = orig_muni,
        destinations   = dest_muni,
        mode           = "CAR",
        all_to_all     = TRUE,
        carspeed_scale = 1,
        verbose        = TRUE,
        progress       = TRUE
      )
    )
    
    st_write(itineraries_car, dsn = out_car, append = FALSE, quiet = TRUE)
    message("  Saved CAR -> ", out_car)
    
    # 2. PT itineraries
    message("  Calculating PT itineraries ...")
    system.time(
      itineraries_pt <- detailed_itineraries(
        r5r_network        = r5r_network,
        origins            = orig_muni,
        destinations       = dest_muni,
        departure_datetime = as.POSIXct("27-11-2025 07:00:00",
                                        format = "%d-%m-%Y %H:%M:%S"),
        mode               = c("WALK", "TRANSIT"),
        max_walk_time      = 15,
        max_trip_duration  = 90,
        max_rides          = 3,
        all_to_all         = TRUE,
        verbose            = TRUE,
        progress           = TRUE
      )
    )
    
    st_write(itineraries_pt, dsn = out_pt, append = FALSE, quiet = TRUE)
    message("  Saved PT  -> ", out_pt)
    
    # 3. Free R memory before next iteration (network stays alive)
    rm(itineraries_car, itineraries_pt, orig_muni, dest_muni)
    gc()
    
    results_log[[muni]] <- "OK"
    
  }, error = function(e) {
    message("  ERROR in ", muni, ": ", conditionMessage(e))
    results_log[[muni]] <<- paste("ERROR -", conditionMessage(e))
    try({ gc() }, silent = TRUE)
  })
}

# =============================================================================
# SHUTDOWN & SUMMARY
# =============================================================================

stop_r5(r5r_network)
rJava::.jgc()

message("\n", strrep("=", 60))
message("BATCH COMPLETE - summary")
message(strrep("=", 60))
for (muni in names(results_log)) {
  message(sprintf("  %-30s %s", muni, results_log[[muni]]))
}