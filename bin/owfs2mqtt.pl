#!/usr/bin/perl

use LoxBerry::System;
use LoxBerry::Log;
use LoxBerry::JSON;
use Getopt::Long;
use Net::MQTT::Simple;
use OWNet;
use Time::HiRes qw ( sleep time );
#use CGI;
#use warnings;
use strict;
use Data::Dumper;

# Version of this script
my $version = "2.0.2";

# Globals
my $now;
my $last;
my $lastdevices = "0";
my $lastvalues = "0";
my %lastvalues;
my %family;
my %values;
my %present;
my %cache;
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
my $mqtt;

# If we were killed...
$SIG{INT} = sub {
        LOGTITLE "MQTT Gateway interrupted by Ctrl-C";
	&mqttpublish ("plugin", "Disconnected");
	LOGEND "End.";
        exit 1;
};

$SIG{TERM} = sub {
        LOGTITLE "MQTT Gateway requested to stop";
	&mqttpublish ("plugin", "Disconnected");
	LOGEND "End.";
        exit 1;
};

# Command line options
#my $cgi = CGI->new;
#$cgi->import_names('R');

# Commandline options
# CGI doesn't work from other CGI skripts... :-(
#my $cgi = CGI->new;
#my $q = $cgi->Vars;
my $verbose;
my $bus;
GetOptions ('verbose=s' => \$verbose,
            'bus=s' => \$bus);

# Logging
# Create a logging object
my $log = LoxBerry::Log->new (  name => "owfs2mqtt",
package => '1-wire-ng',
logdir => "$lbplogdir",
addtime => 1,
);

# Verbose
if ($verbose) {
        $log->stdout(1);
        $log->loglevel(7);
}

LOGSTART "Starting owfs2mqtt";

# Bus to read
if ($bus eq "") {
	$log->stdout(1);
	LOGERR "You have to specify the bus you would like to read. Exiting.";
	exit 1;
} else {
	LOGINF "Reading from Bus.$bus";
	$bus = "/bus." . $bus;
	LOGTITLE "Daemon owfs2mqtt for Bus.$bus";
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
# Refresh Devices
if ( $owfscfg->{"refreshdev"} ) {
	$refresh_devices=$owfscfg->{"refreshdev"};
} else {
	$refresh_devices=300;
}
LOGDEB "Device Refresh: $refresh_devices";

# Refresh Values
if ( $owfscfg->{"refreshval"} ) {
	$refresh_values=$owfscfg->{"refreshval"};
} else {
	$refresh_values=60;
}
LOGDEB "Default Value Refresh: $refresh_values";

# Uncached
if ( is_enabled($owfscfg->{"uncached"}) ) {
	LOGDEB "Default uncached reading.";
	$uncached="/uncached";
} else {
	LOGDEB "Default cached reading.";
	$uncached="";
}

# OWFS Server Port
if ( $owfscfg->{"serverport"} ) {
	$serverport=$owfscfg->{"serverport"};
} else {
	$serverport="4304";
}
LOGDEB "Server Port: $serverport";

# Tempscale
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
if ( !%$mqttcfg ) {
	LOGERR "Cannot open configuration $mqttcfgfile. Exiting.";
	exit (1);
}
# Set defaults
my $mqtttopic = $mqttcfg->{"topic"};
if (!$mqtttopic) {
	$mqtttopic = "owfs";
}
# Check config

# Connect
&mqttconnect();

# Read Device Configuration
my $devcfgfile = $lbpconfigdir . "/devices.json";
my $jsonobjdev = LoxBerry::JSON->new();
my $devcfg = $jsonobjdev->open(filename => $devcfgfile);
if ( !%$devcfg ) {
	LOGERR "Cannot open configuration $devcfgfile. Exiting.";
	exit (1);
}

# Connect to OWServer
$error = owconnect();
if ($error) {
	LOGERR "Error while connecting to OWServer.";
	exit(1);
}

# Infinite Loop
while (1) {

	$now = time();
	my $republish = 0;
	
	# Keepalive message every 60 sec
	if ( $now > $last + 60 ) {
		$last = $now;
		&mqttpublish ("keepaliveepoch", sprintf("%.0f", $now));
	}

	# Scan for devices
	if ( $now > $lastdevices + $refresh_devices ) {
		$lastdevices = time();
		&readdevices();
		$republish = 1;
	}

	# Scan for values - default configs
	if ( $now > $lastvalues + $refresh_values ) {
		$lastvalues = time();
		foreach (@devices) {
			my $publish = 0;
			my $device = $_;
			# Create data structure
			my $busclear = $bus;
			$busclear=~ s/^\///;
			my $uncachedclear;
			if ($uncached) {
				$uncachedclear = "1";
			} else {
				$uncachedclear = "0";
			}
			my %data = ( "address" => "$device",
					"timestamp" => "$lastvalues",
					"bus" => "$busclear",
					"Uncached" => "$uncachedclear"
			);
			# Read devices/values
			my @values = split(/,/,$values{$device});
			foreach (@values) {
				my $value = owreadvalue("$uncached" . "\/$device", "$_");
				$value =~ s/^\s+//;
				if ( $cache{"$device"}{"$_"} eq $value && !$republish ) {
					LOGDEB "Default: Read Value: " . $bus . $uncached . "/" . $device . "/" . $_ . ": " . $value . " -> Value not changed -> skipping";
				} else {
					LOGDEB "Default: Read Value: " . $bus . $uncached . "/" . $device .  "/" . $_ . ": " . $value . " -> Value changed -> publishing";
					$data{"$_"} = $value;
					$cache{"$device"}{"$_"} = $value;
					$publish = 1;
				}
			}
			if ( $present{$device} ) {
				my $value = owreadpresent("$uncached" . "\/$device");
				$value =~ s/^\s+//;
				if ( $cache{"$device"}{"present"} eq $value && !$republish ) {
					LOGDEB "Default: Read Value: " . $bus . $uncached . "/" . $device . "/present: " . $value . " -> Value not changed -> skipping";
				} else {
					LOGDEB "Default: Read Value: " . $bus . $uncached . "/" . $device . "/present: " . $value . " -> Value changed -> publishing";
					$data{"present"} = $value;
					if ($value eq "0") {
						$data{"bus"} = "-1";
					}
					$cache{"$device"}{"present"} = $value;
					$publish = 1;
				}
			}
			# Publish
			if ( $publish || $republish ) {
				my $json = encode_json \%data;
				&mqttpublish($device,$json);
				$publish = 0;
			}
		}
	}
	
	# Scan for values - custom configs
	foreach (@customdevices) {
		my $publish = 0;
		my $device = $_;
		my @values = "";
		my $customuncached = "";
		my $next = $lastvalues{$device} + $devcfg->{"$device"}->{"refresh"};
		if ( $now > $lastvalues{$device} + $devcfg->{"$device"}->{"refresh"} ) {
			$lastvalues{$device} = time();
			# Create data structure
			my $deviceclear = $device;
			$deviceclear =~ s/\W//g;
			my $busclear = $bus;
			$busclear=~ s/^\///;
			my $uncachedclear;
			my %data = ( "address" => "$deviceclear",
					"timestamp" => "$lastvalues",
					"bus" => "$busclear"
			);
			# Read devices/values
			if ( $devcfg->{"$device"}->{"values"} ) {
				@values = split(/,/,$devcfg->{"$device"}->{"values"});
			} else {
				@values = split(/,/,$values{$device});
			}
			if ( $devcfg->{"$device"}->{"uncached"} ) {
				$customuncached = "/uncached";
				$uncachedclear = "1";
			} else {
				$uncachedclear = "0";
			}
			$data{"Uncached"} = $uncachedclear;
			foreach (@values) {
				my $value = owreadvalue("$customuncached" . "/$device", "$_");
				$value =~ s/^\s+//;
				if ( $cache{"$device"}{"$_"} eq $value && !$republish ) {
					LOGDEB "Custom:  Read Value: " . $bus . $customuncached . "/". $device . "/" . $_ . ": " . $value . " -> Value not changed -> skipping";
				} else {
					LOGDEB "Custom:  Read Value: " . $bus . $customuncached . "/" . $device . "/" . $_ . ": " . $value . " -> Value changed -> publishing";
					$data{"$_"} = $value;
					$cache{"$device"}{"$_"} = $value;
					$publish = 1;
				}
			}
			if ( $devcfg->{"$device"}->{"checkpresent"} ) {
				my $value = owreadpresent("$customuncached" . "/$device");
				$value =~ s/^\s+//;
				if ( $cache{"$device"}{"present"} eq $value && !$republish ) {
					LOGDEB "Custom:  Read Value: " . $bus . $customuncached . "/" . $device . "/present: " . $value . " -> Value not changed -> skipping";
				} else {
					LOGDEB "Custom:  Read Value: " . $bus . $customuncached . "/" . $device . "/present: " . $value . " -> Value changed -> publishing";
					$data{"present"} = $value;
					if ($value eq "0") {
						$data{"bus"} = "-1";
					}
					$cache{"$device"}{"present"} = $value;
					$publish = 1;
				}
			}
			# Publish
			if ( $publish || $republish ) {
				my $json = encode_json \%data;
				&mqttpublish($device,$json);
				$publish = 0;
			} 
		}
	}

	# Wait
	sleep 0.1;

}


#############################################################################
# Sub routines
#############################################################################

##
## Read devices from bus
##
sub readdevices
{

	LOGINF "Scanning for devices at $bus...";
	@devices = "";
	my $devices;
	
	# Scan Bus
	eval {
		$devices = $owserver->dir("$bus");
	};
	if ($@ || !$devices) {
		my $error = $@ || 'Unknown failure';
        	LOGERR "An error occurred - $error Devices: $devices";
		exit (1);
	};
	
	# Add manually configured devices 
	foreach (keys %$devcfg) {
		$devices = $devices . ",/" . $_;
	}

	# Set default values
	my @temp = split(/,/,$devices);
	for (@temp) {
		if ( $_ =~ /^\/bus\.\d*\/[0-9a-fA-F]{2}.*$/ ) {
		# if ( $_ =~ /^\/bus\.\d*\/(\d){2}.*$/ ) { # Old
			my $device = $_;
			$device =~ s/^\/bus\.\d*//s;
			$device =~ s/^\/*//s;
			my ($family,$address) = split /\./, $device;
			# Fill hash/array
			$family{$device} = $family;
			# Seperate devices with custom config
			if ( $devcfg->{"$device"}->{"configured"} ) {
				LOGDEB "Custom:  Config for $device found";
				push (@customdevices, $device),
			} else {
				LOGDEB "Default: Config for $device found";
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

##
## Read value from OWServer
##
sub owreadvalue
{

	my ($owdevice, $owvalue) = @_;
	my $value;
	eval {
		$value = $owserver->read( "$bus" . "$owdevice/$owvalue" );
	};
	if ($@ || !$value) {
		my $error = $@ || 'Unknown failure';
        	LOGWARN "An error occurred - $error. Value set to '-9999'";
		$value = "-9999";
	};
	return ($value);

}

##
## Read presents from OWServer
###
sub owreadpresent
{

	my ($owdevice, $owvalue) = @_;
	my $value;
	eval {
		$value = $owserver->read( "$bus" . "$owdevice/present" );
	};
	if (!$value) {
		$value = "0";
	};
	return ($value);

}

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
## Connect to MQTT Broker
##
sub mqttconnect
{

	$ENV{MQTT_SIMPLE_ALLOW_INSECURE_LOGIN} = 1;
	my $mqtt_username;
	my $mqtt_password;
	my $mqttbroker;
	my $mqttport;
	
	# Use MQTT Gateway credentials
	if ( is_enabled( $mqttcfg->{"usemqttgateway"} ) ) {
		LOGINF "Using MQTT Settings from MQTT Gateway Plugin";
		my $plugin = LoxBerry::System::plugindata("mqttgateway");
		# Read MQTT Cred Configuration
		my $mqttgwcfgfile = $lbhomedir . "/config/plugins/" . $plugin->{"PLUGINDB_FOLDER"} . "/cred.json";
		my $jsonobjmqttgw = LoxBerry::JSON->new();
		my $mqttgwcfg = $jsonobjmqttgw->open(filename => $mqttgwcfgfile);
		if ( !%$mqttgwcfg ) {
			LOGERR "Cannot open configuration $mqttgwcfgfile. Exiting.";
			exit (1);
		}
		$mqtt_username = $mqttgwcfg->{"Credentials"}->{"brokeruser"};
		$mqtt_password = $mqttgwcfg->{"Credentials"}->{"brokerpass"};
		$mqttbroker = "localhost";
		$mqttport = "1883";
	# Use own MQTT credentials
	} else {
		LOGINF "Using my own MQTT Settings";
		$mqtt_username = $mqttcfg->{"username"};
		$mqtt_password = $mqttcfg->{"password"};
		$mqttbroker = $mqttcfg->{"server"};
		$mqttport = $mqttcfg->{"port"};
	}
	if (!$mqttbroker || !$mqttport) {
        	LOGERR "MQTT isn't configured completely. I need at least broker and port.";
		exit (1);
	};
	LOGDEB "MQTT Settings: User: $mqtt_username; Pass: $mqtt_password; Broker: $mqttbroker; Port: $mqttport";
	
	# Connect
	eval {
		LOGINF "Connecting to MQTT Broker";
		$mqtt = Net::MQTT::Simple->new($mqttbroker . ":" . $mqttport);
		$mqtt->last_will($mqtttopic . "plugin", "Disconnected", 1);
		if( $mqtt_username and $mqtt_password ) {
			LOGDEB "MQTT Login with Username and Password: Sending $mqtt_username $mqtt_password";
			$mqtt->login($mqtt_username, $mqtt_password);
		}
	};
	if ($@ || !$mqtt) {
		my $error = $@ || 'Unknown failure';
        	LOGERR "An error occurred - $error";
		exit (1);
	};

	# Update Plugin Status
	&mqttpublish ("plugin", "Connected");

	return($error);

};

##
## Publush MQTT Topic
##
sub mqttpublish
{

	my ($owdevice, $devdata) = @_;
	if (!$owdevice || !$devdata) {
		return($error);
	}

	# Clear Name
	my $devname = $devcfg->{"$owdevice"}->{"name"};
	if (!$devname) {
		$devname = $owdevice;
	};

	# Publish
	eval {
		$mqtt->retain($mqtttopic . "/status/" . $devname, "$devdata");
		LOGDEB "Publishing " . $mqtttopic . "/status/" . $devname . " " . $devdata;
	};

	return ($error);

};

##
## Always execute when Script ends
##
#END {
#	&mqttpublish ("/pluginstatus", "Disconnected");
#	LOGEND "End.";
#}
