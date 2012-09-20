#!/usr/bin/perl

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

# go there
my $config = $ARGV[0];
die "No config passed" unless ($config && -f $config);
my ($filename, $filepath) = fileparse($config);
print $filepath, "\n";
chdir $filepath or die "Cannot chdir to $filepath $!\n";
print getcwd();

# old informations
my $oldfeeds;
my $oldfeedsfile = 'oldfeeds.db';
if (-e $oldfeedsfile) {
  $oldfeeds = retrieve($oldfeedsfile);
} else {
  $oldfeeds = {}
}

# parse the config
my %podcasts;
open (my $fh, "<:encoding(utf-8)", $filename)
  or die "Cannot open $filename $!\n";
while (<$fh>) {
  if (m/^([\w-]+)\s+(http.*?)\s*$/) {
    $podcasts{$1} = $2;
  }
}
close $fh;
exit unless %podcasts;

## setup the user agent
my $fakeuseragent = 'Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.1.16) Gecko/20110929 Iceweasel/3.5.16 (like Firefox/3.5.16)';
my $ua = LWP::UserAgent->new;
$ua->timeout(10);
$ua->agent($fakeuseragent);
# $ua->show_progress(1);
my $treewriter = XML::TreePP->new();



# download the feeds
foreach my $pdc (keys %podcasts) {
  make_path("$pdc");
  my $response;
  my $feedfile = $pdc . ".feed";

  # setup the header
  my %header;
  if (my $etag = $oldfeeds->{$pdc}->{etag}) {
    $header{'If-None-Match'} = $etag;
  }
  elsif (my $since = $oldfeeds->{$pdc}->{since}) {
    $header{'If-Modified-Since'} = $since;
  }

  try {
    $response = $ua->get($podcasts{$pdc}, %header);
  } catch {
    print $_;
    next;
  };
  if ($response->is_success) {
    $oldfeeds->{$pdc}->{etag} = $response->header('Etag');
    $oldfeeds->{$pdc}->{since} = $response->header('Last-Modified') || $response->header('Date');
    print "Working on $feedfile\n";
    parse_and_download($pdc, $response);
  }
}

# all done
print "Storing metainfo...";
store $oldfeeds, $oldfeedsfile;
print "done\n";

sub parse_and_download {
  my ($pdc, $r) = @_;
  my $feedstring = $r->decoded_content;
  my $feed = XML::FeedPP->new($feedstring,
			      utf8_flag => 1,
			      -type => 'string',
			     );
  foreach my $item ($feed->get_item()) {
    my $iteminfo = parse_feed_item($pdc, $item);
    next unless $iteminfo;
    if (-e $iteminfo->{showinfo}) {
      # print "skipping " . $iteminfo->{download} . "\n";
      next;
    }
    my @command = ('wget',
		   "-U", $fakeuseragent,
		   "-O", $iteminfo->{filename},
		   "--limit-rate=300k",
		   "-c",
		   $iteminfo->{download});
    
    my $exitcode = 0;
    system(@command) == 0 or $exitcode = ($? >> 8);
    
    # print the info
    if ($exitcode == 0) {
      open (my $fh, ">:encoding(utf-8)", $iteminfo->{showinfo})
	or die "WTF? $!\n";
      print $fh $iteminfo->{body};
      close $fh;
    } elsif ($exitcode == 8) {
      next
    } else {
      die "Unexpected error: $exitcode\n";
    }
  }
} 


sub parse_feed_item {
  my ($pdc, $item) = @_;
  my ($enclosure, $title, $url, $link, $body, $date);

  # get the enclosure or next
  try {
    # this is undocument, but appears to work
    my $enclosure_val = $item->get_value("enclosure");
    if (defined $enclosure_val) {
      $enclosure = $enclosure_val->{-url};
    }
  } catch { warn $_; return };
  warn "No enclosure for " . $item->title() . "\n"  unless $enclosure;
  return                                            unless $enclosure;

  # get the title and the date
  $title = parse_html($item->title());
  warn "No title?\n" unless $title;
  return             unless $title; # title is mandatory for us, ok?
  $body = $title . "\n\n";

  # the time
  $date = $item->pubDate() || localtime->strftime();
  $body .= $date . "\n";

  my ($targetfilename, $suffix) =
    create_sensible_filename($title, $date, $enclosure);
  return unless ($targetfilename and $suffix);
 
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
  warn "NO SUFFIX FOUND! in $basename\n" unless $suffix;
  return unless $suffix;
  return $date_prefix . "-" . $name, $suffix;
}

sub _normalize_title {
  my $crap = shift;
  $crap =~ s/[^A-Za-z0-9-]/-/gs;
  $crap =~ s/^-*//gs;
  $crap =~ s/-*$//gs;
  $crap =~ s/--+/-/gs;
  if ((length($crap) > 2) and (length($crap) < 200)) {
    return $crap
  } else {
    warn "WARNING: resulting filename too long: $crap\n";
    return undef
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

