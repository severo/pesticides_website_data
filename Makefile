# Based on previous work by:
# - Mike Bostock, https://medium.com/@mbostock/command-line-cartography-part-1-897aa8f8ca2c
#   parts 1, 2, 3 and 4.
# - Carolina Bigonha, https://github.com/carolinabigonha/br-atlas/
# - Philippe Rivière, https://observablehq.com/@fil/epsg-5530
# - IBGE, ftp://geoftp.ibge.gov.br/organizacao_do_territorio

NODE_OPTIONS=--max_old_space_size=4096
export NODE_OPTIONS

binDir = node_modules/.bin/
cacheDir = cache/
tmpDir = tmp/
finalDir = final/

SHP2JSON = $(addprefix $(binDir), shp2json)
GEOPROJECT = $(addprefix $(binDir), geoproject)
NDJSON_SPLIT = $(addprefix $(binDir), ndjson-split)
NDJSON_MAP = $(addprefix $(binDir), ndjson-map)
NDJSON_REDUCE = $(addprefix $(binDir), ndjson-reduce)
GEO2TOPO = $(addprefix $(binDir), geo2topo)
TOPOSIMPLIFY = $(addprefix $(binDir), toposimplify)
TOPOQUANTIZE = $(addprefix $(binDir), topoquantize)
TOPOMERGE = $(addprefix $(binDir), topomerge)
TOPO2GEO = $(addprefix $(binDir), topo2geo)

# The file is in SIRGAS 2000 CRS. The coordinates are exactly the same as in WGS 84, so no reprojections needed (GeoJSON requires WGS84).
zipUrl = ftp://geoftp.ibge.gov.br/organizacao_do_territorio/malhas_territoriais/malhas_municipais/municipio_2017/Brasil/BR/br_municipios.zip
zip = $(addprefix $(cacheDir), br.zip)

shpBase = $(addprefix $(tmpDir), BRMUE250GC_SIR)
shp = $(addprefix $(shpBase), .shp)
json = $(addprefix $(tmpDir), br.json)
px = $(addprefix $(tmpDir), br-px.json)
px-nd = $(addprefix $(tmpDir), br-px.ndjson)
ibge-px-nd = $(addprefix $(tmpDir), br-ibge-px.ndjson)
attr-px-nd = $(addprefix $(tmpDir), br-attr-px.ndjson)
attr-px-topo = $(addprefix $(tmpDir), br-attr-px-topo.json)
simple-px-topo = $(addprefix $(tmpDir), br-simple-px-topo.json)
quantized-px-topo = $(addprefix $(tmpDir), br-quantized-px-topo.json)
republic-px-topo = $(addprefix $(tmpDir), br-republic-px-topo.json)
fu-px-topo = $(addprefix $(tmpDir), br-fu-px-topo.json)
internal-fu-px-topo = $(addprefix $(tmpDir), br-internal-fu-px-topo.json)

px-topo = $(addprefix $(finalDir), br-px-topo.json)

all: $(px-topo)

$(zip):
	mkdir -p $(cacheDir)
	curl -o $(zip) $(zipUrl)

$(shp): $(zip)
	unzip -u -d $(tmpDir) $(zip)
	# Set the current date
	touch $(shpBase).*

$(json): $(shp)
	$(SHP2JSON) $(shp) -o $(json)

$(px): $(json)
	# Project to EPSG:5530, so that treatments are done on pixels, not steradians
	# 54 -> rotation to center on Brazil, 960: size of the map in pixels
	# the px coordinates therefore lay between 0 and 960
	$(GEOPROJECT) 'd3.geoPolyconic().rotate([54, 0]).fitSize([960, 960], d)' < $(json) > $(px)

$(px-nd): $(px)
	# Use newline-delimited JSON to make it easier to manage features properties
	$(NDJSON_SPLIT) 'd.features' < $(px) > $(px-nd)

$(ibge-px-nd): $(px-nd)
	# Compute the IBGE code, and only keep this property
	$(NDJSON_MAP) 'd.properties = {ibgeCode: d.properties.CD_GEOCMU.slice(0,6)}, d' < $(px-nd) > $(ibge-px-nd)

$(attr-px-nd): $(ibge-px-nd)
	# TODO: Merge with the statistics data
	cp $(ibge-px-nd) $(attr-px-nd)

$(attr-px-topo): $(attr-px-nd)
	# Convert from ND GeoJson to TopoJSON format (set the geometries under the
	# 'municipalities' topology object - later there will also be a
	# 'federative-units' one)
	$(GEO2TOPO) -n municipalities=$(attr-px-nd) > $(attr-px-topo)

$(simple-px-topo): $(attr-px-topo)
	# Simplify, removing "triangles areas" below 1 px²
	# TODO: also prepare a 0.01px² file, in case we use zoom on municipalities
	$(TOPOSIMPLIFY) -p 1 < $(attr-px-topo) > $(simple-px-topo)

$(quantized-px-topo): $(simple-px-topo)
	# Quantize, removing useless decimals
	# With parameter 1e5, the delta are encoded as [55962, 56806] instead of
	# [537.2378638089835, 538.9451202128314], for example
	$(TOPOQUANTIZE) 1e5 < $(simple-px-topo) > $(quantized-px-topo)

# TODO: come back to WGS84 CRS
#$(quantized-topo):$(quantized-px-topo)
		# Invert EPSG:5530 projection to come back to WGS 84 CRS. Three steps
		# 1. topojson to geojson
	  #$(TOPO2GEO) municipalities=- < $(quantized-px-topo) | \
		# 2. invert projection - does not seem to be possible
		#$(GEOPROJECT) 'd3.geoPolyconic().rotate([54, 0]).fitSize([960, 960].invert, d)' | \
		# 3. geojson to topojson
		#$(GEO2TOPO) municipalities=-

$(republic-px-topo): $(quantized-px-topo)
	# Add a 'republic' object along to 'municipalities' and 'federative-units'.
	# It's obtain by merging the federative-units. Its unique geometry does not
	# contain any 'id' key, contrarily to federative-units (see next step).
	$(TOPOMERGE) republic=municipalities < $(quantized-px-topo) > $(republic-px-topo)

$(fu-px-topo): $(republic-px-topo)
	# Add a 'federative-units' object along to 'municipalities'. It's obtain by
	# merging the municipalities inside every federative unit (or state. See
	# https://en.wikipedia.org/wiki/States_of_Brazil for the details). The
	# federative unit code is given by the two first digits of the municipal IBGE
	# code, and is stored in the 'id' key of every FU geometry.
	$(TOPOMERGE) -k 'd.properties.ibgeCode.slice(0, 2)' federative-units=municipalities < $(republic-px-topo) > $(fu-px-topo)

$(internal-fu-px-topo): $(fu-px-topo)
	# Also store the internal frontiers between federative units, for styling
	# reasons ("Stroking exterior borders tends to lose detail along coastlines")
	# In that object, there no more relation to the federative units or their id.
	$(TOPOMERGE) --mesh -f 'a !== b' internal-federative-units=federative-units < $(fu-px-topo) > $(internal-fu-px-topo)

$(px-topo): $(internal-fu-px-topo)
	mkdir -p $(finalDir)
	cp $(internal-fu-px-topo) $(px-topo)

clean: clean-tmp clean-final

clean-all: clean-tmp clean-final clean-cache

clean-tmp:
	rm -rf ./$(tmpDir)

clean-final:
	rm -rf ./$(finalDir)

clean-cache:
	rm -rf ./$(cacheDir)
