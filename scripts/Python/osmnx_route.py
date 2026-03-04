# -*- coding: utf-8 -*-
"""
Created on Fri Nov  7 11:50:05 2025

Routing mechanism

@author: wozni
"""

import os
import matplotlib.pyplot as plt
# from shapely.geometry import box
import osmnx as ox
import networkx as nx
import random


## adjust your path
os.chdir("C:\\Users\\wozni\\Google Drive\\UAM\\HUB\\MobilityPatterns\\Data")

# load graph
poz_graph = ox.load_graphml('./poz_graph.graphml')
poz_roads = ox.load_graphml('./poz_roads.graphml')

poz_proj = ox.projection.project_graph(poz_roads)

# extract O-D
residential_nodes = [n for n, data in poz_proj.nodes(data=True)
                  if data.get('building') is not None]

wp_nodes = [n for n, data in poz_proj.nodes(data=True)
                  if data.get('amenity') is not None]


# impute missing edge speeds and calculate edge travel times with the speed module
poz_proj = ox.routing.add_edge_speeds(poz_proj)

poz_proj = ox.routing.add_edge_travel_times(poz_proj)

# and sample

O = random.sample(residential_nodes, 5)

D = random.sample(wp_nodes, 5)

# find the shortest path between nodes, minimizing travel time, then plot it
weight = 'travel_time'
route = ox.routing.shortest_path(poz_proj, O, D, weight=weight)
routes = ox.routing.k_shortest_paths(poz_proj, O, D, k=3, weight='length')

fig, ax = ox.plot.plot_graph_route(poz_proj, route, node_size=0, route_linewidth=0.5)

fig, ax = ox.plot_graph_routes(poz_proj, list(route), route_colors="r", 
                               node_size=0, route_linewidths=1,
                               orig_dest_size = 1, route_alpha = 1)

# find the travel time of that path
gdf = ox.routing.route_to_gdf(poz_proj, route)
gdf["travel_time"].sum()/60

