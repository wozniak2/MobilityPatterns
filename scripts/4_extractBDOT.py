# -*- coding: utf-8 -*-
"""
Created on Thu Dec  4 13:30:23 2025
extracts residential buildings and workplaces from BDOT and compares against OSM
@author: wozni
"""

# import pandas as pd
import geopandas as gpd
import os
import matplotlib.pyplot as plt

## adjust your path
os.chdir("C:\\Users\\wozni\\OneDrive\\Pulpit\\MobilityPatterns\\Data")

ap = gpd.read_file('ap.gpkg') ## poznan agglomeration without the city
poz = gpd.read_file('poz.gpkg') ## core city (Poznan)
bui = gpd.read_file('bub.gpkg')
bui_osm = gpd.read_file('buildings.gpkg')
wp_osm = gpd.read_file('workplaces.gpkg')

## reproject files
bui_reprojected = bui.to_crs({'init': 'epsg:4326'})
ap_reprojected = ap.to_crs({'init': 'epsg:4326'})
poz_reprojected = poz.to_crs({'init': 'epsg:4326'})

# frequency count
bui_reprojected['FUNKCJAOGOLNABUDYNKU'].value_counts()


# cut residential buildings
bui_residential = bui_reprojected[bui_reprojected["FUNKCJAOGOLNABUDYNKU"] == "budynki mieszkalne"]
bui_residential = gpd.overlay(ap_reprojected, bui_residential, how='intersection')

# cut workplaces
bui_work = bui_reprojected[
    (bui_reprojected["FUNKCJAOGOLNABUDYNKU"] != "budynki mieszkalne") &
    (bui_reprojected["FUNKCJAOGOLNABUDYNKU"] != "zbiorniki, silosy i budynki magazynowe") &
    (bui_reprojected["FUNKCJAOGOLNABUDYNKU"] != "pozostałe budynki niemieszkalne")
]


bui_work = gpd.overlay(poz_reprojected, bui_work, how='intersection')

# plot results

# residential buildings
fig, (ax1, ax2) = plt.subplots(1,2, figsize=(15,15))
#fig.suptitle('Residential buildings', fontsize=10)

bui_residential.plot(ax = ax1, facecolor = "black", ec="black")
ap_reprojected.plot(ax = ax1, facecolor="none", ec="grey")
ax1.title.set_text('BDOT')

bui_osm.plot(ax = ax2, facecolor = "black", ec="black")
ap_reprojected.plot(ax = ax2, facecolor="none", ec="grey")
ax2.title.set_text('OSM')


# workplaces
fig, (ax1, ax2) = plt.subplots(1,2, figsize=(15, 15))
#fig.suptitle('Workplaces', fontsize=30)

bui_work.plot(ax = ax1, facecolor = "black", ec="black")
poz_reprojected.plot(ax = ax1, facecolor="none", ec="grey")
ax1.title.set_text('BDOT')

wp_osm.plot(ax = ax2, facecolor = "black", ec="black")
poz_reprojected.plot(ax = ax2, facecolor="none", ec="grey")
ax2.title.set_text('OSM')