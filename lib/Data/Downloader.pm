=head1 NAME

Data::Downloader -- Download and organize files using RSS feeds and templates

=head1 SYNOPSIS

    #!/usr/bin/env perl

    use Data::Downloader -init_logging => "DEBUG";
    use strict;

    # Get pictures of apples.  Store them using md5's, make symlinks using date and tags

    my $images = Data::Downloader::Repository->new(
        name           => "images",
        storage_root   => "/usr/local/datastore/data",
        cache_strategy => "Keep",
        feeds          => [
            {
                name => "flickr",
                feed_template => 'http://api.flickr.com/services/feeds/photos_public.gne?tags=<tags>&lang=en-us&format=rss_200',
                file_source => {
                    url_xpath      => 'media:content/@url',
                    filename_xpath => 'media:content/@url',
                    filename_regex => '/([^/]*)$',
                },
                metadata_sources => [
                    { name => 'date_taken', xpath => 'dc:date.Taken' },
                    { name => 'tags',       xpath => 'media:category' },
                ],
            },
        ],
        metadata_transformations => [
            {
                input         => "tags",
                output        => "tag",
                function_name => "split",
            },
        ],
        linktrees => [
            {
                root          => "/usr/local/datastore/by_tag",
                condition     => undef,
                path_template => "<tag>"
            },
            {
                root          => "/usr/local/datastore/by_date",
                condition     => undef,
                path_template => "<date_taken:%Y/%m/%d>"
            },
        ],
    );

    $images->load(speculative => 1) or $images->save;

    for my $feed ($images->feeds) {
        $feed->refresh(tags => "apples");
    }

    $images->download_all;

=head1 DESCRIPTION

Data::Downloader allows one to maintain local repositories of files
and file metadata based on RSS feeds which describe the files.  It
stores files uniquely using MD5 sums, but allows for the creation
and maintenance of trees of symbolic links to the downloaded files.

An SQLite database is used to store both the configuration and information
about the files that have been downloaded.  This file is automatically
created in $HOME/.data_downloader.db (by default).

This distribution also conatins a command-line tool, L<dado>, for
managing the repository.

=head2 CONFIGURATION

See L<Data::Downloader::Config>.

=head2 UPDATING RSS FEEDS

Read about this in L<Data::Downloader::Feed>.

=head2 DOWNLOADING FILES

Take a look at L<Data::Downloader::File>.

=head2 MAINTAINING SYMLINKS

Check out L<Data::Downloader::Linktree>.

=head1 SEE ALSO

L<dado>

L<Data::Downloader::Config>

L<Data::Downloader::Repository>

L<Data::Downloader::Feed>

L<Data::Downloader::DB>

L<Data::Downloader::Cache>

L<Data::Downloader::Linktree>

L<Rose>

=cut

package Data::Downloader;
use Rose::DB::Object::Loader;
use Lingua::EN::Inflect qw/def_noun/;
use Log::Log4perl qw(:easy);

use Data::Downloader::DB;
use Data::Downloader::DB::Object;
use Data::Downloader::DB::Object::Cached;
use Data::Downloader::Config;
use Data::Downloader::MetadataPivot;
use Data::Downloader::FileMetadata;
use strict;

def_noun "metadatum" => "metadata";

our $VERSION = '0.9903';
our $db;
our $useProgressBars;   # set during import to turn on Smart::Comments
our $setupDone;

sub import {
    my ($class,@params) = @_;
    return if $setupDone;
    $setupDone = 1;
    $db = Data::Downloader::DB->new("main");
    if (@params && grep /-init_logging/, @params) {
        my ($level) = grep { /^(DEBUG|INFO|WARN|ERROR|FATAL)$/ } @params;
        $level ||= "INFO";
        my $init = <<"EOT";
           log4perl.rootLogger = $level, Screen
           log4perl.appender.Screen = Log::Log4perl::Appender::ScreenColoredLevels
           log4perl.appender.Screen.layout = Log::Log4perl::Layout::PatternLayout
           log4perl.appender.Screen.layout.ConversionPattern = @{[ $ENV{HARNESS_ACTIVE} ? '#' : '' ]} [%-5p] %d %F{1} (%L) %m %n
EOT
        Log::Log4perl::init(\$init);
    }
    if (@params && grep /-use_progress_bars/, @params) {
        $useProgressBars = 1;
    }
    if (! -s $db->database) {
       INFO "initializing database ".$db->database."\n";
       _initialize_db();
    }
   _setup_classes();
}

sub _initialize_db {
    local $/ = ';';
    while (<DATA>) {
        my $stmt = $_;
        if (/CREATE TRIGGER/) {
            do {
                $stmt .= ( $_ = <DATA> );
            } until /END/ || !defined($_);
        }
        TRACE "SQL:\n$stmt\n";
        next unless $stmt =~ /\w/;
        $db->dbh->do($stmt) or die "failed to execute '$stmt'\n\n".$db->dbh->errstr;
    }
}

sub _setup_classes {
    our $cm = Rose::DB::Object::ConventionManager->new();
    $cm->tables_are_singular(1);
    $cm->singular_to_plural_function(\&Lingua::EN::Inflect::PL);

    my $loader_dynamic = Rose::DB::Object::Loader->new(
        base_class         => "Data::Downloader::DB::Object",
        db                 => $db,
        db_class           => "Data::Downloader::DB",
        class_prefix       => "Data::Downloader",
        convention_manager => $cm,
        post_init_hook     => sub { shift->error_mode('return'); },
        # TODO use log4perl for error mode somehow
    );

    my $loader_cached = Rose::DB::Object::Loader->new(
        base_class         => "Data::Downloader::DB::Object::Cached",
        db                 => $db,
        db_class           => "Data::Downloader::DB",
        class_prefix       => "Data::Downloader",
        convention_manager => $cm,
        post_init_hook     => sub { shift->error_mode('return'); },
    );

    my @config_tables = qw/repository feed disk feed_parameter file_source metadata_source metadata_transformation/;
    my @classes = $loader_dynamic->make_classes(exclude_tables => \@config_tables)
        or LOGDIE "Error: unable to load classes from ".$db->dbh->database;

    push @classes, $loader_cached->make_classes(include_tables => \@config_tables);

    for (@classes) {
        eval "use $_";
        no strict 'refs';
        *{"${_}::init_db"} = sub { Data::Downloader::DB->new_or_cached("main") };
        die "Errors using $_ : $@" if $@ && $@ !~ /Can't locate/;
    }

    Data::Downloader::MetadataPivot->do_setup;
    Data::Downloader::FileMetadata->do_setup;
}

1;

<<"=head1 SCHEMA"; # my trick to put __DATA__ into pod

=head1 SCHEMA

__DATA__

-- See also L<Rose::DB::Object::Loader>

 /*
  * Every table below corresponds to a class named Data::Downloader::<TableName>.
  * Every class has accessors and mutators whose names are the same as the column names.
  * Foreign keys also beget methods in both the parent and child classes, e.g.
  * e.g. $repository->files and $file->repository_obj.
  */

   /*** static tables : populated once during configuration ***/

--- A L<repository|Data::Downloader::Repository> has a L<cache|Data::Downloader::Cache> strategy.

    create table repository (
        id                integer primary key,
        name              varchar(255) not null unique,
        storage_root      text not null,
        file_url_template text,
        cache_strategy    text not null, -- e.g. "LRU" corresponds to Data::Downloader::Cache::LRU
        cache_max_size    integer -- in bytes
    );

--- A L<repository|Data::Downloader::Repository> has many L<feed|Data::Downloader::Feed>s.

    create table feed (
        id                integer primary key,
        repository        integer not null references repository(id),
        name              varchar(255) not null unique,
        feed_template     text
    );

--- A L<repository|Data::Downloader::Repository> has many L<disk|Data::Downloader::Disk>s.

    create table disk (
        id                integer primary key,
        repository        integer not null references repository(id),
        root              varchar(255) not null unique
    );

--- A L<feed|Data::Downloader::Feed> has many default parameters

    create table feed_parameter (
       id    integer primary key,
       feed  integer not null references feed(id),
       name  text not null,
       default_value text
    );

--- A L<feed|Data::Downloader::Feed> has a file source.

    create table file_source (
        feed             integer primary key not null references feed(id),
        url_xpath        text,
        urn_xpath        text,  -- unique identifier for files
        md5_xpath        text,
        filename_xpath   text,
        filename_regex   text   -- apply to whatever is extracted from the xpath
    );

--- A L<feed|Data::Downloader::Feed> has many metadata sources.

    create table metadata_source (
        id               integer primary key,
        feed             integer references feed(id),
        name             text not null unique,
        xpath            text
    );

--- A L<repository|Data::Downloader::Repository> has many L<linktree|Data::Downloader::Linktree>s.

    create table linktree (
        id               integer primary key,
        repository       integer references repository(id),
        root             text,
        condition        text,      -- SQL::Abstract clause
        path_template    text,      -- String::Template string
        unique(root)
    );

--- A L<repository|Data::Downloader::Repository> has many L<metadata_transformations|Data::Downloader::MetadataTransformation>s.

    create table metadata_transformation (
        id               integer primary key,
        input            text, -- references metadata_source.name or this table
        output           text not null,
        repository       integer references repository(id),
        function_name    text, -- function to apply
        function_params  text,
        order_key        integer not null default 1,
        unique(order_key)
    );

   /*** dynamic tables  : populated when files are downloaded, rss feeds are updated, etc. ***/

    create table stat_info (
        id integer primary key,
        repository integer not null references repository(id),
        last_stat_update datetime,
        last_fsck datetime,
        unique(repository)
    );

--- metadata

    create table metadatum (
        id     integer primary key,
        file   integer references file(id),
        name   varchar(255) references metadata_source(name),
        value  text,
        unique (file,name)
    );

--- A L<repository|Data::Downloader::Repository> has many L<file|Data::Downloader::File>s.

    create table file (
       id                 integer primary key,
       repository         integer not null references repository(id),
       filename           text not null,
       md5                char(32),
       url                text,
       urn                text,
       size               integer,
       on_disk            integer, -- boolean
       disk               integer references disk(id),
       atime              datetime, -- stat(file)->atime
       unique(md5),
       unique(filename),
       unique(urn)
    );

--- A L<file|Data::Downloader::File> has many log entries
--- (if $ENV{DATA_DOWNLOADER_GATHER_STATS} is set).

    create table log_entry (
       id integer primary key,
       file integer not null references file(id),
       requested_at datetime not null,
       cache_hit integer, -- boolean
       completed_at datetime,
       prog text, -- $0
       pid integer, -- $$
       uid text, -- $<
       note text -- $ENV{DATA_DOWNLOADER_LOG_NOTE}, e.g. app info
    );

--- A L<file|Data::Downloader::File> has many expirations

    create table file_removal (
       id integer primary key,
       file integer not null references file(id),
       expired_on datetime,
       algorithm, -- the expiration algorithm
       prog text, -- $0
       pid integer, -- $$
       uid text, -- $<
       note text -- $ENV{DATA_DOWNLOADER_FILE_REMOVAL_NOTE},
    );


--- A L<file|Data::Downloader::File> has many symlinks.

    create table symlink (
       id                 integer primary key,
       linkname           text not null, -- linktree.path_template + file's metadata
       file               integer not null references file(id),
       linktree           integer not null references linktree(id),
       unique(linkname)
    );

/***\

=cut

*/

create index symlink_file on symlink(file);
create index symlink_file_linktree on symlink(file,linktree);
create index symlink_linktree on symlink(linktree);

/***\

=head1 AUTHOR

 Brian Duggan

 Phillip Durbin

 Stuart Pineo

 Arnold Martin

 Graham Ollis

 Curt Tilmes

 Michael Walters

=cut

