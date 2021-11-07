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
my $version = "2.0.4";

# Globals
my $now;
my $last;
my $lastdevices = "0";
my $lastvalues = "0";
my %lastvalues;
my %family;
my %bus;
my %values;
my %present;
my %cache;
my @devices;
my @customdevices;
my @busses;
my $refresh_devices;
my $refresh_values;
my $looptime = 1;
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
GetOptions ('verbose=s' => \$verbose);

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

LOGTITLE "Daemon owfs2mqtt";
LOGSTART "Starting owfs2mqtt";

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

# Looptime
if ($owfscfg->{"refreshval"} < $looptime) {
	$looptime = $owfscfg->{"refreshval"};
}
LOGDEB "Default Looptime: $looptime";

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
			my $busclear = $bus{$device};
			$busclear =~ s/^\/bus\.//s;
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
					LOGDEB "Default: Read Value: " . $uncached . "/" . $device . "/" . $_ . ": " . $value . " -> Value not changed -> skipping";
				} else {
					LOGDEB "Default: Read Value: " . $uncached . "/" . $device .  "/" . $_ . ": " . $value . " -> Value changed -> publishing";
					$data{"$_"} = $value;
					$cache{"$device"}{"$_"} = $value;
					$publish = 1;
				}
			}
			if ( $present{$device} ) {
				my $value = owreadpresent("$uncached" . "\/$device");
				$value =~ s/^\s+//;
				if ( $cache{"$device"}{"present"} eq $value && !$republish ) {
					LOGDEB "Default: Read Value: " . $uncached . "/" . $device . "/present: " . $value . " -> Value not changed -> skipping";
				} else {
					LOGDEB "Default: Read Value: " . $uncached . "/" . $device . "/present: " . $value . " -> Value changed -> publishing";
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
		my $busclear;
		my $deviceclear;
		my $next = $lastvalues{$device} + $devcfg->{"$device"}->{"refresh"};
		if ( $now > $lastvalues{$device} + $devcfg->{"$device"}->{"refresh"} ) {
			$lastvalues{$device} = time();
			# Create data structure
			$deviceclear = $device;
			$deviceclear =~ s/\W//g;
			if ($bus{$device}) {
				$busclear = $bus{$device};
				$busclear =~ s/^\/bus\.//s;
			}
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
					LOGDEB "Custom:  Read Value: " . $customuncached . "/". $device . "/" . $_ . ": " . $value . " -> Value not changed -> skipping";
				} else {
					LOGDEB "Custom:  Read Value: " . $customuncached . "/" . $device . "/" . $_ . ": " . $value . " -> Value changed -> publishing";
					$data{"$_"} = $value;
					$cache{"$device"}{"$_"} = $value;
					$publish = 1;
				}
			}
			if ( $devcfg->{"$device"}->{"checkpresent"} ) {
				my $value = owreadpresent("$customuncached" . "/$device");
				$value =~ s/^\s+//;
				if ( $cache{"$device"}{"present"} eq $value && !$republish ) {
					LOGDEB "Custom:  Read Value: " . $customuncached . "/" . $device . "/present: " . $value . " -> Value not changed -> skipping";
				} else {
					LOGDEB "Custom:  Read Value: " . $customuncached . "/" . $device . "/present: " . $value . " -> Value changed -> publishing";
					$data{"present"} = $value;
					if ($value eq "0") {
						$data{"bus"} = "-1";
					} else {
						# Figure out on which bus we are
						$data{"bus"} = "-9999";
						foreach (@busses) {
							my $test = owreadpresent($_ . "$customuncached" . "/$device");
							if ($test) {
								my $busclear = $_;
								$busclear =~ s/^\/bus\.//s;
								$data{"bus"} = "$busclear";
								last;
							}
						}
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
	sleep $looptime;

}


#############################################################################
# Sub routines
#############################################################################

##
## Read devices from bus
##
sub readdevices
{
	
	LOGINF "Scanning for connected and configured devices...";
	LOGINF "Scanning for available busses...";
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

	my $devices;
	foreach my $bus (@busses) {

		#$bus = "/bus." . $bus;
		LOGINF "Scanning for devices at $bus...";
		@devices = "";
		my $tempdevices;
		%family = undef;
		%bus = undef;
	
		# Scan Bus
		eval {
			$tempdevices = $owserver->dir("$bus");
		};
		if ($@ || !$tempdevices) {
			my $error = $@ || 'Unknown failure';
        		LOGERR "An error occurred - $error Devices: $tempdevices";
			exit (1);
		};
	
		LOGDEB "Found entries from the bus: $tempdevices";

		# Set default values
		my @temp = split(/,/,$tempdevices);
		for (@temp) {
			LOGDEB "Checking $_...";
			my $device = $_;
			if ( $device =~ /^(\/bus\.\d*)*\/[0-9a-fA-F]{2}\..*$/ ) {
				LOGDEB "This is a device: $device";
				$device =~ s/^\/bus\.\d*//s;
				$device =~ s/^\/*//s;
				my ($family,$address) = split /\./, $device;
				# Fill hashes/arrays
				$family{$device} = $family;
				$bus{$device} = $bus;
				# Seperate devices with custom config
				if ( $devcfg->{"$device"}->{"configured"} ) {
					LOGDEB "Custom:  Config for $device found";
					push (@customdevices, $device);
					# Set lower looptime if needed
					if ( $devcfg->{"$device"}->{"refresh"} && $devcfg->{"$device"}->{"refresh"} < $looptime ) {
						$looptime = $devcfg->{"$device"}->{"refresh"};
						LOGDEB "Change Looptime: $looptime";
					}
				} else {
					LOGDEB "Default: Config for $device found";
					push (@devices, $device),
				}
			} else {
				LOGDEB "This is NOT a device: $device -> ignore";
			}
		}
	
	}

	# Add manually configured devices we haven't mentioned so far
	LOGINF "Checking all manually configured devices...";
	foreach (keys %$devcfg) {
		LOGDEB "Checking $_...";
		if ( $devcfg->{"$_"}->{"configured"} && !defined($family{$_}) ) {
			LOGDEB "Custom:  Config for $_ found";
			push (@customdevices, $_);
			# Set lower looptime if needed
			if ( $devcfg->{"$_"}->{"refresh"} && $devcfg->{"$_"}->{"refresh"} < $looptime ) {
				$looptime = $devcfg->{"$_"}->{"refresh"};
				LOGDEB "Change Looptime: $looptime";
			}
		} else {
			LOGDEB "$_ not manually configured or already known from bus scanning -> ignore";
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
		# Fill hashes
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
	my $value = undef;
	eval {
		$value = $owserver->read( "$owdevice/$owvalue" );
		LOGDEB "Reading " . "$owdevice/$owvalue" . ": Read value is $value";
	};
	if ($@ || !defined($value) ) {
		my $error = $@ || 'Unknown failure';
        	LOGWARN "An error occurred - $error. Read value was $value. Value will be set to '-9999'";
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
	my $devname;
	if ( defined($devcfg->{"$owdevice"}) ) {
		$devname = $devcfg->{"$owdevice"}->{"name"};
	}
	if (!$devname) {
		$devname = $owdevice;
	};

	# Publish
	eval {
		$mqtt->retain($mqtttopic . "/status/" . $devname, "$devdata");
		LOGINF "Publishing " . $mqtttopic . "/status/" . $devname . " " . $devdata;
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
