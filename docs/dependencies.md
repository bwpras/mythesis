# Dependencies

## Python

| Package | Files importing it | Status |
|---|---|---|
| numpy, pandas, joblib, scikit-learn, imbalanced-learn | active training scripts | confirmed active |
| matplotlib, seaborn | notebooks | notebook-only |
| folium, geopandas, shapely, contextily, plotly | mapping/exploration notebooks | notebook-only |
| scipy, statsmodels, xgboost, Pillow | exploratory notebooks | notebook-only |

## MATLAB

| Toolbox/capability | Evidence | Status |
|---|---|---|
| Signal Processing Toolbox | `butter`, `filtfilt` | confirmed |
| Parallel Computing Toolbox | `parfor`, `gcp` | confirmed for batch paths |
| Mapping Toolbox | `webmap`, `geoplot`, `geobasemap` | confirmed for reader/visualization paths |
| App Designer | `.mlapp`, `uifigure` support | confirmed |
| Wavelet Toolbox | wavelet/CWT helper code | inferred |
