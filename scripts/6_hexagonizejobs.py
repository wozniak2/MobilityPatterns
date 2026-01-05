# -*- coding: utf-8 -*-
"""
Created on Fri Jan  2 11:33:42 2026
The script aggregates weighted workplaces obtained from small enterprises registry and 
GHSL data (non-res) to hexagonal grid
@author: wozni
"""
import pandas as pd
import geopandas as gpd
import os
import matplotlib.pyplot as plt
import h3pandas
import osmnx as ox
cf = '["highway"~"primary|secondary|motorway|trunk"]'
G = ox.graph_from_place('Poznan, Poland', network_type="drive", custom_filter=cf)
## adjust your path
os.chdir("C:\\Users\\wozni\\Google Drive\\UAM\\HUB\\MobilityPatterns\\Data")
# import neccessary files --> distributejobs.py


nodes, streets = ox.graph_to_gdfs(G)
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

joined["index_right"].isna().sum()

# aggregate values per hex
hex_sum = (
    joined
    .groupby("hex_id", as_index=False)["workplaces"]
    .sum()
)

# join back to hex grid
hex_h3 = hex_h3.merge(hex_sum, on="hex_id", how="left")
#hex_h3["workplaces"] = hex_h3["workplaces"].fillna(0)
# hex_h3 = hex_h3.rename(columns={"workplaces": "jobs_summed"})
hex_h3['workplaces'].sum()
hex_h3.plot()

# initialize plot
import contextily as ctx


fig, ax = plt.subplots(figsize=(8, 8))

hex_h3.plot(
    column="workplaces",
    ax=ax,
    scheme="NaturalBreaks",
    k=6,
    cmap="viridis",
    linewidth=0,
    alpha=0.5,
    legend=True,
    legend_kwds={"fmt": "{:.0f}"} 
)
poz.plot(ax=ax, facecolor='none')
streets.plot(ax=ax, ec='black', linewidth=0.1)
ctx.add_basemap(
    ax,
    source=ctx.providers.CartoDB.PositronNoLabels,
    crs=hex_h3.crs
)

ax.set_axis_off()
plt.show()