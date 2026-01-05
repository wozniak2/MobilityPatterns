# -*- coding: utf-8 -*-
"""
Created on Fri Jan  2 11:33:42 2026

@author: wozni
"""
import pandas as pd
import geopandas as gpd
import os
import matplotlib.pyplot as plt
import h3pandas

## adjust your path
os.chdir("C:\\Users\\wozni\\Google Drive\\UAM\\HUB\\MobilityPatterns\\Data")
# import neccessary files --> distributejobs.py

workplace_grid = gpd.read_file('workplace_grid.gpkg')
poz = gpd.read_file('boundary.gpkg') ## core city

# project
poz = poz.to_crs(crs='EPSG:4326')
workplace_grid = workplace_grid.to_crs(poz.crs)

# Resample to H3 cells
resolution=7
hex_h3 = poz.h3.polyfill_resample(resolution)
hex_h3 = hex_h3.reset_index(drop=True)
hex_h3["hex_id"] = hex_h3.index

# match crs
# hex_jobs = hex_h3.to_crs(poz.crs)


joined = gpd.sjoin(
    workplace_grid,
    hex_h3[["hex_id", "geometry"]],
    how="left",
    predicate="within"
)

# aggregate values per hex
hex_sum = (
    joined
    .groupby("hex_id", as_index=False)["raster_values"]
    .sum()
)

# join back to hex grid
hex_h3 = hex_h3.merge(hex_sum, on="hex_id", how="left")
hex_h3["raster_values"] = hex_h3["raster_values"].fillna(0)
hex_h3 = hex_h3.rename(columns={"raster_values": "jobs_summed"})

hex_h3.plot()

# initialize plot
fig, (ax1, ax2) = plt.subplots(1,2, figsize=(15,15))
# 1. Change the background color of the Figure (the canvas holding everything)
fig.set_facecolor('black') 

# 2. Change the background color of the first subplot (ax1)
ax1.set_facecolor('black')

# 3. Change the background color of the second subplot (ax2)
ax2.set_facecolor('black')

# 4. Plot layers
df.plot(ax=ax1, column='total', cmap='OrRd', linewidth=0.2, alpha=0.6)
gdf_cut.plot(ax=ax1, markersize=0.01, color = 'red', alpha=0.1)
ax1.title.set_text('REGON-delegatury + geocoded CEIDG')
ax1.title.set_color('white')

poz_rep.plot(ax=ax2,ec='white')
#gdf_cut.plot(ax=ax2, markersize=0.01, color = 'red', alpha=0.1)
ghs_rep.plot(ax=ax2, alpha=0.5, cmap='OrRd', column = 'raster_values')

ax2.title.set_text('hexagon grid (GHSL) + geocoded CEIDG')
ax2.title.set_color('white')