# -*- coding: utf-8 -*-
"""
Created on Fri Jan  2 11:33:42 2026

@author: wozni
"""

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