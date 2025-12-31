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
from rasterio.plot import show
from rasterio.mask import mask
# from rasterio.features import shapes
import h3pandas
from rasterstats import zonal_stats
import geopandas
#from shapely import wkt
ox.settings.log_console = True     # show logs in notebook/console
ox.settings.use_cache = True       # enable local caching to save API

import numpy as np
from geocube.vector import vectorize
import rioxarray

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
poz = gpd.read_file('boundary.gpkg') ## core city
# merge files
df  = deleg.merge(regon, on='name', how='left')


data = rioxarray.open_rasterio(fp, mask_and_scale=False)



from shapely.geometry import box
arr = np.asarray(data.squeeze(), dtype=np.float32)


transform = data.rio.transform()
rows, cols = arr.shape

polys = []
values = []

for row in range(rows):
    for col in range(cols):
        x_min, y_max = transform * (col, row)
        x_max, y_min = transform * (col + 1, row + 1)

        polys.append(box(x_min, y_min, x_max, y_max))
        values.append(arr[row, col])

ghs_gdf = gpd.GeoDataFrame(
    {"raster_values": values, "geometry": polys},
    crs=data.rio.crs
)


poz = poz.to_crs(ghs_gdf.crs)


# replace nodata values with 0
nodata = data.rio.nodata
if nodata is not None:
    data = data.where(data != nodata, 1)

# IMPORTANT: remove nodata metadata
data = data.rio.write_nodata(None)

# cast to rasterio-compatible dtype
data = data.astype("float32")

# name the band
data.name = "raster_values"


ghs_gdf = vectorize(data)


poz = poz.to_crs(ghs_gdf.crs)


workplace_grid = gpd.overlay(ghs_gdf, poz, how='intersection', keep_geom_type = False)



workplace_grid["nonres_weight"] = (
    workplace_grid["raster_values"] / workplace_grid["raster_values"].sum()
)
workplace_grid["grid_id"] = range(1, len(workplace_grid) + 1)
workplace_grid = workplace_grid.to_crs(epsg=4326)


#workplace_grid["geometry"] = workplace_grid["geometry"].make_valid()


# Remove na values
ceidg = ceidg[ceidg['g_geometry'].notna()]

# convert to gdf and cut for outliers
sme = gpd.GeoDataFrame(
    ceidg,
    geometry=gpd.points_from_xy(ceidg["g_dlug"], ceidg["g_szer"]),
    crs="EPSG:4326"
)
sme["geometry"] = sme["geometry"].make_valid()

sme_join = gpd.sjoin(
    sme,
    workplace_grid[["grid_id", "geometry"]],
    how="left",
    predicate="within"
)

# count SMEs per grid
sme_per_grid = (
    sme_join
    .groupby("grid_id")
    .size()
    .reset_index(name="sme_count")
)

# left join back to workplace_grid
workplace_grid = workplace_grid.merge(
    sme_per_grid,
    on="grid_id",
    how="left"
)

# replace NA with 0
workplace_grid["sme_count"] = workplace_grid["sme_count"].fillna(0)

# compute weights
workplace_grid["sme_weight"] = (
    workplace_grid["sme_count"] / workplace_grid["sme_count"].sum()
)
total_workplaces = 371_010  # June 2025
ghsl_share = 0.8
sme_share = 0.2

workplace_grid["workplaces"] = (
    (workplace_grid["nonres_weight"] * ghsl_share) +
    (workplace_grid["sme_weight"] * sme_share)
) * total_workplaces


wg_plot = workplace_grid[workplace_grid["workplaces"] > 0]



import contextily as ctx
bins = [0, 99, 199, 299, 399, 499, 599, 700]
labels = ["0-99", "100-199", "200-299", "300-399", "400-499", "500-599", "600-700"]

# create a categorical column for plotting
wg_plot["workplace_bin"] = pd.cut(
    wg_plot["workplaces"], bins=bins, labels=labels, include_lowest=True
)

wg_plot = wg_plot.to_crs(epsg=3857)
# apply zoom
x_min, y_min, x_max, y_max = wg_plot.total_bounds
pad = 1000  # in meters (Web Mercator units)
xlim = (x_min - pad, x_max + pad)
ylim = (y_min - pad, y_max + pad)

# plot polygons colored by bin
fig, ax = plt.subplots(figsize=(10, 10))
wg_plot.plot(
    column="workplace_bin",
    categorical=True,
    legend=True,
    cmap="Reds",
    ec="black",
    alpha=1,
    linewidth=0.1,
    ax=ax
)
#poz.plot(ax=ax, facecolor='none')
ctx.add_basemap(
    ax,
    source=ctx.providers.CartoDB.Positron,  # light grayscale tiles
    crs=wg_plot.crs
)

# apply zoom
#ax.set_xlim(xlim)
#ax.set_ylim(ylim)
ax.set_axis_off()
plt.show()

# Resample to H3 cells
poz_rep = poz.to_crs(crs='EPSG:4326')
resolution=7
hex_h3 = poz_rep.h3.polyfill_resample(resolution)

# match raster crs
polyjobs = hex_h3.to_crs(ghs_gdf_cut.crs)

# extract raster values
stats = zonal_stats(
    polyjobs,              # The GeoDataFrame geometries
    ghs_gdf_cut.read(1),        # Read the first band of the opened raster object
    affine=ghs_gdf_cut.transform, # Pass the affine transform from the raster object
    stats=['mean'],        # The statistic we want to calculate
    nodata=ghs_gdf_cut.nodata,    # Optional: Pass the raster's NoData value
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
    total=371_000,
    cap=12_000
)


ghs_gdf_cut['raster_values'].mean()

ghs_rep = ghs_gdf_cut.to_crs(crs='EPSG:4326')
poz_rep = poz.to_crs(crs='EPSG:4326')

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





