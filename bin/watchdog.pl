#!/usr/bin/perl

use LoxBerry::System;
use LoxBerry::Log;
use LoxBerry::JSON;
use OWNet;
use CGI;
#use warnings;
use strict;
use Data::Dumper;

# Version of this script
my $version = "0.1.0";

# Command line options
my $cgi = CGI->new;
$cgi->import_names('R');

# Globals
my @busses;
my $serverport;
my $error;
my $owserver;
my $error;
my $verboseval="0";

# Logging
# Create a logging object
my $log = LoxBerry::Log->new (  name => "watchdog",
package => '1-wire-ng',
logdir => "$lbplogdir",
addtime => 1,
);

# Verbose
if ($R::verbose || $R::v) {
	$verboseval="1";
        $log->stdout(1);
        $log->loglevel(7);
}

LOGSTART "Starting Watchdog";

# Root
if ($<) {
        print "This script has to be run as root.\n";
        LOGERR "This script has to be run as root.";
        exit (1);
}


# Read OWFS Configuration
my $owfscfgfile = $lbpconfigdir . "/owfs.json";
my $jsonobjowfs = LoxBerry::JSON->new();
my $owfscfg = $jsonobjowfs->open(filename => $owfscfgfile);
if ( !%$owfscfg ) {
	LOGERR "Cannot open configuration $owfscfgfile. Exiting.";
	exit (1);
}

# Set Defaults from config
# OWFS Server Port
if ( $owfscfg->{"serverport"} ) {
	$serverport=$owfscfg->{"serverport"};
} else {
	$serverport="4304";
}
LOGDEB "Server Port: $serverport";

# Todo
if ( $R::action eq "start" ) {

	&start();

}

elsif ( $R::action eq "stop" ) {

	&stop();

}

elsif ( $R::action eq "restart" ) {

	&restart();

}

elsif ( $R::action eq "check" ) {

	&check();

}

else {

	LOGERR "No valid action specified. action=start|stop|restart|check is required. Exiting.";
	print "No valid action specified. action=start|stop|restart|check is required. Exiting.\n";
	exit(1);

}

exit;


#############################################################################
# Sub routines
#############################################################################

##
## Start
##
sub start
{

	LOGINF "START called...";
	LOGINF "Starting OWServer...";
	system ("systemctl start owserver");
	sleep (1);
	system ("systemctl start owhttpd");
	sleep (1);
	&readbusses();

	LOGINF "Starting owfs2mqtt instances...";
	for (@busses) {

		my $bus = $_;
		$bus =~ s/^\/bus\.//;
		LOGINF "Starting owfs2mqtt for $_...";
		LOGDEB "Call: $lbpbindir/owfs2mqtt.pl bus=$bus verbose=$verboseval";
		system ("su loxberry -c \"$lbpbindir/owfs2mqtt.pl bus=$bus verbose=$verboseval &\"");
	
	}

	return(0);

}

sub stop
{

	LOGINF "STOP called...";
	LOGINF "Stopping OWServer...";
	system ("pkill -f owserver"); # kill needed because stop does take too long (until timeout)
	system ("systemctl stop owserver");
	sleep (1);
	system ("systemctl stop owhttpd");
	sleep (1);

	LOGINF "Stopping owfs2mqtt instances...";
	system ("pkill -f owfs2mqtt.pl");

	return(0);

}

sub restart
{

	LOGINF "RESTART called...";
	&stop();
	sleep (2);
	&start();

	return(0);

}

sub check
{

	LOGINF "CHECK called...";
	my $output;
	my $errors;
	my $exitcode;

	# owserver
	$output = qx(systemctl -q status owserver);
	$exitcode  = $? >> 8;
	if ($exitcode != 0) {
		LOGERR "owServer seems to be dead - Error $exitcode";
		$errors++;
	}

	# owhttpd
	$output = qx(systemctl -q status owhttpd);
	$exitcode  = $? >> 8;
	if ($exitcode != 0) {
		LOGERR "owhttpd seems to be dead - Error $exitcode";
		$errors++;
	}

	# owfs2mqtt
	$output = qx(pgrep -f owfs2mqtt.pl);
	$exitcode  = $? >> 8;
	if ($exitcode != 0) {
		LOGERR "owfs2mqtt seems to be dead - Error $exitcode";
		$errors++;
	}


	if ($errors) {
		&restart();
	} else {
		LOGINF "All processes seems to be alive. Nothing to do.";	
	}

	return(0);

}

##
## Read available busses
##
sub readbusses
{

	# Connect to OWServer
	$error = owconnect();
	if ($error) {
		LOGERR "Error while connecting to OWServer.";
		exit(1);
	}

	LOGINF "Scanning for busses...";
	my $busses;
	
	# Scan for busses
	eval {
		$busses = $owserver->dir("/");
	};
	if ($@ || !$busses) {
		my $error = $@ || 'Unknown failure';
        	LOGERR "An error occurred - $error Busses: $busses";
		exit (1);
	};
	LOGDEB "OWServer Root Folder: $busses";
	
	# Set default values
	my @temp = split(/,/,$busses);
	for (@temp) {
		if ( $_ =~ /^\/bus.*$/ ) {
			LOGDEB "Found Bus $_";
			push (@busses, $_),
		}
	}

	return();

};

##
## Connect to OWServer
##
sub owconnect
{
	eval {
		$owserver = OWNet->new('localhost:' . $owfscfg->{"serverport"} . " -v -" .$owfscfg->{"tempscale"} );
	};
	if ($@ || !$owserver) {
		my $error = $@ || 'Unknown failure';
        	LOGERR "An error occurred - $error";
		exit (1);
	};
	return($error);

};

##
## Always execute when Script ends
##
END {

	LOGEND "This is the end - My only friend, the end...";

}
