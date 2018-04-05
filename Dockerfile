# DOCKER-VERSION 1.3.1
# VERSION 0.2
FROM debian:stretch
MAINTAINER Vitaliy Filippov <vitalif@mail.ru>

ENV OSM_CARTO_VERSION 4.8.0
ENV OSM_BRIGHT_VERSION master
ENV MOD_TILE_VERSION master
ENV PARALLEL_BUILD 4

# ca-certificates & gnupg2 needed to pull nodejs from nodesource repo
ADD etc /etc
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
    less wget sudo curl unzip gdal-bin mapnik-utils apache2 runit autoconf libtool libmapnik-dev apache2-dev libgdal-dev \
    fonts-noto-cjk fonts-noto-hinted fonts-noto-unhinted fonts-hanazono ttf-unifont ca-certificates gnupg2 \
    osm2pgsql libdbd-pg-perl && \
    (curl -L https://deb.nodesource.com/setup_8.x | bash -) && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs build-essential gyp && \
    apt-get clean && rm -rf /var/lib/apt/lists/*
RUN npm install -g --unsafe carto millstone

RUN cd /tmp && \
    wget https://github.com/gravitystorm/openstreetmap-carto/archive/v$OSM_CARTO_VERSION.tar.gz && \
    tar -xzf v$OSM_CARTO_VERSION.tar.gz && rm v$OSM_CARTO_VERSION.tar.gz && \
    mkdir /usr/share/mapnik && \
    mv /tmp/openstreetmap-carto-$OSM_CARTO_VERSION /usr/share/mapnik/

RUN cd /usr/share/mapnik/openstreetmap-carto-$OSM_CARTO_VERSION/ && \
    scripts/get-shapefiles.py && \
    cp project.mml project.mml.orig && \
    cd /usr/share/mapnik/openstreetmap-carto-$OSM_CARTO_VERSION/data && \
    mkdir -p ne_10m_populated_places && \
    cd ne_10m_populated_places && \
    wget http://www.naturalearthdata.com/http//www.naturalearthdata.com/download/10m/cultural/ne_10m_populated_places.zip && \
    unzip ne_10m_populated_places.zip && \
    rm ne_10m_populated_places.zip && \
    shapeindex ne_10m_populated_places.shp && \
    (find /usr/share/mapnik/openstreetmap-carto-$OSM_CARTO_VERSION/data \( -type f -iname "*.zip" -o -iname "*.tgz" \) -delete)

RUN cd /tmp && \
    wget https://github.com/mapbox/osm-bright/archive/$OSM_BRIGHT_VERSION.tar.gz && \
    tar -xzf $OSM_BRIGHT_VERSION.tar.gz && rm $OSM_BRIGHT_VERSION.tar.gz && \
    mv /tmp/osm-bright-$OSM_BRIGHT_VERSION /usr/share/mapnik

# Create symlink for shapefiles
RUN ln -s /usr/share/mapnik/openstreetmap-carto-$OSM_CARTO_VERSION/data /usr/share/mapnik/osm-bright-$OSM_BRIGHT_VERSION/shp

RUN cd /tmp && \
    wget https://github.com/openstreetmap/mod_tile/archive/$MOD_TILE_VERSION.tar.gz && \
    tar -xzf $MOD_TILE_VERSION.tar.gz && \
    rm $MOD_TILE_VERSION.tar.gz && \
    cd /tmp/mod_tile-$MOD_TILE_VERSION/ && ./autogen.sh && ./configure && make -j $PARALLEL_BUILD && make install && make install-mod_tile && \
    cd / && rm -rf /tmp/mod_tile-$MOD_TILE_VERSION

RUN mkdir -p /var/lib/mod_tile && chown www-data:www-data /var/lib/mod_tile
RUN mkdir -p /var/run/renderd  && chown www-data:www-data /var/run/renderd

COPY ./openstreetmap-carto.lua.diff /usr/share/mapnik/openstreetmap-carto-$OSM_CARTO_VERSION/
RUN cd /usr/share/mapnik/openstreetmap-carto-$OSM_CARTO_VERSION && \
    patch openstreetmap-carto.lua < openstreetmap-carto.lua.diff

RUN mkdir -p /etc/service/renderd && mkdir -p /etc/service/apache2
COPY ./apache2/run /etc/service/apache2/run
COPY ./renderd/run /etc/service/renderd/run
RUN chown root:root /etc/service/renderd/run /etc/service/apache2/run
RUN chmod u+x       /etc/service/renderd/run /etc/service/apache2/run

COPY ./tile.load /etc/apache2/mods-available/tile.load
COPY ./apache2/000-default.conf /etc/apache2/sites-enabled/000-default.conf
RUN ln -s /etc/apache2/mods-available/tile.load /etc/apache2/mods-enabled/
COPY ./renderd/renderd.conf /usr/local/etc/renderd.conf

COPY runit_bootstrap /usr/sbin/runit_bootstrap
RUN chmod 755 /usr/sbin/runit_bootstrap

COPY ./osm-loader.pl /osm-loader.pl

EXPOSE 80
ENTRYPOINT ["/usr/sbin/runit_bootstrap"]
