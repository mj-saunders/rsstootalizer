#!/usr/bin/perl -w -I.

use strict;
use Data::Dumper;
use URI::Escape;
use JSON;
use RSSTootalizer::Feed;
use RSSTootalizer::Filter;
use RSSTootalizer::User;
use RSSTootalizer::Entry;
use RSSTootalizer::DB;

my $VERBOSE = 1;
my $DEBUG = 1;

our $config = "";
open CONFIG, "rsstootalizer.conf.json" or die "Cannot open rsstootalizer.conf.json";
{
	local $/ = undef;
	$config = <CONFIG>;
}
close CONFIG;
$config = decode_json($config);

sub Error {{{
	my $errormessage = "\nStack Trace:\n";

	my $i=0;
	while ((my @call_details = (caller($i++))) ){
		$errormessage .= $call_details[1].":".$call_details[2]." in function ".$call_details[3]."\n";
	}

	print STDERR $errormessage;
	exit(1);
}}}

# Force Unicode output
binmode STDERR, ":utf8";
binmode STDOUT, ":utf8";

if ($VERBOSE) {print STDOUT "Checking for new entries\n";}
my $new_entries = 0;
my $std_length = 500;
my $link_disp_len = 23;

my @feeds = RSSTootalizer::Feed->all();
# For each Feed stored in database
FEED: foreach my $feed (@feeds){
	next FEED unless $feed;
	next FEED unless $feed->{data}->{enabled};
	# If enabled, fetch the RSS xml
	my $entries = $feed->fetch_entries();
	next FEED unless $entries;

	my @posts;
	# For each entry in the xml file
	ENTRY: foreach my $entry ($entries->items){
		# Does the entry already exist in the database?
		my @seen_entries = $feed->entry_by("entry_link", $entry->link());
		next ENTRY if ((scalar @seen_entries) > 0);

		my %entry;
		$entry{title} = $entry->title();
		$entry{link} = $entry->link();
		$entry{content} = $entry->content()->body;
		$entry{author} = $entry->author();
		$entry{issued} = $entry->issued();
		$entry{modified} = $entry->modified();
		$entry{id} = $entry->id();
		$entry{tags} = join(", ", $entry->tags());

		my @filters = $feed->filters();
		# White/black-list entry based on filter(s)
		foreach my $filter (@filters){
			if ($filter->apply($entry)){
				if ($filter->{data}->{type} eq "white"){
					push(@posts, {%entry});
				}
			}
		}
	} # ENTRY

	if (@posts){
		my $user = $feed->user();
		my %toot;
		$toot{visibility} = 'public';
		# Visibility of a toot can be 'direct', 'private', 'unlisted' or 'public'
		# 'direct' and 'unlisted' are irrelevant, except perhaps for testing
		# 'private' posts only to followers [default]
		# 'public' posts to public timelines [ethical issue?]
		# [* Should be set per feed in the sql db *]
		# [* Hardcoded here temporarily for testing *]

		if ($DEBUG){
			$toot{spoiler_text} = 'testing toot bot';
		}

		if ($feed->{data}->{digest_enabled}){
			my $digest_count = 1;
			my $digest_sig = $feed->{data}->{digest_signature};
			my $post_limit = $feed->{data}->{digest_limit};

			while (@posts){
				my $post_count = scalar(@posts);
				if ( $post_count < $post_limit ){
					$post_limit = $post_count;
				}

				my $snip_length = int( ($std_length - length($digest_sig)) / $post_limit );

				my $status;
				for (my $j=0; $j<$post_limit; $j++){
					my $format = $feed->{data}->{format};
					my %post = %{shift @posts};
					$status = $status . prep_post(\%post, $format, $snip_length);
					$new_entries += 1;
					update_db($feed, $post{link});
				}
				$status = $status . $digest_sig;
				$toot{status} = $status;

				send_post(\%toot, $user);
			} # while @posts
		} else {
			# Post standard toot
			while (@posts){
				my %post = %{shift @posts};
				my $format = $feed->{data}->{format};
				my $status = prep_post(\%post, $format, $std_length);
				$new_entries += 1;

				send_post(\%toot, $user);
				update_db($feed, $post{link});
			}
		}
	} # posts
} # FEED

RSSTootalizer::DB->doUPDATE("UPDATE `users` SET session_id = 'invalid' WHERE TIME_TO_SEC(NOW()) - TIME_TO_SEC(`valid_from`) > 60*60*4;"); # invalidate old sessions

if ($VERBOSE) {
	$new_entries ? ($new_entries > 1 ? print "$new_entries new entries\n" : print "$new_entries new entry\n") : print "No new entries\n";
	print STDOUT "Done\n";
}


### FUNCTIONS ###

sub prep_post {
	# Get passed parameters
	my ($postRef, $status, $snip_length) = @_;
	my %post = %{$postRef};

	if(!defined($post{title})){
		$post{title} = "No Title";
	}

	my @placeholders = qw( {ID} {Title} {Link} {Content} {Author} {Issued} {Modified} {Tags} );
	# Truncation allowances:
	# * ID and Link must be preserved if present as they are url's *
	#     only requires allocation of 23 chars max, more chars will be ignored
	# All other text will be truncated as a whole, but with respect to any static
	# characters within 'Format' text

	my %status_contains;
	#my $raw_content_length = 0;
	my $reserved = 0;
	my $reserve_count = 0;
	foreach (@placeholders){
		my $rawpos = index($status, $_);
		if ($rawpos != -1){
			# Store position of placeholder in status string
			# and length of the text that will replace the placeholder
			my $content_tag = lc(substr($_,1,-1));
			my $content_len = length($post{$content_tag});
			$status_contains{$_} = [$rawpos, $content_len, $content_tag];

			# Remove the processed placeholder so that stored positions
			# are relative to static text within status
			$status =~ s/$_//g;

			if ($_ eq "{ID}" or $_ eq "{Link}"){
				# Reserve space in final post for any url's
				$reserved += $content_len > 23 ? 23 : $content_len;
				$reserve_count += 1;
			}# else {
				# Sum the length required by the text that shall
				# replace any placeholders
			#	$raw_content_length += $content_len;
			#}
		}
	}

	my $trunc_length = $snip_length - $reserved - length($status) - 3; #The 3 is for "..."
	my $content_length_sum = 0;
	my $pos_shift = 0;
	my $reserved_only = 0; #Boolean
	HOLDER: foreach my $holder (sort { $status_contains{$a}[0] <=> $status_contains{$b}[0] } keys %status_contains){
		my $pos = $status_contains{$holder}[0];
		my $content_length = $status_contains{$holder}[1];
		my $content_tag = $status_contains{$holder}[2];

		# ID and Link, being reserved cases, are not measured
		if ($holder ne "{Link}" and $holder ne "{ID}"){
			$content_length_sum += $content_length;
			# Check if content length is within bounds
			if (!$reserved_only){
				if ($content_length_sum < $trunc_length){
					# Add content text to final status)
					substr( $status, ($pos + $pos_shift), 0, $post{$content_tag} );
					$pos_shift += $content_length;
				} else {
					# Remove necessary chars, add three dots
					my $overflow = $content_length_sum - $trunc_length;
					my $remaining = $content_length - $overflow;

					# Truncate latest content piece
					$post{$content_tag} = substr($post{$content_tag}, 0, $remaining) . "...";
					substr( $status, ($pos + $pos_shift), 0, $post{$content_tag} );
					$pos_shift += ($remaining + 3);
					# Prevent further unreserved additions
					$reserved_only = 1;
				}
			}
		} else {
			# Add content text to final status
			substr( $status, ($pos + $pos_shift), 0, $post{$content_tag} );
			$pos_shift += $content_length;
		}

	}

	#print STDOUT "$status\n";
	return $status;
}


sub send_post {
	# Get passed parameters
	my ($tootRef, $user) = @_;
	my %toot = %{$tootRef};

	$ENV{status} = encode_json({%toot});

	# encode_json breaks '\n' chars - turns them into '\\n'
	# Fix them
	$ENV{status} =~ s/\\\\n/\\n/g;

	open(DATA, "./post_status.bash '$user->{data}->{access_token}' '$user->{data}->{instance}' |");
	my $reply = "";
	{
		local $/ = undef;
		$reply = <DATA>;
	}
}


sub update_db {
	# Get passed parameteres
	my ($feed, $link) = @_;

	my %ne;
	$ne{feed_id} = $feed->{data}->{ID};
	$ne{entry_link} = $link;

	RSSTootalizer::Entry->create(%ne);
}
