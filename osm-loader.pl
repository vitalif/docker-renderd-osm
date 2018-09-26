#!/usr/bin/perl
# Configuration in env: OSM_CACHE_DIR, OSM_CARTO_DIR, URL_LATEST, URL_UPDATES,
# plus PG_ENV_OSM_{DB,HOST,PORT,USER,PASSWORD} like in README for the render server itself

use strict;
use DBI;
use POSIX;

my $dir = $ENV{OSM_CACHE_DIR} || '/var/lib/mod_tile/downloads';
my $carto_dir = '/usr/share/mapnik/openstreetmap-carto-'.$ENV{OSM_CARTO_VERSION};
my $url_latest = $ENV{URL_LATEST} || 'http://download.geofabrik.de/russia-latest.osm.pbf';
my $url_updates = $ENV{URL_UPDATES} || 'http://download.geofabrik.de/russia-updates';
my $url_gislab_dump = 'http://be.gis-lab.info/data/osm_dump/dump/RU/RU-';
my $url_gislab_diff = 'http://be.gis-lab.info/data/osm_dump/diff/RU/RU-';

-e $dir || mkdir($dir);
chdir $dir or die "Failed to chdir $dir";

my $state = parse_geofabrik_state($url_updates, $dir);
my $dbh = DBI->connect(
    'dbi:Pg:dbname='.$ENV{PG_ENV_OSM_DB}.';host='.$ENV{PG_ENV_OSM_HOST}.';port='.$ENV{PG_ENV_OSM_PORT},
    $ENV{PG_ENV_OSM_USER}, $ENV{PG_ENV_OSM_PASSWORD}, {AutoCommit => 0, RaiseError => 1}
);
my ($version) = eval { $dbh->selectrow_array(
    'SELECT value FROM replication_state WHERE name=? FOR UPDATE', {}, 'osm_version'
) };
if (!$version)
{
    if (!$ENV{OSM_INIT})
    {
        die "Current OSM version missing, run with OSM_INIT=1 environment variable to initialize\n";
    }
    $dbh->rollback;
    my ($fn) = $url_latest =~ /(^\/)+$/so;
    $fn =~ s/^([^\.]+)/$1-$state->{timestamp}/;
    system("curl -s -C - -f '$url_latest' -o $dir/$fn");
    if (!-e "$dir/$fn")
    {
        die "Failed to download $url_latest or $url_updates/state.txt\n";
    }
    load_and_init($dbh, $state->{timestamp} . ' ' . $state->{sequenceNumber}, "$dir/$fn", $carto_dir);
}
else
{
    my $apply = load_geofabrik_deltas($version, $state, $url_updates, $dir);
    apply_deltas($apply, $state->{timestamp} . ' ' . $state->{sequenceNumber}, $dir, $carto_dir);
}
exit;

sub parse_geofabrik_state
{
    my ($url_updates, $dir) = @_;
    system("curl -s - -f '$url_updates/state.txt' -o $dir/state.txt");
    if (!-r "$dir/state.txt")
    {
        die "Error downloading $url_updates/state.txt";
    }
    else
    {
        my $state;
        if (open FD, "<$dir/state.txt")
        {
            local $/ = undef;
            $state = <FD>;
            close FD;
            $state = { map { (split /\s*=\s*/, $_, 2) } grep { !/^\s+(#.*)?$/so } split /\n/, $state };
            if (!$state->{timestamp} || !$state->{sequenceNumber})
            {
                print "State file incorrect, should have timestamp=<ISO8601 date> and sequenceNumber=<integer>\n";
                exit;
            }
            $state->{timestamp} =~ s/\\//g;
        }
    }
    return $state;
}

sub load_and_init
{
    my ($dbh, $state_text, $path, $carto_dir) = @_;
    $dbh->do('CREATE EXTENSION IF NOT EXISTS postgis');
    $dbh->do('CREATE EXTENSION IF NOT EXISTS hstore');
    $dbh->commit;
    $dbh->do('CREATE TABLE IF NOT EXISTS replication_state (name varchar(1024) not null primary key, value text not null)');
    $dbh->do(
        'INSERT INTO replication_state (name, value) VALUES (?, ?)',
        {}, 'osm_version', $state_text
    );
    my $cmd =
        "PGPASSWORD='".$ENV{PG_ENV_OSM_PASSWORD}."' osm2pgsql -I -s -c --hstore".
        " --style $carto_dir/openstreetmap-carto.style".
        " --tag-transform-script $carto_dir/openstreetmap-carto.lua".
        " -C 4000 -G -H '".$ENV{PG_ENV_OSM_HOST}."' -U '".$ENV{PG_ENV_OSM_USER}."' -d '".$ENV{PG_ENV_OSM_DB}."'".
        " -P ".($ENV{PG_ENV_OSM_PORT} || 5432)." '$path'";
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

sub load_gislab_full
{
    my ($url_gislab_dump, $dir) = @_;
    my $url = $url_gislab_dump.POSIX::strftime("%y%m%d", localtime(time-86400)).'.osm.pbf';
    my ($fn) = $url =~ /(^\/)+$/so;
    system("curl -s -C - -f '$url' -o $dir/$fn");
    if (!-e "$dir/$fn")
    {
        die "Failed to download $url\n";
    }
    return "$dir/$fn";
}

sub load_gislab_deltas
{
    my ($version, $url_gislab_diff) = @_;
    my $ymd = [ split /-/, $version ];
    my $cur = POSIX::mktime(0, 0, 0, $ymd->[2]-0, $ymd->[1]-1, $ymd->[0]-1900);
    my $now = time();
    my $apply = [];
    while ($cur+86400 < $now)
    {
        my $next = $cur+86400;
        my $url = $url_gislab_diff.POSIX::strftime("%y%m%d", localtime($cur)).'-'.
            POSIX::strftime("%y%m%d", localtime($next)).'.osc.gz';
        my ($fn) = $url =~ m!/([^/]+)$!so;
        system("curl -C - -s -f '$url' -o $dir/$fn");
        if (-e "$dir/$fn")
        {
            $cur = $next;
            push @$apply, $fn;
        }
        else
        {
            last;
        }
    }
    return $apply;
}

sub load_geofabrik_deltas
{
    my ($version, $state, $url_updates, $dir) = @_;
    my ($timestamp, $i) = split /\s+/, $version;
    my $apply = [];
    while ($i <= $state->{sequenceNumber})
    {
        my $subdir = sprintf("%03d/%03d", $i / 1000000, ($i / 1000) % 1000);
        my $fn = sprintf("%03d.osc.gz", $i % 1000);
        system("mkdir -p $dir/$subdir && curl -C - -s -f '$url_updates/$subdir/$fn' -o $dir/$subdir/$fn");
        if (-e "$dir/$subdir/$fn")
        {
            push @$apply, "$subdir/$fn";
        }
        else
        {
            die "Delta not available: $url_updates/$subdir/$fn\n";
        }
        $i++;
    }
    return $apply;
}

sub apply_deltas
{
    my ($apply, $state_text, $dir, $carto_dir) = @_;
    if (@$apply)
    {
        chdir($dir);
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
            {}, $state_text, 'osm_version'
        );
        $dbh->commit;
        if ($ENV{OSM_EXPIRE})
        {
            system("cat $dir/expire.list | render_expired --map=osm_carto --touch-from=11");
            system("cat $dir/expire.list | render_expired --map=osm_bright --touch-from=11");
        }
    }
    $dbh->commit;
}
