# -*- coding: utf-8 -*-
"""
Created on Mon Nov 17 13:45:02 2025
sample between random residential locations and workplaces
@author: wozni
"""
import geopandas as gpd
import pandas as pd
import r5py
import os
import datetime

## adjust your path
os.chdir("C:\\Users\\wozni\\Google Drive\\UAM\\HUB\\MobilityPatterns\\Data")

# Step 1. Get origins and destinations
# home_code = 3021132 (Rokietnica)
bui_cut =  gpd.read_file('buildings.gpkg')
work_cut = gpd.read_file('workplaces.gpkg')


origins = bui_cut.loc[bui_cut['home_code'] == 3021132, ['home_code','geometry', 'JPT_NAZWA_']]
origin_points = origins.sample(10).copy()
origin_points.geometry = origin_points.geometry.centroid

destination_points = work_cut.sample(10).copy()
destination_points.geometry = destination_points.geometry.centroid

# unique ids required for r5py routing
origin_points["id"] = [f"o{i}" for i in range(len(origin_points))]
destination_points["id"] = [f"d{i}" for i in range(len(destination_points))]

# clean indices
origin_points = origin_points.reset_index(drop=True)
destination_points = destination_points.reset_index(drop=True)


# Step 2. Initialise network and compute routes
network = r5py.TransportNetwork("roads.pbf", "agency.zip")

detailed_PT = r5py.DetailedItineraries(
    network,
    origins=origin_points,
    destinations=destination_points,
    transport_modes=['TRANSIT'],
#    access_modes=['WALK', 'BICYCLE'],      # drive to transit
#    egress_modes=['WALK', 'BICYCLE'],     # walk from transit to destination

    snap_to_network=True,
)

detailed_CAR = r5py.DetailedItineraries(
    network,
    origins=origin_points,
    destinations=destination_points,
    transport_modes=['CAR'],
#    access_modes=['WALK', 'BICYCLE'],      # drive to transit
#    egress_modes=['WALK', 'BICYCLE'],     # walk from transit to destination

    snap_to_network=True,
)

# Step 3. visualise routes
import matplotlib.pyplot as plt

gdf = pd.concat([detailed_PT, detailed_CAR])



fig, ax = plt.subplots(figsize=(10, 10))

# plot all routes colored by 'transport_mode'
gdf.plot(
    ax=ax,
    column="transport_mode",
    cmap = "viridis",
    linewidth=2,
    categorical=True,
    legend=True,
    alpha = 0.5
)

plt.show()