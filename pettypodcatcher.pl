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


my $inlinetags = qr{
		     ^(
		      a|abbr|acronym|b|basefont|bdo|big|cite|code|dfn|em|font|
		      i|img|input|kbd|label|q|s|samp|select|small|span|strike|
		      strong|sub|sup|sub|textarea|tt|u|var
		    )$
		 }x;


# go there
my $config = $ARGV[0];
die "No config passed" unless ($config && -f $config);
my ($filename, $filepath) = fileparse($config);
print $filepath, "\n";
chdir $filepath or die "Cannot chdir to $filepath $!\n";

# old informations
my $oldfeeds;
my $oldfeedsfile = 'oldfeeds.db';
if (-e $oldfeedsfile) {
  $oldfeeds = retrieve($oldfeedsfile);
} else {
  die "Couldn't retrieve $oldfeedsfile";
}

# parse the config
my %podcasts;
open (my $fh, "<:encoding(utf-8)", $filename)
  or die "Cannot open $filename $!\n";
while (<$fh>) {
  if (m/([\w-]+)\s+(http.*?)\s*$/) {
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
$ua->show_progress(1);
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
    parse_and_download($response);
  }
}

print "Storing metainfo...";
store $oldfeeds, $oldfeedsfile;

sub parse_and_download {
  my $r = shift;
  my $feedstring = $r->decoded_content;
  my $feed = XML::FeedPP->new($feedstring,
			      utf8_flag => 1,
			      -type => 'string',
			     );
  foreach my $item ($feed->get_item()) {
    my ($enclosure, $title, $url, $link, $body, $date);
    
    # get the enclosure or next
    try {
      # this is undocument, but appears to work
      my $enclosure_val = $item->get_value("enclosure");
      if (defined $enclosure_val) {
	$enclosure = $enclosure_val->{-url};
      }
    } catch { warn $_ };
    next unless $enclosure;

    # get the title and the date
    $title = parse_html($item->title()) || "\n";
    $date = $item->pubDate()            || "\n";
 
    # body processing (to store in the file)
    $body = parse_html(
      $item->get("content:encoded") || $item->description()
     ) || "\n";
    if (my $fullpage = $item->link()) {
      try {
	$body .= "Text dump of $fullpage\n"
	  . parse_html($ua->get($fullpage)->decoded_content)
	    . "\n";
      } catch { warn $_ };
    }
    
    

  }# prepare the file.txt
}


sub create_sensible_filename {
  my $crap = shift;
  $crap =~ s/[^A-Za-z0-9-]/-/gs;
  $crap =~ s/^-*//gs;
  $crap =~ s/-*$//gs;
  $crap =~ s/--+/-/gs;
  return if (length($crap) > 250);
  return if (length($crap) < 3);
  return $crap;
}


sub parse_html {
  my ($html, $dontsavelinks) = @_;
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

