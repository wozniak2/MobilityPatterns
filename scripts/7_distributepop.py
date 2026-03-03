# -*- coding: utf-8 -*-
"""
Created on Mon Jan  5 10:52:48 2026

@author: wozni
"""

import numpy as np
import rioxarray
import geopandas as gpd
import matplotlib.pyplot as plt
import h3pandas
import pandas as pd
import os

fp = r"C:\\Users\\wozni\\Google Drive\\UAM\\HUB\\MobilityPatterns\\Data\\ghs_pop.tif"
## adjust your path
os.chdir("C:\\Users\\wozni\\Google Drive\\UAM\\HUB\\MobilityPatterns\\Data")

# create network from that bounding box
o_bb = 17.402, 52.680, 16.460, 52.151
import osmnx as ox
cf = '["highway"~"primary|secondary|motorway|trunk"]'
G = ox.graph.graph_from_bbox(o_bb, network_type="drive_service", custom_filter=cf)
nodes, streets = ox.graph_to_gdfs(G)


data = rioxarray.open_rasterio(fp, mask_and_scale=False)
ap = gpd.read_file('ap.gpkg') ## poznan agglomeration without the city
poz = gpd.read_file('poz.gpkg') 


# convert raster to polygons
# time consumming; perhabs can be optimized

from shapely.geometry import box
arr = np.asarray(data.squeeze(), dtype=np.float32)

transform = data.rio.transform()
rows, cols = arr.shape

polys = []
values = []

# read values from raster
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

# match crs and cut
ap = ap.to_crs(ghs_gdf.crs)

pop_grid = gpd.overlay(ghs_gdf, ap, how='intersection', keep_geom_type = False)
pop_grid = pop_grid.replace({'raster_values': -200}, 0)

ap_union = ap.geometry.unary_union
ap_union = gpd.GeoSeries([ap_union], crs=pop_grid.crs)
streets = streets.to_crs(crs=pop_grid.crs)


# Resample to H3 cells
# ap_rep = ap_union.to_crs(crs='EPSG:4326')

# resolution=7
# project
# ap = ap.to_crs(crs='EPSG:4326')
# hex_h3 = ap_rep.h3.polyfill_resample(resolution)
# hex_h3 = hex_h3.reset_index(drop=True)
# hex_h3["hex_id"] = hex_h3.index
# hex_h3.plot()

# initialize plot
import contextily as ctx


fig, ax = plt.subplots(figsize=(8, 8))

pop_grid.plot(
    column="raster_values",
    ax=ax,
    scheme="NaturalBreaks",
    k=6,
    cmap="viridis",
    linewidth=0,
    alpha=0.5,
    legend=True,
    legend_kwds={"fmt": "{:.0f}"} 
)
#ap_union.plot(ax=ax, facecolor='none', linewidth=0.5)
streets.plot(ax=ax, ec='black', linewidth=0.3, alpha=0.7)
ctx.add_basemap(
    ax,
    source=ctx.providers.CartoDB.PositronNoLabels,
    crs=pop_grid.crs
)

ax.set_axis_off()
plt.show()