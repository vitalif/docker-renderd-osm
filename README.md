# docker-renderd-osm

A basic image for rendering/serving tiles using OpenStreetMap data from an external PostgreSQL instance.


## Build instructions

Build using

    docker build -t vitalif/renderd-osm github.com/vitalif/docker-renderd-osm.git

## Running

This container is designed to work with an PostgreSQL instance
with PostGIS and osm2pgsql loaded database (for example,
[openfirmware/docker-postgres-osm](https://registry.hub.docker.com/u/openfirmware/postgres-osm/) +
[openfirmware/docker-osm2pgsql](https://registry.hub.docker.com/u/openfirmware/osm2pgsql/)).

To run this container with local PostgreSQL (not docker-packaged):

    docker run --name renderd -it -d -p 8096:80 \
        -v /var/run/postgresql:/var/run/postgresql \
        --env PG_ENV_OSM_USER=<user> \
        --env PG_ENV_OSM_DB=<database> \
        --env PG_ENV_OSM_HOST=<db_host> \
        --env PG_ENV_OSM_PASSWORD=<password> vitalif/renderd-osm

To run with postgresql from another docker container:

    docker run --name renderd -it -d -p 8096:80 \
        --link postgres-osm:pg \
        --env PG_ENV_OSM_USER=<user> \
        --env PG_ENV_OSM_DB=<database> \
        --env PG_ENV_OSM_HOST=<db_host> \
        --env PG_ENV_OSM_PASSWORD=<password> vitalif/renderd-osm

Also you may override host and port with PG_ENV_OSM_HOST and PG_ENV_OSM_PORT,
and listen address/port with RENDERD_LISTEN_ADDR (default is 0.0.0.0:80).

Once the container is up you should be able to see a small map of the
world once you point your browser to [http://127.0.0.1:8096/osm/0/0/0.png](http://127.0.0.1:8096/osm/0/0/0.png)

## Loading and updating OSM data

Use osm-loader.pl (Russia by now).

## Available Styles

 * [openstreetmap-carto](https://github.com/gravitystorm/openstreetmap-carto),
   available at [http://host/osm/0/0/0.png](http://host/osm/0/0/0.png)
 * [osm-bright](https://github.com/mapbox/osm-bright)
   available at [http://host/osmb/0/0/0.png](http://host/osmb/0/0/0.png)

## About

This Dockerfile has been put together using the [Debian Tileserver Install Guide](https://wiki.debian.org/OSM/tileserver/jessie)
