#!/usr/bin/perl -w

# Author          : MrLurch81
# Created On      : 21-05-2017
# Last Modified By: MrLurch81
# Last Modified On: 31-05-2019
# Update Count    : 
# Status          : 

################ Common stuff ################

use strict;
use warnings;
use utf8;

use Config::Properties;
my $props = Config::Properties->new();

# Package name.
my $my_package = 'Growatt WiFi Tools';
# Program name and version.
my ($my_name, $my_version) = qw( growatt_data 0.07 );

# This should be replaced by module functions
require "growatt_lib.pl";

################ Read property file ################
our $configfile;

if(open my $fh, '<', $configfile) {
	$props->load($fh);
    close $fh;
} else {
    print "No properties file found at $configfile \n";
    print "Upload will not be performed \n";
} 

# if(open my $fh, '<', '/config/config.properties') {
	# $props->load($fh);
    # close $fh;
# } else {
    # print "No properties file found at /config/config.properties\n";
# } 

my $gwversion = $props->getProperty('gwversion', 3);

my $PVOUTPUTAPIKEY = $props->getProperty('PVOUTPUTAPIKEY', '');
my $PVOUTPUTSID = $props->getProperty('PVOUTPUTSID', '');

my $DOMOTICZ_HOST = $props->getProperty('DOMOTICZ_HOST', '');
my $DOMOTICZ_PORT = $props->getProperty('DOMOTICZ_PORT', '');
my $DOMOTICZ_IDXENERGY = $props->getProperty('DOMOTICZ_IDXENERGY', '');
my $DOMOTICZ_IDXVOLTAGE = $props->getProperty('DOMOTICZ_IDXVOLTAGE', '');

my $MQTT_HOST = $props->getProperty('MQTT_HOST', '');
my $MQTT_PORT = $props->getProperty('MQTT_PORT', '');
my $MQTT_USER = $props->getProperty('MQTT_USER', '');
my $MQTT_PASS = $props->getProperty('MQTT_PASS', '');

my $PVOUTPUT_URL = "http://pvoutput.org/service/r2/addstatus.jsp";
my $DOMOTICZ_URL = "http://$DOMOTICZ_HOST:$DOMOTICZ_PORT/json.htm";
my $MQTT_URL = "$MQTT_HOST:$MQTT_PORT";

use URI;
use LWP::UserAgent;

# MQTT support
use Net::MQTT::Simple;

sub upload_msg {
	my ( $ts, $msg ) = @_;
	my $data = disassemble_datafile($gwversion, $msg);

	if ( $PVOUTPUTAPIKEY ne "" ) {
		eval {
			upload_data_pvoutput($ts, $data);
			1;
		} or do {
			my $e = $@;
			print("Upload to PV Output went wrong: $e\n");
		}
	}

	if ( $DOMOTICZ_HOST ne "" && $ts ne "") {
		# if $ts is empty, request was historical (from growatt_data.pl), so don't do Domoticz update
		eval {
			upload_data_domoticz($ts, $data);
			1;
		} or do {
			my $e = $@;
			print("Upload to Domoticz went wrong: $e\n");
		}
	}

	if ( $MQTT_HOST ne "" && $ts ne "") {
		# if $ts is empty, request was historical (from growatt_data.pl), so don't do MQTT update
		eval {
			upload_data_mqtt($ts, $data);
			1;
		} or do {
			my $e = $@;
			print("Upload to MQTT went wrong: $e\n");
		}
	}

}

sub upload_data_pvoutput {
	my ( $ts, $a ) = @_;
	my %data = %$a;
	my @tm = localtime(time);
	my $date = sprintf( "%04d%02d%02d", 1900 + $tm[5], 1 + $tm[4], $tm[3] );
	my $time = sprintf( "%02d:%02d", @tm[2,1] );
	
	if ( $ts ne "" ) {
		$date = substr $ts, 0, 10;
		$date =~ s/-//g; 				# remove the minus sign for PVOutput
		$time = substr $ts, 11, 5;
	}
	
	my $ua = LWP::UserAgent->new;
	my $url = URI->new($PVOUTPUT_URL);
	$url->query_form( 'd'  => $date					# Date
					, 't'  => $time					# Time
#					, 'c1' => "1"					# Cumulative flag
#					, 'v1' => 1000 * $data{E_Total}	# Generated energy (Wh)
					, 'c1' => "0"					# Today energy flag
					, 'v1' => 1000 * $data{E_Today}	# Generated energy (Wh)
					, 'v2' => $data{Pac}			# Generated power (W)
					, 'v6' => $data{Vpv1}			# PV Voltage (V)
					);
	
	############################
	# set custom HTTP request header fields
	my $req = HTTP::Request->new(GET => $url);
	$req->header('X-Pvoutput-Apikey' => $PVOUTPUTAPIKEY);
	$req->header('X-Pvoutput-SystemId' => $PVOUTPUTSID);
	print "HTTP POST as string: ", $req->as_string;
	
	my $resp = $ua->request($req);
	
	############################
	
	if ($resp->is_success) {
		my $message = $resp->decoded_content;
		print "Received reply from PV Output: $message\n";
	}
	else {
		print "HTTP POST error code: ", $resp->code, "\n";
		print "HTTP POST error message: ", $resp->message, "\n";
		print "HTTP POST content: ", $resp->content, "\n";
	}
	print "\n";
}

sub upload_data_domoticz {
	my ( $ts, $a ) = @_;
	my %data = %$a;
	
	my $ua = LWP::UserAgent->new;
	my $url = URI->new($DOMOTICZ_URL);

	my $powerconcat = $data{Pac} . ';' . (1000 * $data{E_Total});
	
	############################
	# send the Power/Energy
	$url->query_form( 'type'	=> "command"					# Domoticz API
					, 'param'	=> "udevice"					# Domoticz API
					, 'idx'		=> $DOMOTICZ_IDXENERGY			# item to write the energy value to
					, 'nvalue'	=> 0							# blank
					, 'svalue'	=> $powerconcat					# Generated power (W) and energy (Wh)
					);
					
	my $req = HTTP::Request->new(GET => $url);
	print "HTTP POST as string: ", $req->as_string;
	
	my $resp = $ua->request($req);

	if ($resp->is_success) {
		my $message = $resp->decoded_content;
		print "Received reply from Domoticz: $message\n";
	}
	else {
		print "HTTP POST error code: ", $resp->code, "\n";
		print "HTTP POST error message: ", $resp->message, "\n";
		print "HTTP POST content: ", $resp->content, "\n";
	}
	
	############################
	# send the Voltage
	$url->query_form( 'type'	=> "command"				# Domoticz API
					, 'param'	=> "udevice"				# Domoticz API
					, 'idx'		=> $DOMOTICZ_IDXVOLTAGE		# item to write the voltage value to
					, 'nvalue'	=> 0						# blank
					, 'svalue'	=> $data{Vpv1}				# PV Voltage (V)
					);
					
	$req = HTTP::Request->new(GET => $url);
	print "HTTP POST as string: ", $req->as_string;
	
	$resp = $ua->request($req);
	
	if ($resp->is_success) {
		my $message = $resp->decoded_content;
		print "Received reply from Domoticz: $message\n";
	}
	else {
		print "HTTP POST error code: ", $resp->code, "\n";
		print "HTTP POST error message: ", $resp->message, "\n";
		print "HTTP POST content: ", $resp->content, "\n";
	}

}

sub upload_data_mqtt {
	my ( $ts, $a ) = @_;
	my %data = %$a;
	
	# send current time if $ts has a problem
	my @tm = localtime(time);
	my $date = sprintf( "%04d%02d%02d", 1900 + $tm[5], 1 + $tm[4], $tm[3] );
	my $time = sprintf( "%02d%02d", @tm[2,1] );
	
	# Read the date/time from the measurement timestamp:
	if ( $ts ne "" ) {
		$date = substr $ts, 0, 10;
		$date =~ s/-//g; 				# remove the minus sign
		$time = substr $ts, 11, 5;
		$time =~ s/://g; 				# remove the minus sign
	}
	
	my $jsonpayload = '{ "date": "' . $date
				  . '" , "time": "' . $time 
				  . '" , "power": "' . $data{Pac} 
				  . '" , "voltage": "' . $data{Vpv1} 
				  . '" , "e_today": "' . 1000 * $data{E_Today}
				  . '" , "e_total": "' . 1000 * $data{E_Total}
				  . '" }';
	print "Sending json data to MQTT: $jsonpayload\n";
	print "\n";
	
	#############################
	# Allow unencrypted connection with credentials
	$ENV{MQTT_SIMPLE_ALLOW_INSECURE_LOGIN} = 1;
	
	# Connect to broker
	my $mqtt = Net::MQTT::Simple->new($MQTT_URL);
	
	# Depending if authentication is required, login to the broker
	if($MQTT_USER and $MQTT_PASS) {
		$mqtt->login($MQTT_USER, $MQTT_PASS);
	}
	
	# Publish a message with retain flag
	$mqtt->retain("solar/live/status", $jsonpayload);
	
	$mqtt->disconnect();
	#############################
}



