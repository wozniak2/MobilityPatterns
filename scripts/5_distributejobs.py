# -*- coding: utf-8 -*-
"""
Created on Fri Dec 12 09:54:13 2025
The script allocates distribution of workplaces based on sme and ghs data
@author: wozni
"""

import pandas as pd
import geopandas as gpd
import os
# import osmnx as ox
import matplotlib.pyplot as plt
import rasterio
#from rasterio.plot import show
#from rasterio.mask import mask
# from rasterio.features import shapes
# import h3pandas
from rasterstats import zonal_stats
import geopandas
#from shapely import wkt
# ox.settings.log_console = True     # show logs in notebook/console
# ox.settings.use_cache = True       # enable local caching to save API

import numpy as np
# from geocube.vector import vectorize
import rioxarray



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


# convert raster to polygons
# time consumming; perhabs can be optimized

from shapely.geometry import box
arr = np.asarray(data.squeeze(), dtype=np.float32)

transform = data.rio.transform()
rows, cols = arr.shape

polys = []
values = []

# read from raster
for row in range(rows):
    for col in range(cols):
        x_min, y_max = transform * (col, row)
        x_max, y_min = transform * (col + 1, row + 1)

        polys.append(box(x_min, y_min, x_max, y_max))
        values.append(arr[row, col])

# write to gdf
ghs_gdf = gpd.GeoDataFrame(
    {"raster_values": values, "geometry": polys},
    crs=data.rio.crs
)


# match crs
poz = poz.to_crs(ghs_gdf.crs)


# cut to the city
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

##
total_workplaces = 371_010  # June 2025
ghsl_share = 0.8
sme_share = 0.2

workplace_grid["workplaces"] = (
    (workplace_grid["nonres_weight"] * ghsl_share) +
    (workplace_grid["sme_weight"] * sme_share)
) * total_workplaces


## write workplace grid to file
workplace_grid.to_file("workplace_grid.gpkg")



##
## Plots jobs distribution
##


import contextily as ctx
wg_plot = workplace_grid[workplace_grid["workplaces"] > 0]
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







