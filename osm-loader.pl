#!/usr/bin/perl
# Конфигурация в переменных окружения:
#
# OSM_CACHE_DIR - путь к директории с временными и загружаемыми файлами
# OSM_INIT - если 1, то при пустой базе инициализировать базу
# OSM_UPDATE_FILE - если 1, то обновлять локальный файл osm.pbf до актуального состояния путём наката дельт
# OSM_EXPIRE - если 1, то вызывать утилиту render_expired
# OSM_METHOD - режим загрузки: osm2pgsql-carto или imposm3-all
# OSM_CARTO_VERSION - для режима osm2pgsql-carto - версия osm-carto. Файлы должны быть в /usr/share/mapnik/openstreetmap-carto-ВЕРСИЯ
# URL_LATEST - URL последней версии .osm.pbf экспортного файла
# URL_UPDATES - URL директории с обновлениями (должна содержать state.txt и дельты)
# PG_ENV_OSM_DB - БД PostGIS
# PG_ENV_OSM_HOST - хост/сокет БД
# PG_ENV_OSM_PORT - порт БД (по умолчанию 5432)
# PG_ENV_OSM_USER - пользователь БД
# PG_ENV_OSM_PASSWORD - пароль пользователя БД

use strict;
use DBI;
use POSIX;

my $dbh;
my $dir = $ENV{OSM_CACHE_DIR} || '/var/lib/mod_tile/downloads';
my $method = $ENV{OSM_METHOD} || 'osm2pgsql-carto';
my $url_latest = $ENV{URL_LATEST} || 'http://download.geofabrik.de/russia-latest.osm.pbf';
my $url_updates = $ENV{URL_UPDATES} || 'http://download.geofabrik.de/russia-updates';

if (!$ENV{PG_ENV_OSM_DB})
{
    fatal("Не задана БД OSM");
}
info("Начато обновлением OSM базы данных: $ENV{PG_ENV_OSM_DB}");
if ($method ne 'osm2pgsql-carto' && $method ne 'imposm3-all')
{
    fatal("Некорректный режим обновления: $method (поддерживаются только osm2pgsql-carto и imposm3-all)");
}
-e $dir || mkdir($dir);
chdir $dir or fatal("Директория $dir не существует");
eval { run_update() };
if ($@)
{
    fatal("Ошибка кода: $@");
}
exit(0);

sub run_update
{
    my $state = parse_geofabrik_state($url_updates, $dir);
    my $dbh = DBI->connect(
        'dbi:Pg:dbname='.$ENV{PG_ENV_OSM_DB}.';host='.$ENV{PG_ENV_OSM_HOST}.';port='.($ENV{PG_ENV_OSM_PORT}||5432),
        $ENV{PG_ENV_OSM_USER}, $ENV{PG_ENV_OSM_PASSWORD}, {AutoCommit => 0, RaiseError => 1}
    );
    my ($version) = eval { $dbh->selectrow_array(
        'SELECT value FROM replication_state WHERE name=? FOR UPDATE', {}, 'osm_version'
    ) };
    if (!$version)
    {
        if (!$ENV{OSM_INIT})
        {
            fatal("БД OSM не инициализирована, запустите скрипт с переменной окружения OSM_INIT=1 для инициализации");
        }
        $dbh->rollback; # иначе postgresql пишет "statements until the end ignored"
        # создаём таблицу и оставляем её заблокированной
        init_state($dbh, $state);
        $dbh->do('CREATE EXTENSION IF NOT EXISTS postgis');
        $dbh->do('CREATE EXTENSION IF NOT EXISTS hstore');
        # качаем дамп
        my ($fn) = $url_latest =~ /([^\/]+)$/so;
        info("Скачивается файл $url_latest");
        system("curl -s -C - -f '$url_latest' -o $dir/$fn");
        if ($? || !-e "$dir/$fn")
        {
            fatal("Не удалось скачать файл $url_latest");
        }
        system("cp $dir/state.txt $dir/$fn.state.txt");
        if ($method eq 'osm2pgsql-carto')
        {
            init_osm2pgsql($dbh, $state->{timestamp} . ' ' . $state->{sequenceNumber}, "$dir/$fn");
        }
        else
        {
            init_imposm3($dbh, $state->{timestamp} . ' ' . $state->{sequenceNumber}, "$dir/$fn");
        }
        $dbh->commit;
        info("База данных OSM $ENV{PG_ENV_OSM_DB} инициализирована версией: ".$state->{timestamp});
    }
    else
    {
        $version = [ split /\s+/, $version ];
        $version = { timestamp => $version->[0], sequenceNumber => $version->[1] };
        my $apply = load_geofabrik_deltas($version, $state, $url_updates, $dir);
        chdir($dir);
        if ($method eq 'osm2pgsql-carto')
        {
            apply_deltas_osm2pgsql($apply);
        }
        else
        {
            apply_deltas_imposm3($apply);
        }
        update_state($dbh, $state);
        $dbh->commit;
        info("База данных OSM $ENV{PG_ENV_OSM_DB} обновлена до версии: ".$state->{timestamp});
        if ($ENV{OSM_EXPIRE})
        {
            system("cat $dir/expire.list | render_expired --map=osm_carto --touch-from=11");
            system("cat $dir/expire.list | render_expired --map=osm_bright --touch-from=11");
        }
    }
    if ($ENV{OSM_UPDATE_FILE})
    {
        apply_deltas_file($url_latest, $url_updates, $dir);
    }
}

sub parse_geofabrik_state
{
    my ($url_updates, $dir) = @_;
    system("curl -s -f '$url_updates/state.txt' -o $dir/state.txt");
    if (-r "$dir/state.txt")
    {
        return parse_geofabrik_state_file("$dir/state.txt");
    }
    fatal("Не удалось скачать файл $url_updates/state.txt");
}

sub parse_geofabrik_state_file
{
    my ($file) = @_;
    my $state;
    if (open FD, "<$file")
    {
        local $/ = undef;
        $state = <FD>;
        close FD;
        $state = { map { (split /\s*=\s*/, $_, 2) } grep { !/^\s*(#.*)?$/so && /=/so } split /\n/, $state };
        if (!$state->{timestamp} || !$state->{sequenceNumber})
        {
            fatal("Файл состояния репликации OSM некорректный, должен содержать строки timestamp=<дата_ISO8601> и sequenceNumber=<число>");
        }
        $state->{timestamp} =~ s/\\//g;
        return $state;
    }
    return undef;
}

sub load_geofabrik_deltas
{
    my ($old_state, $state, $url_updates, $dir) = @_;
    my $i = $old_state->{sequenceNumber};
    my $apply = [];
    while ($i < $state->{sequenceNumber})
    {
        my $subdir = sprintf("%03d/%03d", $i / 1000000, ($i / 1000) % 1000);
        my $fn = sprintf("%03d.osc.gz", $i % 1000);
        if (!-e "$dir/$subdir/$fn")
        {
            info("Скачивается файл дельты $url_updates/$subdir/$fn");
        }
        system("mkdir -p $dir/$subdir && curl -C - -s -f '$url_updates/$subdir/$fn' -o $dir/$subdir/$fn");
        if (-e "$dir/$subdir/$fn")
        {
            push @$apply, "$subdir/$fn";
        }
        else
        {
            unlink("$dir/$subdir/$fn") if -e "$dir/$subdir/$fn";
            fatal("Не удалось скачать файл дельты $url_updates/$subdir/$fn\n");
        }
        $i++;
    }
    return $apply;
}

sub init_state
{
    my ($dbh, $state) = @_;
    $dbh->do('CREATE TABLE IF NOT EXISTS replication_state (name varchar(1024) not null primary key, value text not null)');
    $dbh->do(
        'INSERT INTO replication_state (name, value) VALUES (?, ?)',
        {}, 'osm_version', $state->{timestamp} . ' ' . $state->{sequenceNumber}
    );
}

sub update_state
{
    my ($dbh, $state) = @_;
    $dbh->do(
        'UPDATE replication_state SET value=? WHERE name=?',
        {}, $state->{timestamp} . ' ' . $state->{sequenceNumber}, 'osm_version'
    );
}

sub init_osm2pgsql
{
    my ($dbh, $path) = @_;
    my $carto_dir = '/usr/share/mapnik/openstreetmap-carto-'.$ENV{OSM_CARTO_VERSION};
    if (!$ENV{OSM_CARTO_VERSION})
    {
        fatal("Не задан путь к osm-carto");
    }
    my $cmd =
        "PGPASSWORD='".$ENV{PG_ENV_OSM_PASSWORD}."' osm2pgsql -I -s -c --hstore".
        " --style $carto_dir/openstreetmap-carto.style".
        " --tag-transform-script $carto_dir/openstreetmap-carto.lua".
        " -C 4000 -G -H '".$ENV{PG_ENV_OSM_HOST}."' -U '".$ENV{PG_ENV_OSM_USER}."' -d '".$ENV{PG_ENV_OSM_DB}."'".
        " -P ".($ENV{PG_ENV_OSM_PORT} || 5432)." '$path'";
    system($cmd);
    if ($?)
    {
        fatal("Загрузка полного дампа с помощью osm2pgsql не удалась");
    }
    local $/ = undef;
    my $fd;
    open $fd, "$carto_dir/indexes.sql";
    for my $index (split /;\s*/, <$fd>)
    {
        $dbh->do($index);
    }
    close $fd;
}

sub init_imposm3
{
    my ($dbh, $path) = @_;
    my $cmd =
        "imposm3 import -connection 'postgis://".$ENV{PG_ENV_OSM_USER}.":".$ENV{PG_ENV_OSM_PASSWORD}.
        "@".$ENV{PG_ENV_OSM_HOST}.(($ENV{PG_ENV_OSM_PORT}||5432) != 5432 ? ":".$ENV{PG_ENV_OSM_PORT} : "").
        "/".$ENV{PG_ENV_OSM_DB}."' -cachedir '".$ENV{OSM_CACHE_DIR}."/imposm3-cache' -mapping '/home/imposm3-all.yml' -srid 4326 -diff".
        " -read '$path' -write";
    system($cmd);
    if ($?)
    {
        fatal("Загрузка полного дампа с помощью imposm3 не удалась");
    }
    my $indexes = "SET SEARCH_PATH TO import, public;
CREATE INDEX IF NOT EXISTS osm_polygon_area     ON osm_polygon      (st_area(geometry));
CREATE INDEX IF NOT EXISTS osm_point_tags       ON osm_point        USING gin (tags);
CREATE INDEX IF NOT EXISTS osm_linestring_tags  ON osm_linestring   USING gin (tags);
CREATE INDEX IF NOT EXISTS osm_polygon_tags     ON osm_polygon      USING gin (tags);
CREATE INDEX IF NOT EXISTS osm_relation_tags    ON osm_relation     USING gin (tags);
CREATE INDEX IF NOT EXISTS osm_point_text       ON osm_point        USING gin (to_tsvector('russian', tags::text));
CREATE INDEX IF NOT EXISTS osm_linestring_text  ON osm_linestring   USING gin (to_tsvector('russian', tags::text));
CREATE INDEX IF NOT EXISTS osm_polygon_text     ON osm_polygon      USING gin (to_tsvector('russian', tags::text));
CREATE INDEX IF NOT EXISTS osm_relation_text    ON osm_relation     USING gin (to_tsvector('russian', tags::text))";
    foreach my $index (split /;\n/, $indexes)
    {
        $dbh->do($index);
    }
}

sub apply_deltas_osm2pgsql
{
    my ($apply, $carto_dir) = @_;
    if (@$apply)
    {
        my $cmd =
            "PGPASSWORD='".$ENV{PG_ENV_OSM_PASSWORD}."' osm2pgsql --append -e15 -o '".$ENV{OSM_CACHE_DIR}."/expire.list' -I -s --hstore".
            " --style $carto_dir/openstreetmap-carto.style".
            " --tag-transform-script $carto_dir/openstreetmap-carto.lua".
            " -C 4000 -G -H '".$ENV{PG_ENV_OSM_HOST}."' -U '".$ENV{PG_ENV_OSM_USER}."' -d '".$ENV{PG_ENV_OSM_DB}."'".
            " -P ".($ENV{PG_ENV_OSM_PORT} || 5432)." '".join("' '", @$apply)."'";
        system($cmd);
        if ($?)
        {
            fatal("Загрузка дельт osm2pgsql не удалась");
        }
    }
}

sub apply_deltas_imposm3
{
    my ($apply) = @_;
    my $carto_dir = '/usr/share/mapnik/openstreetmap-carto-'.$ENV{OSM_CARTO_VERSION};
    if (!$ENV{OSM_CARTO_VERSION})
    {
        fatal("Не задан путь к osm-carto");
    }
    if (@$apply)
    {
        my $cmd =
            "imposm3 diff -connection 'postgis://".$ENV{PG_ENV_OSM_USER}.":".$ENV{PG_ENV_OSM_PASSWORD}.
            "@".$ENV{PG_ENV_OSM_HOST}.(($ENV{PG_ENV_OSM_PORT}||5432) != 5432 ? ":".$ENV{PG_ENV_OSM_PORT} : "").
            "/".$ENV{PG_ENV_OSM_DB}."' -cachedir '".$ENV{OSM_CACHE_DIR}."/imposm3-cache' -mapping '/home/imposm3-all.yml' -srid 4326".
            " '".join("' '", @$apply)."'";
        system($cmd);
        if ($?)
        {
            fatal("Загрузка дельт imposm3 не удалась");
        }
    }
}

sub apply_deltas_file
{
    my ($url_latest, $url_updates, $dir) = @_;
    my ($full_fn) = $url_latest =~ /([^\/]+)$/so;
    my $old_state = parse_geofabrik_state_file("$dir/$full_fn.state.txt");
    my $state = parse_geofabrik_state($url_updates, $dir);
    my $apply = load_geofabrik_deltas($old_state, $state, $url_updates, $dir);
    if (@$apply)
    {
        my $cmd = "osmconvert $dir/$full_fn '".join("' '", @$apply)."' -o $dir/new-$full_fn";
        system($cmd);
        if ($?)
        {
            fatal("Обновление локального файла .osm.pbf не удалось");
        }
        system("mv $dir/new-$full_fn $dir/$full_fn");
        system("cp $dir/state.txt $full_fn.state.txt");
    }
}

sub info
{
    my ($msg) = @_;
    print POSIX::strftime("%Y-%m-%d %H:%M:%S", localtime)." [info] $msg\n";
}

sub fatal
{
    my ($msg) = @_;
    eval { $dbh->rollback } if $dbh;
    print POSIX::strftime("%Y-%m-%d %H:%M:%S", localtime)." [error] $msg\n";
    exit(1);
}
