# -*- coding: utf-8 -*-
"""
Created on Mon Jan  5 10:52:48 2026

@author: wozni
"""
import rasterio
import numpy as np
import rioxarray
import geopandas as gpd

fp = r"C:\\Users\\wozni\\Google Drive\\UAM\\HUB\\MobilityPatterns\\Data\\ghs_pop.tif"

data = rioxarray.open_rasterio(fp, mask_and_scale=False)



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
