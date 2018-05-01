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

my @feeds = RSSTootalizer::Feed->all();
FEED: foreach my $feed (@feeds){
	next FEED unless $feed;
	next FEED unless $feed->{data}->{enabled};
	my $entries = $feed->fetch_entries();
	next FEED unless $entries;
	ENTRY: foreach my $entry ($entries->items){
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

		my $do_post = 0;
		my @filters = $feed->filters();
		foreach my $filter (@filters){
			if ($filter->apply($entry)){
				if ($filter->{data}->{type} eq "white"){
					$do_post = 1;
				} else {
					$do_post = 0;
				}
			}
		}

		if ($do_post){
			my $user = $feed->user();
			my $status = $feed->{data}->{format};
			$status =~ s/{ID}/$entry{id}/g;
			if (defined($entry{title})){
				$status =~ s/{Title}/$entry{title}/g;
			} else {
				$status =~ s/{Title}/No Title/g;
			}
			$status =~ s/{Link}/$entry{link}/g;
			$status =~ s/{Content}/$entry{content}/g;
			$status =~ s/{Author}/$entry{author}/g;
			$status =~ s/{Issued}/$entry{issued}/g;
			$status =~ s/{Modified}/$entry{modified}/g;
			$status =~ s/{Tags}/$entry{tags}/g;

			my %data;
			if (length($status) > 500){
				$status =~ s/^(.{497}).*$/$1.../g;
			}
			$data{status} = $status;

			# Visibility of a toot can be 'direct', 'private', 'unlisted' or 'public'
                        # 'direct' and 'unlisted' are irrelevant
                        # 'private' posts only to followers [default]
                        # 'public' posts to public timelines [ethical issue?]
                        # [* Should be set per feed in the sql db *]
                        # [* Hardcoded here temporarily for testing *]
                        my $visibility = 'public';
                        $data{visibility} = $visibility;

			$ENV{status} = encode_json({%data});

			# encode_json breaks '\n' chars - turns them into '\\n'
                        # Fix them
                        $ENV{status} =~ s/\\\\n/\\n/g;

			open(DATA, "./post_status.bash '$user->{data}->{access_token}' '$user->{data}->{instance}' |");
			my $reply = "";
			{
				local $/ = undef;
				$reply = <DATA>;
			}

			$new_entries += 1;
		}

		my %ne;
		$ne{feed_id} = $feed->{data}->{ID};
		$ne{entry_link} = $entry{link};
		RSSTootalizer::Entry->create(%ne);
	}
}

RSSTootalizer::DB->doUPDATE("UPDATE `users` SET session_id = 'invalid' WHERE TIME_TO_SEC(NOW()) - TIME_TO_SEC(`valid_from`) > 60*60*4;"); # invalidate old sessions

if ($VERBOSE) {
	$new_entries ? ($new_entries > 1 ? print "$new_entries new entries\n" : print "$new_entries new entry\n") : print "No new entries\n";
	print STDOUT "Done\n";
}
