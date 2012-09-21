#!/usr/bin/perl

=head1 AUTHOR

Marco Pessotto, marco@theanarchistlibrary.org

=head1 COPYRIGHT AND LICENSE

No Copyright

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.10.1 or,
at your option, any later version of Perl 5 you may have available.

=cut


use strict;
use warnings;
use utf8;
binmode STDOUT, ":encoding(utf-8)";

use XML::FeedPP;
use HTML::PullParser;
use LWP::UserAgent;
use File::Basename;
use Cwd;
use File::Spec;
use File::Path qw/make_path/;
use Data::Dumper;
use Try::Tiny;
use URI::Split qw/uri_split/;
use Storable;
use Date::Parse;
use Time::Piece;
use Getopt::Long;
use YAML::Any qw/LoadFile/;

my $inlinetags = qr{
		     ^(
		      a|abbr|acronym|b|basefont|bdo|big|cite|code|dfn|em|font|
		      i|img|input|kbd|label|q|s|samp|select|small|span|strike|
		      strong|sub|sup|sub|textarea|tt|u|var
		    )$
		 }x;


my $mediasuffixes = qr{
			\.(
			  mp3|m4a|flv|
			  mp4|aac|avi|
			  ogg|flac|ogm|
			  pdf|m4b|m4v
			)
		    }x;

my $simulate = 0;
my $limitrate = "300k";
my $debug = 0;
my $logfile = "petty.log";

my $options = GetOptions (
  "simulate"     => \$simulate,
  "limit-rate=s" => \$limitrate,
  "debug"        => \$debug,
  "log-file=s"   => \$logfile,
 );

if ($limitrate =~ m/(\d+k?)/) {
  $limitrate = $1;
} else {
  $limitrate = "300k";
}


# go there
my $config = $ARGV[0];
die "No config passed" unless ($config && -f $config);
my ($filename, $filepath) = fileparse($config);
write_log(localtime() . ": switching dir in $filepath");
chdir $filepath or die "Cannot chdir to $filepath $!\n";
write_log("Landed in " . getcwd());

# old informations
my $oldfeeds;
my $oldfeedsfile = 'oldfeeds.db';
if (-e $oldfeedsfile) {
  $oldfeeds = retrieve($oldfeedsfile);
} else {
  $oldfeeds = {}
}

# parse the config
my $podcasts = LoadFile($filename);
exit unless $podcasts;

## setup the user agent
my $fakeuseragent = 'Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.1.16) Gecko/20110929 Iceweasel/3.5.16 (like Firefox/3.5.16)';
my $ua = LWP::UserAgent->new;
$ua->timeout(10);
$ua->agent($fakeuseragent);
# $ua->show_progress(1);
my $treewriter = XML::TreePP->new();



# download the feeds
foreach my $pdc (keys %{$podcasts}) {
  make_path("$pdc");
  my $response;

  # setup the header
  my %header;
  if (my $etag = $oldfeeds->{$pdc}->{etag}) {
    $header{'If-None-Match'} = $etag;
  }
  elsif (my $since = $oldfeeds->{$pdc}->{since}) {
    $header{'If-Modified-Since'} = $since;
  }

  try {
    $response = $ua->get($podcasts->{$pdc}->{url}, %header);
  } catch {
    warn $_;
    next;
  };
  if ($response->is_success) {
    $oldfeeds->{$pdc}->{etag} = $response->header('Etag');
    $oldfeeds->{$pdc}->{since} = $response->header('Last-Modified') || $response->header('Date');
    write_log("Working on $pdc");
    parse_and_download($pdc, $response, $podcasts->{$pdc}->{filter});
  }
}

# all done
write_log("Storing metainfo...");
store $oldfeeds, $oldfeedsfile;
write_log("done on " . localtime());

sub parse_and_download {
  my ($pdc, $r, $filter) = @_;
  my $feedstring = $r->decoded_content;
  my $feed = XML::FeedPP->new($feedstring,
			      utf8_flag => 1,
			      -type => 'string',
			     );
  foreach my $item ($feed->get_item()) {
    my $iteminfo = parse_feed_item($pdc, $item, $filter);
    next unless $iteminfo;
    if (-e $iteminfo->{showinfo}) {
      write_log("skipping " . $iteminfo->{download}
		  . ": " . $iteminfo->{filename}
		    . " already downloaded");
      next;
    }
    my @command = ('wget',
		   "-U", $fakeuseragent,
		   "-O", $iteminfo->{filename},
		   "--limit-rate=$limitrate",
		   "-c",
		   $iteminfo->{download});
    
    if ($simulate) {
      print join(" ", @command), "\n";
      next;
    }

    system(@command) == 0 or die "Execution of @command failed: $?\n";
    print "File saved in " . $iteminfo->{filename} . "\n";
    open (my $fh, ">:encoding(utf-8)", $iteminfo->{showinfo})
      or die "WTF? $!\n";
    print $fh $iteminfo->{body};
    close $fh;
  }
} 


sub parse_feed_item {
  my ($pdc, $item, $filter) = @_;
  my ($enclosure, $title, $url, $link, $body, $date);

  # get the enclosure or next
  try {
    # this is undocument, but appears to work
    my $enclosure_val = $item->get_value("enclosure");
    if (defined $enclosure_val) {
      $enclosure = $enclosure_val->{-url};
    }
  } catch { warn $_; return };
  write_log("No enclosure for " . $item->title()) unless $enclosure;
  return unless $enclosure;

  # get the title and the date
  $title = parse_html($item->title());
  write_log("No title found in $pdc" . Dumper($item)) unless $title;
  return unless $title; # title is mandatory for us
  $body = $title . "\n\n";

  # the time
  $date = $item->pubDate() || localtime->strftime();
  $body .= $date . "\n";

  my ($targetfilename, $suffix) =
    create_sensible_filename($title, $date, $enclosure);
  return unless ($targetfilename and $suffix);
  
  # filtering. return unless it match, return if in ignore
  if ($filter) {
    if (my $match = $filter->{match}) {
      unless ($targetfilename =~ m/$match/i) {
	write_log("Ignoring $targetfilename, doesn't match\n");
	return
      }
    }
    if (my $ignore = $filter->{ignore}) {
      if ($targetfilename =~ m/$ignore/i) {
	write_log("Ignoring $targetfilename, in ignore");
	return
      }
    }
  }
  
  # body processing (to store in the file)
  $body .= parse_html($item->get("content:encoded") || $item->description()) . "\n";
  if (my $fullpage = $item->link()) {
    unless ($fullpage =~ m/$mediasuffixes$/) {
      try {
	$body .= "\nText dump of $fullpage\n"
	  . parse_html($ua->get($fullpage)->decoded_content)
	    . "\n";
      } catch { warn $_ };
    }
  }
  return { filename => File::Spec->catfile(getcwd(), $pdc,
					   $targetfilename . "$suffix"),
	   showinfo => File::Spec->catfile(getcwd(), $pdc,
					   $targetfilename . ".txt"),
	   body     => $body,
	   download => $enclosure };
}

sub create_sensible_filename {
  my ($title, $date, $enclosure) = @_;
  my $output;
  my $time = localtime(str2time($date));
  my $date_prefix = $time->ymd;
  my $name = _normalize_title($title) || "X";
  my ($scheme, $auth, $path, $query, $frag) = uri_split($enclosure);
  return unless $path;
  my ($basename, $remotepath, $suffix) = fileparse($path, $mediasuffixes);
  write_log("NO SUFFIX FOUND! in $basename: skipping") unless $suffix;
  return unless $suffix;
  return $date_prefix . "-" . $name, $suffix;
}

sub _normalize_title {
  my $crap = shift;
  return unless $crap;
  $crap = substr $crap, 0, 200; # be sure to have a sensible “short” name
  $crap =~ s/[^A-Za-z0-9-]/-/gs;
  $crap =~ s/^-*//gs;
  $crap =~ s/-*$//gs;
  $crap =~ s/--+/-/gs;
  if (length($crap) < 2) {
    return undef;
  } else {
    return $crap
  }
}


sub parse_html {
  my $html = shift;
  return " " unless $html;
  if (ref $html eq "HASH") {
    my $tree = $treewriter->write($html);
    $html = $tree;
    undef $tree;
  };
  return "Unknown data" unless (ref $html eq "");
  #  warn "Parsing ", Dumper($html);
  my $p = HTML::PullParser->new(
				doc   => $html,
				start => '"S", tagname',
				end   => '"E", tagname',
				text  => '"T", dtext',
				empty_element_tags => 1,
				marked_sections => 1,
				unbroken_text => 1,
				ignore_elements => [qw(script style)]
			       ) or return undef;
  my @text;
  while (my $token = $p->get_token) {
    my $type = shift @$token;

    # start tag
    if ($type eq 'S') {
      my ($tag, $attrs) = @$token;
      if ($tag =~ m/$inlinetags/s) {
	next
      }
      elsif ($tag eq 'li') {
	push @text, ' * ';
      }
      else {
	push @text, "\n";
      }
    }
    # end tag
    elsif ($type eq 'E') {
      my $tag = shift @$token;
      # empty the links queue at the first ending tag
      unless ($tag =~ m/$inlinetags/s) {
	push @text, "\n";
      }
    }
    # text
    elsif ($type eq 'T') {
      my $txt = shift @$token;
      $txt =~ s/\s+/ /;
      push @text, $txt;
    }
    # wtf?
    else {
      warn "unknon type passed in the parser\n";
    }
  }
  my $result = join("", @text);
  $result =~ s/(\n\s*){2,}/\n/gs;
  return $result;
};

sub write_log {
  my $log = shift;
  if ($debug) {
    print $log, "\n";
  }
  open (my $fh, ">>:encoding(utf-8)", $logfile)
    or die "Cannot open logfile $!\n";
  print $fh $log, "\n";
  close $fh;
}
