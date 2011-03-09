#!/usr/bin/perl

use warnings;
use strict;

use Getopt::Long;
use HTTP::Status qw/status_message/;
use Time::Local;

sub get_times($)
{
	my $timers = shift;
	(my $Tq, my $Tw, my $Tc, my $Tr, my $Tt) = split(/\//, $timers);
	return ($Tq, $Tw, $Tc, $Tr, $Tt);
}

sub print_times($) {
	my $timers = shift;
	(my $Tq, my $Tw, my $Tc, my $Tr, my $Tt) = split(/\//, $timers);
	print "  time waiting (total)  : $Tq\n";
	print "  time in queues        : $Tw\n";
	print "  time connecting to be : $Tc\n";
	print "  time waiting for be   : $Tr\n";
	print "  total time            : $Tt\n";
}

sub get_termstate($)
{
	my $termstate = shift;
	(my $first_event, my $session_state, my $persistence_cookie, my $persistence_ops) = split(//, $termstate);
	return ($first_event, $session_state, $persistence_cookie, $persistence_ops);
}

sub print_termstate($)
{
	my $termstate = shift;
	(my $first_event, my $session_state, my $persistence_cookie, my $persistence_ops) = split(//, $termstate);
	print "  first event   : ";
	if ($first_event eq 'C') {
		print "unexpectedly aborted by client";
	} elsif ($first_event eq 'S') {
		print "refused by server";
	} elsif ($first_event eq 'P') {
		print "aborted by proxy";
	} elsif ($first_event eq 'R') {
		print "proxy resource exhausted";
	} elsif ($first_event eq 'I') {
		print "internal proxy error (BAD!)"
	} elsif ($first_event eq 'c') {
		print "client-side timeout";
	} elsif ($first_event eq 's') {
		print "server-side timeout";
	} elsif ($first_event eq '-') {
		print "normal";
	} else {
		print "unknown";
	}
	print "\n";
	print "  session state : ";
	if ($session_state eq 'R') {
		print "waiting for valid request";
	} elsif ($session_state eq 'Q') {
		print "waiting in queue (BAD!)";
	} elsif ($session_state eq 'C') {
		print "waiting to connect to BE";
	} elsif ($session_state eq 'H') {
		print "waiting for headers from BE";
	} elsif ($session_state eq 'D') {
		print "in DATA phase";
	} elsif ($session_state eq 'L') {
		print "transmitting LAST data";
	} elsif ($session_state eq 'T') {
		print "request tarpitted";
	} elsif ($session_state eq '-') {
		print "normal";
	} else {
		print "unknown";
	}
	print "\n";
}

sub get_hastate($)
{
	my $hastate = shift;
	(my $actconn, my $feconn, my $beconn, my $srv_conn, my $retries) = split(/\//, $hastate);
	return ($actconn, $feconn, $beconn, $srv_conn, $retries);
}

sub print_hastate($)
{
	my $hastate = shift;
	(my $actconn, my $feconn, my $beconn, my $srv_conn, my $retries) = split(/\//, $hastate);
	print "  active connections    : $actconn\n";
	print "  front-end connections : $feconn\n";
	print "  back-end connections  : $beconn\n";
	print "  this server conns     : $srv_conn\n";
	print "  retries               : $retries\n";
	return ($actconn, $feconn, $beconn, $srv_conn, $retries);
}

sub print_queues($)
{
	my $queues = shift;
	(my $srv_queue, my $be_queue) = split(/\//, $queues);
	print "  srv queue : $srv_queue\n";
	print "  be queue  : $be_queue\n";
}

sub parse_hadate($)
{
	my %monhash = (
		'Jan' => 0,
		'Feb' => 1,
		'Mar' => 2,
		'Apr' => 3,
		'May' => 4,
		'Jun' => 5,
		'Jul' => 6,
		'Aug' => 7,
		'Sep' => 8,
		'Oct' => 9,
		'Nov' => 10,
		'Dec' => 11,
	);
	my $date = shift;
	my $sec = substr($date, 19, 2);
	my $min = substr($date, 16, 2);
	my $hour = substr($date, 13, 2);
	my $mday = substr($date, 1, 2);
	my $month = substr($date, 4, 3);
	my $mon = $monhash{$month};
	my $year = substr($date, 8, 4) - 1900;
	return timelocal($sec, $min, $hour, $mday, $mon, $year);
}

sub handler($$$$$$)
{
	my $action = shift;
	my $server = shift;
	my $client = shift;
	my $proxy = shift;
	my $mintime = shift;
	my $errorsonly = shift;
	my $start_time = undef;
	for (<>) {
		my $date = substr($_, 0, 15) . "\n";
		my $quoteidx = index($_, '"');
		my $query = substr($_, $quoteidx);
		my @fields = split(/\s/, substr($_, 16, $quoteidx-16));
		my $remote = $fields[2];
		if (!($remote =~ /^[0-9]/)) {
			next;
		}
		(my $address, my $ip) = split(/:/, $remote);
		my $hadate = $fields[3];
		my $timestamp = parse_hadate($hadate);
		if ($timestamp < $mintime) {
			next;
		}
		unless (defined($start_time)) {
			$start_time = $timestamp;
		} else {
			# syslog doesn't preserve order, after all
			if ($timestamp < $start_time) {
				$start_time = $timestamp;
			}
		}
		my $frontend = $fields[4];
		(my $be_set, my $backend) = split(/\//, $fields[5]);
		my $timers = $fields[6];
		my $code = $fields[7];
		my $status = ($code == -1) ? "unknown" : status_message($code);
		my $bytes_read = $fields[8];
		my $termstate = $fields[11];
		my $hastate = $fields[12];
		my $queues = $fields[13];
		my $reqheaders = $fields[14];
		my $resheaders = $fields[15];
		if ($errorsonly && $termstate eq "----") {
			next;
		}
		(my $Tq, my $Tw, my $Tc, my $Tr, my $Tt) = get_times($timers);
		(my $first_event, my $session_state, my $persistence_cookie, my $persistence_ops) = get_termstate($termstate);
		if (!$client) {
			if ($first_event eq 'C' or $first_event eq 'c') {
				next;
			}
		}
		if (!$server) {
			if ($first_event eq 'S' or $first_event eq 's') {
				next;
			}
		}
		if (!$proxy) {
			if ($first_event eq 'P' or $first_event eq 'R' or $first_event eq 'I') {
				next;
			}
		}
		(my $actconn, my $feconn, my $beconn, my $srv_conn, my $retries) = get_hastate($hastate);
		if ($action eq "print") {
			print localtime($timestamp) . "\n";
			print "Remote: $remote\n";
			print "Code: $code ($status)\n";
			print "Timers: $timers\n";
			print_times($timers);
			print "Bytes read: $bytes_read\n";
			print "Term state: $termstate\n";
			print_termstate($termstate);
			print "Backend: $backend\n";
			print "HA state:   $hastate\n";
			print_hastate($hastate);
			print "Queues:	 $queues\n";
			print_queues($queues);
			if (defined($reqheaders)) {
				print "Req headers: $reqheaders\n";
			}
			if (defined ($resheaders)) {
				print "Res headers: $resheaders\n";
			}
			print "Query: $query\n";
			print "\n";
		}
		elsif ($action eq "queries") {
			print substr($query, 1, length($query) - 3) . "\n";
		}
		elsif ($action eq "servers") {
			print "$backend\n";
		}
		elsif ($action eq "timestamps") {
			print "$timestamp\n";
		}
	}
}

sub main()
{
	my $action = "print";
	my $server = 0;
	my $client = 0;
	my $proxy = 0;
	my $mintime = 0;
	my $errorsonly = 0;
	GetOptions("client" => \$client,
		"server" => \$server,
		"proxy" => \$proxy,
		"min-time=i" => \$mintime,
		"action=s" => \$action,
		"errors-only" => \$errorsonly);
	if ($action ne "print" && $action ne "queries" && $action ne "servers" && $action ne "timestamps") {
		print "Actions: (print, queries, servers, timestamps)\n";
		exit(1);
	}
	handler($action, $server, $client, $proxy, $mintime, $errorsonly);
}

unless(caller) {
	main();
}

# vim: set noexpandtab ts=4 sw=4:`
