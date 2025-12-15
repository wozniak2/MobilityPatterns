# -*- coding: utf-8 -*-
"""
Created on Fri Dec 12 09:54:13 2025
The script plots and allocates distribution of workplaces accross
hexagonal grid.
@author: wozni
"""

import pandas as pd
import geopandas as gpd
import os
import osmnx as ox
import matplotlib.pyplot as plt
import rasterio
import h3pandas
from rasterstats import zonal_stats
import geopandas
#from shapely import wkt
ox.settings.log_console = True     # show logs in notebook/console
ox.settings.use_cache = True       # enable local caching to save API

import numpy as np


def capped_proportional_allocation(x, total, cap):
    """
    Allocate 'total' proportionally to x, with per-element cap.
    """
    x = np.asarray(x, dtype=float)
    allocation = np.zeros_like(x)

    remaining = total
    active = np.ones_like(x, dtype=bool)

    while remaining > 1e-6 and active.any():
        weights = x[active]
        proposed = weights / weights.sum() * remaining

        capped = proposed >= cap
        allocation[active] += np.minimum(proposed, cap)

        # update remaining
        remaining -= np.minimum(proposed, cap).sum()

        # deactivate capped hexagons
        idx = np.where(active)[0]
        active[idx[capped]] = False

    return allocation

# G = ox.graph.graph_from_place('Poznan, Poland', network_type="drive")
## adjust your path
os.chdir("C:\\Users\\wozni\\Google Drive\\UAM\\HUB\\MobilityPatterns\\Data")
fp = r"C:\\Users\\wozni\\Google Drive\\UAM\\HUB\\MobilityPatterns\\Data\\ghs_built.tif"


# Read files 
raster = rasterio.open(fp)
deleg = gpd.read_file('delegatury.gpkg') ## 
regon = pd.read_csv('regon_clean.csv') ##
ceidg= pd.read_csv('ceidg_geocode.csv') ##
work_bui = gpd.read_file('work_bdot.gpkg') ##
poz = gpd.read_file('poz.gpkg') ## poznan agglomeration without the city
# merge files
df  = deleg.merge(regon, on='name', how='left')

# Remove na values
ceidg = ceidg[ceidg['g_geometry'].notna()]

# convert to gdf and cut for outliers
ceidg["g_geometry"] = geopandas.GeoSeries.from_wkt(ceidg["g_geometry"])
gdf = geopandas.GeoDataFrame(ceidg, geometry="g_geometry")
gdf = gdf.set_crs(crs='EPSG:4326')

gdf = gdf.to_crs(poz.crs)
gdf_cut = gpd.overlay(gdf, poz, how='intersection')


# Resample to H3 cells
poz_rep = poz.to_crs(crs='EPSG:4326')
resolution=7
hex_h3 = poz_rep.h3.polyfill_resample(resolution)

# match raster crs
polyjobs = hex_h3.to_crs(raster.crs)

# extract raster values
stats = zonal_stats(
    polyjobs,              # The GeoDataFrame geometries
    raster.read(1),        # Read the first band of the opened raster object
    affine=raster.transform, # Pass the affine transform from the raster object
    stats=['mean'],        # The statistic we want to calculate
    nodata=raster.nodata,    # Optional: Pass the raster's NoData value
    geo_json=False
)


mean_values = [stat['mean'] for stat in stats]

# Add the new column to GeoDataFrame
polyjobs['raster_mean'] = mean_values

# get back to previous crs
polyjobs = polyjobs.to_crs(hex_h3.crs)

# distribute workplaces across hex based on GHSL distribution and regon
polyjobs["workplaces"] = capped_proportional_allocation(
    polyjobs["raster_mean"],
    total=120_000,
    cap=12_000
)


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

polyjobs.plot(ax=ax2, column ='workplaces', cmap='OrRd')
gdf_cut.plot(ax=ax2, markersize=0.01, color = 'red', alpha=0.1)
ax2.title.set_text('hexagon grid (GHSL) + geocoded CEIDG')
ax2.title.set_color('white')





