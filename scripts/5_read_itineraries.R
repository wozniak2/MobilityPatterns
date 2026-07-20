library(sf)
library(terra)
library(tidyverse)

# --- Config ---
data_dir <- "/Users/wozni/Downloads/commuting_itineraries" 

# --- Find files ---
pt_files  <- list.files(data_dir, pattern = "^pt_itineraries_.*\\.gpkg$",  full.names = TRUE)
car_files <- list.files(data_dir, pattern = "^car_itineraries_.*\\.gpkg$", full.names = TRUE)

# Extract county names from filenames (lowercase for matching)
extract_county <- function(fname) {
  str_extract(basename(fname), "(?<=itineraries_).*(?=\\.gpkg)") %>% str_to_lower()
}

pt_counties  <- extract_county(pt_files)
car_counties <- extract_county(car_files)

# Match PT and car files by county name
matched <- inner_join(
  tibble(county = pt_counties,  pt_path  = pt_files),
  tibble(county = car_counties, car_path = car_files),
  by = "county"
)

cat("Matched counties:", nrow(matched), "\n")
cat("Unmatched PT: ",  setdiff(pt_counties,  car_counties), "\n")
cat("Unmatched car:", setdiff(car_counties, pt_counties),  "\n")

# --- Processing function for one county ---
process_county <- function(pt_path, car_path, county_name) {
  message("Processing: ", county_name)
  
  pt  <- st_read(pt_path,  quiet = TRUE)
  car <- st_read(car_path, quiet = TRUE)
  
  pit <- st_transform(pt,  3857)
  cit <- st_transform(car, 3857)
  
  pit$freq <- 1
  cit$freq <- 1
  
  vpit <- vect(pit)
  vcit <- vect(cit)
  
  rpit <- rast(ext(vpit), resolution = 120)
  rcit <- rast(ext(vcit), resolution = 120)
  
  rpit_flow <- rasterize(vpit, rpit, field = "freq", fun = "sum", background = NA)
  rcit_flow <- rasterize(vcit, rcit, field = "freq", fun = "sum", background = NA)
  
  list(
    county   = county_name,
    df_pit   = as.data.frame(rpit_flow, xy = TRUE),
    df_cit   = as.data.frame(rcit_flow, xy = TRUE),
    rpit_flow = rpit_flow,  # keep rasters too, useful for later merging
    rcit_flow = rcit_flow
  )
}

# --- Iterate over all matched counties ---
results <- pmap(
  list(matched$pt_path, matched$car_path, matched$county),
  process_county
)

names(results) <- matched$county

# Read raw itineraries for weight joining (geometry preserved)
pt_itineraries <- matched |>
  pmap(\(county, pt_path, car_path) {
    st_read(pt_path, quiet = TRUE) |> mutate(county = county)
  }) |>
  bind_rows()

car_itineraries <- matched |>
  pmap(\(county, pt_path, car_path) {
    st_read(car_path, quiet = TRUE) |> mutate(county = county)
  }) |>
  bind_rows()