# -*- coding: utf-8 -*-
"""
Created on Thu Oct 30 13:25:45 2025

The script downloads and plots transportation network together with
residential buildings and workplaces footprints for Poznan
agglomeration. To be expanded 

@author: wozni
"""

import pandas as pd
import geopandas as gpd
import os
import matplotlib.pyplot as plt
# from shapely.geometry import box
import networkx as nx
import mapclassify
import osmnx as ox
ox.settings.log_console = True     # show logs in notebook/console
ox.settings.use_cache = True       # enable local caching to save API

## adjust your path
os.chdir("C:\\Users\\wozni\\Google Drive\\UAM\\HUB\\MobilityPatterns\\Data")

# Read files 
df = pd.read_csv('OD_flows.csv') ## flows matrix stat poland
ap = gpd.read_file('ap.gpkg') ## poznan agglomeration without the city
poz = gpd.read_file('poz.gpkg') ## core city (Poznan)
pop = gpd.read_file('pop.gpkg') ## population density (optional)

poznanOD = df[df["work_name"] == "Poznań"]

ap.rename(columns={'JPT_KOD_JE': 'home_code'}, inplace=True)
ap['home_code'] = ap['home_code'].str.replace('_', '')
ap['home_code'] = ap['home_code'].astype('int64')

ap['home_code'].dtype
poznanOD['home_code'].dtype

merged_df = pd.merge(poznanOD, ap, on='home_code', how='inner')

# pd.concat([merged_df['home_name'],ap['JPT_NAZWA_JE_']]).drop_duplicates(keep=False)

# bounding_box = {
#    "min_lon": 16.513,
#    "max_lon": 17.402,
#    "min_lat": 52.098,
#    "max_lat": 52.656,
# }

# min_lon = bounding_box["min_lon"]
# max_lon = bounding_box["max_lon"]
# min_lat = bounding_box["min_lat"]
# max_lat = bounding_box["max_lat"]

# bbox = box(min_lon, min_lat, max_lon, max_lat)
# g = gpd.GeoSeries([bbox])

#clipped_gdf = gdf.loc[gdf.geometry.within(bbox)]
#clipped_gdf.crs


# create network from that bounding box
o_bb = 17.402, 52.680, 16.460, 52.151
G = ox.graph.graph_from_bbox(o_bb, network_type="drive_service")
#G_projected = ox.project_graph(G)
#G_gdf = gpd.GeoDataFrame(G_projected) 

Gr = ox.graph_from_bbox(o_bb, custom_filter='["railway"~"tram|rail"]')

graphs = [G, Gr]
full_graph = nx.compose_all(graphs)


# -------------------------------------------------------------
# Define tags relevant to workplaces and residential buildings
# -------------------------------------------------------------

tags_bui = {
    'building': [
        'residential', 'apartments', 'detached', 'house',
        'terrace', 'semidetached_house', 'farm'
    ],
    'landuse': ['residential']
}

tags_wp = {
    'landuse': ['commercial', 'industrial'],
    'building': ['office', 'commercial', 'industrial', 'retail'],
    'office': True,             # all office-type amenities
    'amenity': ['university', 'school', 'hospital'],  # major workplaces
    'shop': True                # include retail
}

## reproject population and cut to poznan agglomeration (optional)
pop_reprojected = pop.to_crs({'init': 'epsg:4326'})
ap_reprojected = ap.to_crs({'init': 'epsg:4326'})
pop_cut = gpd.overlay(ap_reprojected, pop_reprojected, how='intersection')

# Fetch footprints
buildings = ox.features_from_bbox(o_bb, tags=tags_bui)
bui = buildings[buildings.geometry.geom_type == 'Polygon']

workplaces = ox.features_from_place("Poznań, Poland", tags=tags_wp)
work = workplaces[workplaces.geometry.geom_type == 'Polygon']
work['amenity'] = work['amenity'].fillna("wp")

## cut buildings and workplaces
poz_reprojected = poz.to_crs({'init': 'epsg:4326'})
work_cut = gpd.overlay(poz_reprojected, work, how='intersection')
bui_cut = gpd.overlay(ap_reprojected, bui, how='intersection')

# attach buildings and workplaces to the nearest nodes as attributes
bui_points = bui_cut.representative_point()
nn_bui = ox.distance.nearest_nodes(full_graph, bui_points.x, bui_points.y)

wp_points = work_cut.representative_point()
nn_wp = ox.distance.nearest_nodes(full_graph, wp_points.x, wp_points.y)

useful_tags_bui = ["building"]
useful_tags_wp = ["amenity"]

for node, building in zip(nn_bui, bui[useful_tags_bui].to_dict(orient="records")):
    building = {k: v for k, v in building.items() if pd.notna(v)}
    full_graph.nodes[node].update({"building": building})

for node, workplace in zip(nn_wp, work[useful_tags_wp].to_dict(orient="records")):
    workplace = {k: v for k, v in workplace.items() if pd.notna(v)}
    full_graph.nodes[node].update({"amenity": workplace})

nodes, streets = ox.graph_to_gdfs(full_graph)


# plot the network, but do not show it or close it yet
ec = ['w' if 'highway' in d else 'y' for _, _, _, d in full_graph.edges(keys=True, data=True)]
el = [0.1 if 'highway' in d else 0.25 for _, _, _, d in full_graph.edges(keys=True, data=True)]

fig, ax = ox.plot.plot_graph(
    full_graph,
    show=False,
    close=False,
    bgcolor="#111111",
    edge_color=ec,
    edge_linewidth=el,
    node_size=0,
    edge_alpha = 0.7
)

bui_cut.plot(ax=ax, ec=None, color="violet", alpha=0.3, zorder=-1)
work_cut.plot(ax=ax, ec=None, color="red", alpha=1, zorder=-1)
# unmark if want to plot population density grid
#pop_cut.plot(ax=ax, column='tot_15_64', scheme='user_defined', classification_kwds={'bins':[0, 100, 500, 1000, 4300]}, alpha = 0.2)
fig.set_size_inches(8, 8)
plt.show()

mapclassify.Quantiles(pop_cut.tot_15_64, k=5)


## save graph
ox.save_graphml(full_graph, './poz_graph.graphml')


