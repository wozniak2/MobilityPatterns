# -*- coding: utf-8 -*-
"""
Created on Thu Nov 13 13:31:06 2025
Extract pbf from osm
@author: wozni
"""

import requests
import subprocess
import os

## adjust your path
os.chdir("C:\\Users\\wozni\\Google Drive\\UAM\\HUB\\MobilityPatterns\\Data")


# Define bounding box (south, west, north, east) - Poznan
bbox = (52.151, 16.460, 52.680, 17.402)

# Overpass query for all highway ways (and their nodes)
query = f"""
[out:xml][timeout:180];
(
  way["highway"]({bbox[0]},{bbox[1]},{bbox[2]},{bbox[3]});
  way["railway"="tram"]({bbox[0]},{bbox[1]},{bbox[2]},{bbox[3]});
  way["railway"="light_rail"]({bbox[0]},{bbox[1]},{bbox[2]},{bbox[3]});
  way["railway"="rail"]({bbox[0]},{bbox[1]},{bbox[2]},{bbox[3]});
  way["railway"="subway"]({bbox[0]},{bbox[1]},{bbox[2]},{bbox[3]});
);
(._;>;);
out body;
"""

# Filenames
osm_xml = "roads.osm"
osm_pbf = "roads.pbf"

# Step 1. Download from Overpass
url = "https://overpass-api.de/api/interpreter"
r = requests.post(url, data=query)
r.raise_for_status()

with open(osm_xml, "wb") as f:
    f.write(r.content)
    
# Step 2. Convert to pbf & save
# use this tool (win64): https://wiki.openstreetmap.org/wiki/Osmconvert#Windows    
subprocess.run(["osmconvert", osm_xml, f"-o={osm_pbf}"], check=True)




