#!/usr/bin/perl

use LoxBerry::System;
use LoxBerry::Log;
use LoxBerry::JSON;
use Getopt::Long;
use OWNet;
#use CGI;
#use warnings;
use strict;
#use Data::Dumper;

# Version of this script
my $version = "2.0.5";

# Command line options
#my $cgi = CGI->new;
#$cgi->import_names('R');

# Globals
my @busses;
my $serverport;
my $error;
my $owserver;
my $error;
my $verboseval="0";
my $verbose;
my $action;

# Logging
# Create a logging object
my $log = LoxBerry::Log->new (  name => "watchdog",
package => '1-wire-ng',
logdir => "$lbplogdir",
addtime => 1,
);

# Commandline options
# CGI doesn't work from other CGI skripts... :-(
#my $cgi = CGI->new;
#my $q = $cgi->Vars;
GetOptions ('verbose=s' => \$verbose,
            'action=s' => \$action);

# Verbose
if ($verbose) {
	$verboseval="1";
        $log->stdout(1);
        $log->loglevel(7);
}

LOGSTART "Starting Watchdog";

# Root
#if ($<) {
#	$log->stdout(1);
#        LOGERR "This script has to be run as root.";
#        exit (1);
#}

# Lock
my $status = LoxBerry::System::lock(lockfile => '1-wire-ng-watchdog', wait => 120);
if ($status) {
    print "$status currently running - Quitting.";
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
if ( $action eq "start" ) {

	&start();

}

elsif ( $action eq "stop" ) {

	&stop();

}

elsif ( $action eq "restart" ) {

	&restart();

}

elsif ( $action eq "check" ) {

	&check();

}

else {

	LOGERR "No valid action specified. action=start|stop|restart|check is required. Exiting.";
	print "No valid action specified. action=start|stop|restart|check is required. Exiting.\n";
	exit(1);

}

LOGEND "This is the end - My only friend, the end...";
LoxBerry::System::unlock(lockfile => '1-wire-ng-watchdog');

exit;


#############################################################################
# Sub routines
#############################################################################

##
## Start
##
sub start
{

	my $exitcode;

	LOGINF "START called...";
	LOGINF "Starting OWServer...";
	system ("sudo systemctl start owserver");
	sleep (1);
	system ("sudo systemctl start owhttpd");
	sleep (1);

	# Bus Config
	my $buscfgfile = $lbpconfigdir . "/busses.json";

	# Connect to OWServer
	eval {
		$owserver = OWNet->new('localhost:' . $owfscfg->{"serverport"} );
	};
	if ($@ || !$owserver) {
		my $error = $@ || 'Unknown failure';
		LOGERR "Could not connect to OWServer - $error";
		LoxBerry::System::write_file($buscfgfile, "{ }");
		return (1);
	};


	# Scan for busses
	my $busses;
	eval {
		$busses = $owserver->dir("/");
	};
	if ($@ || !$busses) {
		my $error = $@ || 'Unknown failure';
		LOGERR "Could not read busses from OWServer - $error Busses: $busses";
		LoxBerry::System::write_file($buscfgfile, "{ }");
		return (1);
	};
	LOGDEB "OWServer Root Folder: $busses";
	
	# Create available busses
	my $jsonobjbus = LoxBerry::JSON->new();
	my $buscfg = $jsonobjbus->open(filename => $buscfgfile);

	# Set default values
	my @temp = split(/,/,$busses);
	my @busses;
	my $newbuscfg;
	foreach (@temp) {
		if ( $_ =~ /^\/bus.*$/ ) {
			my $busname;
			my $busaddress;
			eval {
				$busname = $owserver->read("$_/interface/settings/name");
				$busaddress = $owserver->read("$_/interface/settings/address");
			};
			push (@busses, $_);
			$_ =~ s/^\/bus\.//s;
			LOGDEB "Found Bus bus$_  Name: $busname  Address: $busaddress";
			$newbuscfg->{"bus$_"}->{"name"} = $busname;
			$newbuscfg->{"bus$_"}->{"address"} = $busaddress;
		}
	}
	$jsonobjbus->{jsonobj} = $newbuscfg;
	$jsonobjbus->write();

	# If no busses are configured, enable all
	if (! $owfscfg->{"busses"} ) {
		foreach (@busses) {
			$_ =~ s/^\/bus\.//s;
			$owfscfg->{"busses"}->{"bus$_"} = "true";
		}
		$jsonobjowfs->write();
	}

	# Startup
	my $startup = 0;
	foreach (@busses) {
		$_ =~ s/^\/bus\.//s;
		if ( is_enabled( $owfscfg->{"busses"}->{"bus$_"} ) ) {
			$startup = 1;
			last;
		}
	}
	if ($startup) {
		LOGINF "Starting owfs2mqtt...";
		LOGDEB "Call: $lbpbindir/owfs2mqtt.pl --verbose=$verboseval";
		system("$lbpbindir/owfs2mqtt.pl --verbose=$verboseval");
		$exitcode = $? >> 8;
		if ($exitcode != 0) {
			my $error = $@ || 'Unknown failure';
			LOGERR "Could not start $lbpbindir/owfs2mqtt.pl --verbose=$verboseval - $error";
			return(1);
		} else {
			LOGOK "$lbpbindir/owfs2mqtt.pl --verbose=$verboseval started successfully.";
		}
	} else {
		LOGINF "No Bus enabled. Will not start owfs2mqtt.";
		return(0);
	}

	# Start seperate owfs instances for each found and enabled bus
	foreach (@busses) {
		$_ =~ s/^\/bus\.//s;
		print "Know scanning: $_ And this is: " . $owfscfg->{"busses"}->{"bus$_"} . "\n";
		if ( is_enabled( $owfscfg->{"busses"}->{"bus$_"} ) ) {
			LOGDEB "Call: $lbpbindir/owfs2mqtt.pl --bus=$_ --verbose=$verboseval";
			eval {
				system("$lbpbindir/owfs2mqtt.pl --bus=$_ --verbose=$verboseval &");
			};
			$exitcode = $? >> 8;
			if ($exitcode != 0) {
				my $error = $@ || 'Unknown failure';
				LOGERR "Could not start $lbpbindir/owfs2mqtt.pl --bus=$_ --verbose=$verboseval - $error";
			} else {
				LOGOK "$lbpbindir/owfs2mqtt.pl --bus=$_ --verbose=$verboseval started successfully.";
			}
		}
	}
	return(0);

}

sub stop
{

	LOGINF "STOP called...";
	LOGINF "Stopping OWServer...";
	system ("sudo pkill -f owserver"); # kill needed because stop does take too long (until timeout)
	system ("sudo systemctl stop owserver");
	sleep (1);
	system ("sudo systemctl stop owhttpd");
	sleep (1);

	LOGINF "Stopping owfs2mqtt instances...";
	system ("pkill -f owfs2mqtt.pl");

	LOGOK "Done.";

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
	
	# Creating tmp file with failed checks
	if (!-e "/dev/shm/1-wire-ng-watchdog-fails.dat") {
		my $response = LoxBerry::System::write_file("/dev/shm/1-wire-ng-watchdog-fails.dat", "0");
	}

	# owserver
	$output = qx(sudo systemctl -q status owserver);
	$exitcode  = $? >> 8;
	if ($exitcode != 0) {
		LOGWARN "owServer seems to be dead - Error $exitcode";
		$errors++;
	}

	# owhttpd
	$output = qx(sudo systemctl -q status owhttpd);
	$exitcode  = $? >> 8;
	if ($exitcode != 0) {
		LOGWARN "owhttpd seems to be dead - Error $exitcode";
		$errors++;
	}

	# owfs2mqtt
	$output = qx(pgrep -f owfs2mqtt.pl);
	$exitcode  = $? >> 8;
	if ($exitcode != 0) {
		LOGWARN "owfs2mqtt seems to be dead - Error $exitcode";
		$errors++;
	}

	if ($errors) {
		my $fails = LoxBerry::System::read_file("/dev/shm/1-wire-ng-watchdog-fails.dat");
		chomp ($fails);
		$fails++;
		my $response = LoxBerry::System::write_file("/dev/shm/1-wire-ng-watchdog-fails.dat", "$fails");
		if ($fails > 9) {
			LOGERR "Too many failures. Will stop watchdogging... Check your configuration and start services manually.";
		} else {
			&restart();
		}
	} else {
		LOGOK "All processes seems to be alive. Nothing to do.";	
		my $response = LoxBerry::System::write_file("/dev/shm/1-wire-ng-watchdog-fails.dat", "0");
	}

	return(0);

}

##
## Always execute when Script ends
##
END {

	LOGEND "This is the end - My only friend, the end...";
	LoxBerry::System::unlock(lockfile => '1-wire-ng-watchdog');

}
