#!/usr/bin/perl

# Copyright 2019 Michael Schlenstedt, michael@loxberry.de
#                Christian Fenzl, christian@loxberry.de
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


##########################################################################
# Modules
##########################################################################

# use Config::Simple '-strict';
# use CGI::Carp qw(fatalsToBrowser);
use CGI;
use LoxBerry::System;
#use LoxBerry::Web;
use LoxBerry::JSON; # Available with LoxBerry 2.0
#require "$lbpbindir/libs/LoxBerry/JSON.pm";
use LoxBerry::Log;
use Time::HiRes qw ( sleep );
use warnings;
use strict;
use Data::Dumper;
use OWNet;

##########################################################################
# Variables
##########################################################################

my $log;

# Read Form
my $cgi = CGI->new;
my $q = $cgi->Vars;

my $version = LoxBerry::System::pluginversion();
my $template;

# Language Phrases
my %L;

# Globals 
my %pids;
my $CFGFILEDEVICES = $lbpconfigdir . "/devices.json";
my $CFGFILEMQTT = $lbpconfigdir . "/mqtt.json";
my $CFGFILEOWFS = $lbpconfigdir . "/owfs.json";

##########################################################################
# AJAX
##########################################################################

if( $q->{ajax} ) {
	
	## Handle all ajax requests 
	require JSON;
	# require Time::HiRes;
	my %response;
	ajax_header();

	# Save MQTT Settings
	if( $q->{ajax} eq "savemqtt" ) {
		$response{error} = &savemqtt();
		print JSON->new->canonical(1)->encode(\%response);
	}
	
	# Restart services
	if( $q->{ajax} eq "restartservices" ) {
		$response{error} = &restartservices();
		print JSON->new->canonical(1)->encode(\%response);
	}
	
	# Save OWFS Settings
	if( $q->{ajax} eq "saveowfs" ) {
		$response{error} = &saveowfs();
		my $errors = &searchdevices(); # Always create devices.json, but ignore errors
		print JSON->new->canonical(1)->encode(\%response);
	}
	
	# Save Device Settings
	if( $q->{ajax} eq "savedevice" ) {
		$response{error} = &savedevice();
		print JSON->new->canonical(1)->encode(\%response);
	}


	# Get pids
	if( $q->{ajax} eq "getpids" ) {
		pids();
		$response{pids} = \%pids;
		print JSON->new->canonical(1)->encode(\%response);
	}
	
	# Get config
	if( $q->{ajax} eq "getconfig" ) {
		my $content;
		if ( !$q->{config} ) {
			$response{error} = "1";
			$response{message} = "No config given";
		}
		elsif ( !-e $lbpconfigdir . "/" . $q->{config} . ".json" ) {
			$response{error} = "1";
			$response{message} = "Config file does not exist";
		}
		else {
			# Config
			my $cfgfile = $lbpconfigdir . "/" . $q->{config} . ".json";
			$content = LoxBerry::System::read_file("$cfgfile");
			print $content;
		}
		print JSON->new->canonical(1)->encode(\%response) if !$content;
	}
	
	# Scan Devices
	if( $q->{ajax} eq "searchdevices" ) {
		$response{error} = &searchdevices();
		print JSON->new->canonical(1)->encode(\%response);
	}
	
	# Delete Devices
	if( $q->{ajax} eq "deletedevice" ) {
		if ( !$q->{device} ) {
			$response{error} = "1";
			$response{message} = "No device given";
		}
		$response{error} = &deletedevice($q->{device});
		print JSON->new->canonical(1)->encode(\%response);
	}
	
	# Get single device config
	if( $q->{ajax} eq "getdeviceconfig" ) {
		if ( !$q->{device} ) {
			$response{error} = "1";
			$response{message} = "No device given";
		}
		else {
			# Get config
			%response = &getdeviceconfig ( $q->{device} );
		}
		print JSON->new->canonical(1)->encode(\%response);
	}
	
	exit;

##########################################################################
# Normal request (not AJAX)
##########################################################################

} else {
	
	require LoxBerry::Web;
	
	# Init Template
	$template = HTML::Template->new(
	    filename => "$lbptemplatedir/settings.html",
	    global_vars => 1,
	    loop_context_vars => 1,
	    die_on_bad_params => 0,
	);
	%L = LoxBerry::System::readlanguage($template, "language.ini");
	
	# First time preparation - to create all nessassery config files
	if (!-e "$CFGFILEDEVICES") {
		my $errors =  &searchdevices();
	}
	
	# Default is owfs form
	$q->{form} = "owfs" if !$q->{form};

	if ($q->{form} eq "owfs") { &form_owfs() }
	elsif ($q->{form} eq "devices") { &form_devices() }
	elsif ($q->{form} eq "mqtt") { &form_mqtt() }
	elsif ($q->{form} eq "log") { &form_log() }

	# Print the form
	&form_print();
}

exit;


##########################################################################
# Form: OWFS
##########################################################################

sub form_owfs
{
	$template->param("FORM_OWFS", 1);
	return();
}


##########################################################################
# Form: DEVICES
##########################################################################

sub form_devices
{
	$template->param("FORM_DEVICES", 1);
	return();
}

##########################################################################
# Form: MQTT
##########################################################################

sub form_mqtt
{
	$template->param("FORM_MQTT", 1);
	my $lbversion = version->parse(vers_tag(LoxBerry::System::lbversion()));
	$lbversion =~ s/^v(\d+)\..*/$1/r; # Major Version, e. g. "2"
	$template->param("MQTTGATEWAY_LB2", 1) if($lbversion < 3);
	return();
}


##########################################################################
# Form: Log
##########################################################################

sub form_log
{
	$template->param("FORM_LOG", 1);
	$template->param("LOGLIST", LoxBerry::Web::loglist_html());
	return();
}

##########################################################################
# Print Form
##########################################################################

sub form_print
{
	
	# Navbar
	our %navbar;

	$navbar{10}{Name} = "$L{'COMMON.LABEL_OWFS'}";
	$navbar{10}{URL} = 'index.cgi?form=owfs';
	$navbar{10}{active} = 1 if $q->{form} eq "owfs";
	
	$navbar{20}{Name} = "$L{'COMMON.LABEL_DEVICES'}";
	$navbar{20}{URL} = 'index.cgi?form=devices';
	$navbar{20}{active} = 1 if $q->{form} eq "devices";
	
	$navbar{30}{Name} = "$L{'COMMON.LABEL_MQTT'}";
	$navbar{30}{URL} = 'index.cgi?form=mqtt';
	$navbar{30}{active} = 1 if $q->{form} eq "mqtt";
	
	$navbar{98}{Name} = "$L{'COMMON.LABEL_LOG'}";
	$navbar{98}{URL} = 'index.cgi?form=log';
	$navbar{98}{active} = 1 if $q->{form} eq "log";

	#$navbar{99}{Name} = "$L{'COMMON.LABEL_CREDITS'}";
	#$navbar{99}{URL} = 'index.cgi?form=credits';
	#$navbar{99}{active} = 1 if $q->{form} eq "credits";
	
	# Template
	LoxBerry::Web::lbheader($L{'COMMON.LABEL_PLUGINTITLE'} . " V$version", "https://wiki.loxberry.de/plugins/1_wire_ng/start", "");
	print $template->output();
	LoxBerry::Web::lbfooter();
	
	exit;

}


######################################################################
# AJAX functions
######################################################################

sub ajax_header
{
	print $cgi->header(
			-type => 'application/json',
			-charset => 'utf-8',
			-status => '200 OK',
	);	
}	

sub pids
{
	$pids{'owserver'} = trim(`pgrep -f owserver`) ;
	$pids{'owhttpd'} = trim(`pgrep -f owhttpd`) ;
	$pids{'owfs2mqtt'} = trim(`pgrep -d , -f owfs2mqtt`) ;
	return();
}

sub deletedevice
{
 	my $device = $_[0];
 	my $errors;
 	if (!$device) {
 		$errors++;
 	} else {
 		# Devices config
 		my $jsonobjdevices = LoxBerry::JSON->new();
 		my $cfgdevices = $jsonobjdevices->open(filename => $CFGFILEDEVICES);
 		delete $cfgdevices->{$device};
 		$jsonobjdevices->write();
 	}
 	return ($errors);
}

sub getdeviceconfig
{
	my $device = $_[0];
	my %response;
	if (!$device) {
		$response{error} = 1;
		$response{message} = "No device given.";
	} else {
		my $jsonobjdevices = LoxBerry::JSON->new();
		my $cfgdevices = $jsonobjdevices->open(filename => $CFGFILEDEVICES);
		if ($cfgdevices->{$device}) {
			$response{address} = $cfgdevices->{$device}->{address};
			$response{name} = $cfgdevices->{$device}->{name};
			$response{configured} = $cfgdevices->{$device}->{configured};
			$response{refresh} = $cfgdevices->{$device}->{refresh};
			$response{uncached} = $cfgdevices->{$device}->{uncached};
			$response{values} = $cfgdevices->{$device}->{values};
			$response{checkpresent} = $cfgdevices->{$device}->{checkpresent};
			$response{error} = 0;
			$response{message} = "Device data read successfully.";
		} else {
			$response{error} = 1;
			$response{message} = "Device does not exist.";
		}
	}
	return (%response);
}

sub savedevice
{
	my $errors;
	
	# Devices Config
	my $jsonobjdevices = LoxBerry::JSON->new();
	my $cfgdevices = $jsonobjdevices->open(filename => $CFGFILEDEVICES);
	my $address = $q->{address};
	
	# OWFS Config
	my $jsonobjow = LoxBerry::JSON->new();
	my $cfgow = $jsonobjow->open(filename => $CFGFILEOWFS);
 	
	# Delete old entries - in case of a Address change delete device and (new) address
	delete $cfgdevices->{$q->{device}};
	delete $cfgdevices->{$q->{address}};
	
	# Connect to owserver
	my $owserver;
	eval {
		$owserver = OWNet->new('localhost:' . $cfgow->{"serverport"} . " -v -" .$cfgow->{"tempscale"} );
	};
	if ($@ || !$owserver) {
		$errors++;
	};

	# Check Type
	my $type;
	eval {
		$type = $owserver->read("/$address/type");
	};
	if ($@ || !$type) {
		$errors++;
		$type = "Unknown";
	};
	
	# Save
	$cfgdevices->{$address}->{name} = $q->{name};
	$cfgdevices->{$address}->{address} = $q->{address};
	my $configured =  is_enabled ($q->{configured}) ? 1 : 0;
	$cfgdevices->{$address}->{configured} = $configured;
	$q->{refresh} =~ s/,/\./g;
	$cfgdevices->{$address}->{refresh} = $q->{refresh};
	my $uncached =  is_enabled ($q->{uncached}) ? 1 : 0;
	$cfgdevices->{$address}->{uncached} = $uncached;
	my $checkpresent =  is_enabled ($q->{checkpresent}) ? 1 : 0;
	$cfgdevices->{$address}->{checkpresent} = $checkpresent;
	$cfgdevices->{$address}->{values} = $q->{values};
	$cfgdevices->{$address}->{type} = $type;
	$jsonobjdevices->write();

	return ($errors);
}

sub searchdevices
{
 	my $errors;
	
 	# Devices config
 	my $jsonobjdevices = LoxBerry::JSON->new();
 	my $cfgdevices = $jsonobjdevices->open(filename => $CFGFILEDEVICES);
	
 	# Clear content
	#foreach ( keys %$cfgdev ) { delete $cfgdev->{$_}; }

	# OWFS Config
	my $jsonobjow = LoxBerry::JSON->new();
	my $cfgow = $jsonobjow->open(filename => $CFGFILEOWFS);
 	
	# Connect to owserver
	my $owserver;
	eval {
		$owserver = OWNet->new('localhost:' . $cfgow->{"serverport"} . " -v -" .$cfgow->{"tempscale"} );
	};
	if ($@ || !$owserver) {
		$errors++;
		return($errors);
	};
	
	# Scan Bus
	my $devices;
	eval {
		$devices = $owserver->dir("/");
	};
	if ($@ || !$devices) {
		$errors++;
		return($errors);
	};
	
	my @devices = split(/,/,$devices);
	for ( @devices ) {
		if ( $_ =~ /^\/[0-9a-fA-F]{2}.*$/ ) {
		#if ( $_ =~ /^\/(\d){2}.*$/ ) { # Old
			my $name = $_;
			$name =~ s/^\///g;
			# Check if config already exists
			if ( $cfgdevices->{$name} ) {
				next;
			} else {
				# Add device to config
				my $type;
				eval {
					$type = $owserver->read("/$name/type");
				};
				if ($@ || !$type) {
					$errors++;
					$type = "Unknown";
				};
				$cfgdevices->{$name}->{name} = "$name";
				$cfgdevices->{$name}->{address} = "$name";
				$cfgdevices->{$name}->{type} = "$type";
				$cfgdevices->{$name}->{configured} = "0";
				$cfgdevices->{$name}->{refresh} = "60";
				$cfgdevices->{$name}->{uncached} = "1";
				$cfgdevices->{$name}->{checkpresent} = "0";
				$cfgdevices->{$name}->{values} = "";
			}
		}
	}

	$jsonobjdevices->write();

 	return ($errors);
}

sub savemqtt
{
	# Save mqtt.json
	my $errors;
	my $jsonobj = LoxBerry::JSON->new();
	my $cfg = $jsonobj->open(filename => $CFGFILEMQTT);
	$cfg->{topic} = $q->{topic};
	$jsonobj->write();
	
	# Save mqtt_subscriptions.cfg for MQTT Gateway
	my $subscr_file = $lbpconfigdir."/mqtt_subscriptions.cfg";
	eval {
		open(my $fh, '>', $subscr_file);
		print $fh $q->{topic} . "/#\n";
		close $fh;
	};
	if ($@) {
		$errors++;
	}
	
	return ($errors);
}

sub saveowfs
{
	# Save owfs.json
	
	my $errors;
	my $jsonobj = LoxBerry::JSON->new();
	my $cfg = $jsonobj->open(filename => $CFGFILEOWFS);
	$cfg->{fake} = $q->{fake};
	$cfg->{httpdport} = $q->{httpdport};
	$cfg->{serverport} = $q->{serverport};
	$cfg->{usb} = $q->{usb};
	$cfg->{serial2usb} = $q->{serial2usb};
	$cfg->{i2c} = $q->{i2c};
	$cfg->{gpio} = $q->{gpio};
	$cfg->{pullup} = $q->{pullup};
	$cfg->{tempscale} = $q->{tempscale};
	$cfg->{uncached} = $q->{uncached};
	$q->{refreshdev} =~ s/,/\./g;
	$cfg->{refreshdev} = $q->{refreshdev};
	$q->{refreshval} =~ s/,/\./g;
	$cfg->{refreshval} = $q->{refreshval};
	$cfg->{busses} = undef;
	foreach my $key (keys %$q) {
		if ($key =~ /^bus\d+$/) {
			$cfg->{busses}->{$key} = $q->{$key};
		}
	}
	$jsonobj->write();

	my $subscr_file = $lbpconfigdir."/owfs.conf";
	eval {
		open(my $fh, '>', $subscr_file);
		print $fh "!server: server = 127.0.0.1:" . $q->{serverport} . "\n";
		print $fh "server: port = " . $q->{serverport} . "\n";
		print $fh "http: port = " . $q->{httpdport} . "\n";
		print $fh "server: FAKE = " . $q->{fake} . "\n" if $q->{fake};
		print $fh "server: usb = all\n" if is_enabled($q->{usb});
		print $fh "server: i2c = ALL:ALL\n" if is_enabled($q->{i2c});
		print $fh "server: w1\n" if is_enabled($q->{gpio});
		if ( is_enabled($q->{serial2usb}) && -e "$lbpdatadir/ftdidevices.dat" ) {
			open(my $fh1, '<', "$lbpdatadir/ftdidevices.dat");
			while (my $row = <$fh1>) {
				chomp $row;
				print $fh "$row\n";
			}
			close $fh1;
		}
		close $fh;
		#if ( is_enabled($q->{gpio}) ) {
		eval {
			system("sudo $lbpbindir/create1wgpio.sh >/dev/null 2>&1");
		};
		#}
	};
	if ($@) {
		$errors++;
	}

	my $loglevel = LoxBerry::System::pluginloglevel();
	my $verbose = "0";
	if ($loglevel eq "7") {
		$verbose = 1;
	}

	# Restart OWFS
	eval {
		system("sudo systemctl enable owserver >/dev/null 2>&1");
		system("sudo systemctl enable owhttpd >/dev/null 2>&1");
		system("$lbpbindir/watchdog.pl --action=restart --verbose=$verbose >/dev/null 2>&1");
	};
	if ($@) {
		$errors++;
	}
	
	# Create Cronjob
	#my $cron_file = $lbhomedir . "/system/cron/cron.01min/" . $lbpplugindir;
	#eval {
	#	open(my $fh, '>', $cron_file);
	#	print $fh "#!/bin/bash\n";
	#	print $fh "$lbpbindir/watchdog.pl --action=check --verbose=0\n";
	#	close $fh;
	#	system("chmod 755 $cron_file >/dev/null 2>&1");
	#};
	#if ($@) {
	#	$errors++;
	#}

	return ($errors);

}

sub restartservices
{
	my $loglevel = LoxBerry::System::pluginloglevel();
	my $verbose = "0";
	if ($loglevel eq "7") {
		$verbose = 1;
	}

	# Restart services from WebUI
	my $errors;
	eval {
		system("$lbpbindir/watchdog.pl --action=restart --verbose=$verbose >/dev/null 2>&1");
	};
	if ($@) {
		$errors++;
	}

	return ($errors);

}


END {
}
