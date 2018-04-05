#!/usr/bin/perl
# Configuration in env: OSM_CACHE_DIR, OSM_CARTO_DIR + same Docker env vars

use strict;
use DBI;
use POSIX;

my $dir = $ENV{OSM_CACHE_DIR} || '/var/lib/mod_tile/downloads';
my $carto_dir = '/usr/share/mapnik/openstreetmap-carto-'.$ENV{OSM_CARTO_VERSION};

-e $dir || mkdir($dir);
chdir $dir or die "Failed to chdir $dir";

my $dbh = DBI->connect(
    'dbi:Pg:dbname='.$ENV{PG_ENV_OSM_DB}.';host='.$ENV{PG_ENV_OSM_HOST}.';port='.$ENV{PG_ENV_OSM_PORT},
    $ENV{PG_ENV_OSM_USER}, $ENV{PG_ENV_OSM_PASSWORD}, {AutoCommit => 0, RaiseError => 1}
);
my ($version) = eval { $dbh->selectrow_array(
    'SELECT value FROM replication_state WHERE name=? FOR UPDATE', {}, 'osm_version'
) };
if (!$version)
{
    $dbh->rollback;
    $dbh->do('CREATE TABLE IF NOT EXISTS replication_state (name varchar(1024) not null primary key, value text not null)');
    if ($ENV{OSM_INIT})
    {
        my $cur = time()-86400;
        my $fn = 'RU-'.POSIX::strftime("%y%m%d", localtime($cur)).'.osm.pbf';
        my $url = 'http://be.gis-lab.info/data/osm_dump/dump/RU/'.$fn;
        system("curl -s -C - -f '$url' -o $dir/$fn");
        if (-e "$dir/$fn")
        {
            $dbh->do('CREATE EXTENSION IF NOT EXISTS postgis');
            $dbh->do('CREATE EXTENSION IF NOT EXISTS hstore');
            $dbh->commit;
            $dbh->do(
                'INSERT INTO replication_state (name, value) VALUES (?, ?)',
                {}, 'osm_version', POSIX::strftime("%Y-%m-%d", localtime($cur))
            );
            my $cmd =
                "PGPASSWORD='".$ENV{PG_ENV_OSM_PASSWORD}."' osm2pgsql -I -s -c --hstore".
                " --style $carto_dir/openstreetmap-carto.style".
                " --tag-transform-script $carto_dir/openstreetmap-carto.lua".
                " -C 4000 -G -H '".$ENV{PG_ENV_OSM_HOST}."' -U '".$ENV{PG_ENV_OSM_USER}."' -d '".$ENV{PG_ENV_OSM_DB}."'".
                " -P ".($ENV{PG_ENV_OSM_PORT} || 5432)." '$dir/$fn'";
            system($cmd);
            if ($?)
            {
                print "$cmd failed\n";
                $dbh->rollback;
                exit;
            }
            $dbh->commit;
            {
                local $/ = undef;
                my $fd;
                open $fd, "$carto_dir/indexes.sql";
                for my $index (split /;\s*/, <$fd>)
                {
                    $dbh->do($index);
                }
                close $fd;
            }
            $dbh->commit;
        }
        else
        {
            print "Failed to download $url\n";
        }
    }
    else
    {
        print "Current OSM version missing, run with OSM_INIT=1 environment variable to initialize\n";
    }
    exit;
}

my $ymd = [ split /-/, $version ];
my $cur = POSIX::mktime(0, 0, 0, $ymd->[2]-0, $ymd->[1]-1, $ymd->[0]-1900);
my $now = time();
my $apply = [];
while ($cur+86400 < $now)
{
    my $next = $cur+86400;
    my $fn = 'RU-'.POSIX::strftime("%y%m%d", localtime($cur)).'-'.POSIX::strftime("%y%m%d", localtime($next)).'.osc.gz';
    my $url = 'http://be.gis-lab.info/data/osm_dump/diff/RU/'.$fn;
    system("curl -C - -s -f '$url' -o $dir/$fn");
    $cur = $next;
    if (-e "$dir/$fn")
    {
        push @$apply, $fn;
    }
    else
    {
        last;
    }
}
if (@$apply)
{
    my $cmd =
        "PGPASSWORD='".$ENV{PG_ENV_OSM_PASSWORD}."' osm2pgsql --append -e15 -o $dir/expire.list -I -s --hstore".
        " --style $carto_dir/openstreetmap-carto.style".
        " --tag-transform-script $carto_dir/openstreetmap-carto.lua".
        " -C 4000 -G -H '".$ENV{PG_ENV_OSM_HOST}."' -U '".$ENV{PG_ENV_OSM_USER}."' -d '".$ENV{PG_ENV_OSM_DB}."'".
        " -P ".($ENV{PG_ENV_OSM_PORT} || 5432)." '".join("' '", @$apply)."'";
    system($cmd);
    if ($?)
    {
        print "$cmd failed\n";
        $dbh->rollback;
        exit;
    }
    $dbh->do(
        'UPDATE replication_state SET value=? WHERE name=?',
        {}, POSIX::strftime("%Y-%m-%d", localtime($cur)), 'osm_version'
    );
    $dbh->commit;
    if ($ENV{OSM_EXPIRE})
    {
        system("cat $dir/expire.list | render_expired --map=osm_carto --touch-from=11");
        system("cat $dir/expire.list | render_expired --map=osm_bright --touch-from=11");
    }
}
$dbh->commit;
exit;
