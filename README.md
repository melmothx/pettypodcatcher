Petty PodCatcher
================

## Yet another podcatcher?

Indeed :-)

## Why?

Because it's fun :-)

## Ok, why is this something different?

This podcatcher doesn't try to be too smart, but has some nice feature.

 - If the file is named podcast.mp3, after the downloading is
   complete, the tracklist, the description and the master page
   referred in the feed, are dumped in the file named podcast.txt
   
 - Suitable to be run in a cronjob.
 
 - Reg-Exp filtering on the episode title (both match/ignore). 

 - Partial content supported (via wget).
 
 - Consistent naming convention: date-title.ext

## Dependencies

This is the list of modules used (many are core modules, others are
well known ones).

 - XML::FeedPP
 - HTML::PullParser
 - LWP::UserAgent
 - Try::Tiny
 - URI::Split
 - Date::Parse
 - Time::Piece
 - Getopt::Long
 - YAML::Any
 - Storable
 - File::Basename
 - Cwd
 - File::Spec
 - File::Path
 - Data::Dumper
 
## Usage

The configuration file is a YAML file:

    PodcastName:
      url: 'http://my-uber-statation/feed.xml'
      filter:
        match: '(episode.*i.*want.*to.*see|other.*episode)'
        ignore: 'crappy.*episode'

The filtering match and ignore are regular expressions. They are
interpolated literally, but case insensitively, with m/$value/i

The matching is done against the resulting filename (taken from the
title + date prefix, so you can ignore, for example, a specific date).

After invoking `pettypodcatcher.pl /path/to/config.yml`, the program
will immediately change directory to the directory with the
configuration file, and will create the needed directories using the
keys of the configuration file (e.g. `PodcastName`), where will dump
the attachments and the descriptions.

A detailed log of the operations will be saved as 'petty.log' (or as
specified by the command line argument `--log-file`.

You can limit the rate of the downloading passing `--limit-rate` and a
numeric value (optionally followed by "k"). See the `wget` manpage for
details. Defaults to 300k.

Example:

    pettypodcatcher.pl --log-file /tmp/mylog \
        --limit-rate 500k ~/music/myconf.yml
