#!/usr/bin/perl

use LoxBerry::System;
use LoxBerry::Log;
use LoxBerry::JSON;
use Net::MQTT::Simple;
use OWNet;
use Time::HiRes qw ( sleep );
use CGI;
#use warnings;
use strict;

# Version of this script
my $version = "0.1.0";

# Globals
my $now;
my $lastdevices = "0";
my $lastvalues = "0";
my %lastvalues;
my %family;
my %values;
my %present;
my @devices;
my @customdevices;
my $refresh_devices;
my $refresh_values;
my $uncached;
my $bus;
my $temp;
my $serverport;
my $tempscale;
my $owserver;
my $mqtt;
my $error;
my $verbose;

# Command line options
my $cgi = CGI->new;
$cgi->import_names('R');

# Logging
# Create a logging object
my $log = LoxBerry::Log->new (  name => "owfs2mqtt Bus.$R::bus",
package => '1-wire-ng',
logdir => "$lbplogdir",
#filename => "$lbplogdir/watchdog.log",
#append => 1,
);

if ($R::verbose || $R::v) {
        $log->stdout(1);
        $log->loglevel(7);
}

# Bus to read
if ($R::bus eq "") {
	LOGERR "You have to specify the bus you would like to read. Exiting.";
	exit 1;
} else {
	LOGINF "Reading from Bus.$R::bus";
	$bus = "/bus." . $R::bus;
}

# Read OWFS Configuration
my $owfscfgfile = $lbpconfigdir . "/owfs.json";
my $jsonobjowfs = LoxBerry::JSON->new();
my $owfscfg = $jsonobjowfs->open(filename => $owfscfgfile);

if ( $owfscfg->{"refreshdev"} ) {
	$refresh_devices=$owfscfg->{"refreshdev"};
} else {
	$refresh_devices=300;
}
LOGDEB "Device Refresh: $refresh_devices";
if ( $owfscfg->{"refreshval"} ) {
	$refresh_values=$owfscfg->{"refreshval"};
} else {
	$refresh_values=60;
}
LOGDEB "Default Value Refresh: $refresh_values";
if ( $owfscfg->{"uncached"} ) {
	LOGDEB "Default uncached reading."
	$uncached="/uncached";
} else {
	LOGDEB "Default cached reading."
	$uncached="";
}
if ( $owfscfg->{"serverport"} ) {
	$serverport=$owfscfg->{"serverport"};
} else {
	$serverport="4304";
}
LOGDEB "Server Port: $serverport";
if ( $owfscfg->{"tempscale"} ) {
	$tempscale=$owfscfg->{"tempscale"};
} else {
	$tempscale="C";
}
LOGDEB "Tempscale: $tempscale";

# Read MQTT Configuration
my $mqttcfgfile = $lbpconfigdir . "/mqtt.json";
my $jsonobjmqtt = LoxBerry::JSON->new();
my $mqttcfg = $jsonobjmqtt->open(filename => $mqttcfgfile);

# Read Device Configuration
my $devcfgfile = $lbpconfigdir . "/devices.json";
my $jsonobjdev = LoxBerry::JSON->new();
my $devcfg = $jsonobjdev->open(filename => $devcfgfile);

# Create owserver object
$error = owconnect();
if ($error) {
	LOGERR "Error while connecting to OWServer.";
	exit(1);
}

# Infinite Loop
while (1) {

	$now = time();

	# Scan for devices
	if ( $now > $lastdevices + $refresh_devices ) {
		$lastdevices = time();
		&readdevices();
	}

	# Scan for values - default configs
	if ( $now > $lastvalues + $refresh_values ) {
		LOGDEB "Parse Values from Default Config"
		$lastvalues = time();
		foreach (@devices) {
			my $device = $_;
			# Print default values
			my @values = split(/,/,$values{$device});
			foreach (@values) {
				my $value = owreadvalue($device, $_);
				LOGDEB "Read Value: " . $bus . $uncached . $device . " " . $_ . ": " . $value;
			}
			if ( $present{$device} ) {
				my $value = owreadpresent($device);
				LOGDEB "Read Present: " . $bus . $uncached . $device . " " . $_ . ": " . $value;
			}
		}
	}
	
	# Scan for values - custom configs
	foreach (@customdevices) {
		my $device = $_;
		my @values = "";
		my $customuncached = "";
		if ( $now > $lastvalues{$device} + $devcfg->{"$device"}->{"refresh"} ) {
			$lastvalues{$device} = time();
			# Print default values
			if ( $devcfg->{"$device"}->{"values"} ) {
				@values = split(/,/,$devcfg->{"$device"}->{"values"});
			} else {
				@values = split(/,/,$values{$device});
			}
			if ( $devcfg->{"$device"}->{"uncached"} ) {
				$customuncached = "/uncached";
			}
			foreach (@values) {
				#print $bus . $customuncached . $device . " " . $_ . ": " . $owserver->read( "$bus" . "$customuncached" . "$device/$_" ) . "\n";
			}
			if ( $devcfg->{"$device"}->{"checkpresent"} ) {
				#print $bus . $customuncached . $_ . ": " . $owserver -> present( "$bus" . "$customuncached" . "$device" ) . "\n";
			}
		}
	}

	# Wait
	sleep 0.1;

}


#############################################################################
# Sub routines
# ###########################################################################

sub readdevices
{
	LOGINF "Scanning for devices...\n";
	@devices = "";
	my $devices;
	eval {
		$devices = $owserver->dir("$bus");
	};
	if ($@ || !$devices) {
		my $error = $@ || 'Unknown failure';
        	LOGERR "An error occurred - $error";
		exit (1);
	};
	my @temp = split(/,/,$devices);
	for (@temp) {
		if ( $_ =~ /^\/bus\.\d*\/(\d){2}.*$/ ) {
			my $device = $_;
			$device =~ s/^\/bus\.\d*//s;
			my ($tmpbus,$family) = split /\./, $_;
			$family =~ s/^.*\///s;
			# Fill hash/array
			$family{$device} = $family;
			# Seperate devices with custom config
			if ( $devcfg->{"$device"} ) {
				print "Custom:  $device\n";
				push (@customdevices, $device),
			} else {
				print "Default: $device\n";
				push (@devices, $device),
			}
		}
	}
	# Check for Default values
	foreach (@devices) {
		my $values = "";
		my $present = "";
		if ( $family{$_} eq "01" ) { # DS2401
			$present = 1;
		}
		elsif ( $family{$_} eq "05" ) { # DS2405
			$values = "PIO";
		}
		elsif ( $family{$_} eq "10" ) { # DS18S20, DS1920
			$values = "temperature9";
		}
		elsif ( $family{$_} eq "12" ) { # DS2406/07
			$values = "PIO.A";
		}
		elsif ( $family{$_} eq "1D" ) { # DS2423
			$values = "counters.A";
		}
		elsif ( $family{$_} eq "20" ) { # DS2450
			$values = "PIO.A";
		}
		elsif ( $family{$_} eq "21" ) { # DS1921
			$values = "temperature9";
		}
		elsif ( $family{$_} eq "22" ) { # DS1822
			$values = "temperature9";
		}
		elsif ( $family{$_} eq "26" ) { # DS2438
			$values = "VDD,VAD,temperature";
		}
		elsif ( $family{$_} eq "28" ) { # DS18B20
			$values = "temperature9";
		}
		elsif ( $family{$_} eq "29" ) { # DS2408
			$values = "PIO.BYTE";
		}
		elsif ( $family{$_} eq "3A" ) { # DS2413
			$values = "PIO.A";
		} 
		else {
			$values = "";
		}
		# Fill hash
		$values{$_} = $values;
		$present{$_} = $present;
	}
	return();
};

sub owreadvalue
{

	my ($owdevice, $owvalue) = @_;
	my $value;
	eval {
		$value = $owserver->read( "$bus" . "$uncached" . "$owdevice/$owvalue" );
	};
	if ($@ || !$value) {
		my $error = $@ || 'Unknown failure';
        	LOGWARN "An error occurred - $error. Value set to '-9999'";
		$value = "-9999";
	};
	return ($value);

}

sub owreadpresent
{

	my ($owdevice) = @_;
	my $value;
	eval {
		$value = $owserver->present( "$bus" . "$uncached" . "$owdevice" );
	};
	if (!$value) {
		$value = "0";
	};
	return ($value);

}

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

sub mqttconnect
{
	$ENV{MQTT_SIMPLE_ALLOW_INSECURE_LOGIN} = 1;
	
	# Use MQTT Gateway credentials
	# Check if MQTT plugin in installed
	if ( is_enabled( $mqttcfg->{"usemqttgateway"} ) {
	}
	eval {
		$mqtt = Net::MQTT::Simple->new('localhost:1883');
		if($mqtt_username and $mqtt_password) {
			$mqtt->login($mqtt_username, $mqtt_password);
		}
	};
	if ($@ || !$owserver) {
		my $error = $@ || 'Unknown failure';
        	LOGERR "An error occurred - $error";
		exit (1);
	};
	return($error);

};

END {
	$mqtt->disconnect();
	LOGEND "End.";
}
