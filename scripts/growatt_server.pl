#!/usr/bin/perl
#
# Author          : Johan Vromans
# Created On      : Tue Jul  7 21:59:04 2015
# Last Modified By: MrLurch81
# Last Modified On: 
# Update Count    : 
# Status          : Unknown, Use with caution!
#
################################################################
#
# Local server for Growatt WiFi.
#
# The Growatt WiFi module communicates with the Growatt server
# (server.growatt.com, port 5279). This proxy server can be put
# between the module and the server to intercept all traffic.
# It can also be run as a standalone server for data logging without
# involving the Growatt servers.
#
# The proxy is transparent, every data package from the module is sent
# to the server, and vice versa. An extensive logging is produced of
# all traffic.
#
# Data packages that contain energy data from the data logger are
# written to disk in separate files for later processing.
#
# This server is loosely based on code by Peteris Krumins (peter@catonmat.net).

# Usage:
#
# In an empty directory, start the server. It will listen to port
# 5279. If you provide a remote server name on the command line it will
# act as a proxy and connect to the remote Growatt server.
#
# Using the Growatt WiFi module administrative interface, go to the
# "STA Interface Setting" and change "Server Address" (default:
# server.growatt.com) to the name or ip of the system running the
# proxy server.
# Reboot the WiFi module and re-visit the "STA Interface Setting" page
# to verify that the "Server Connection State" is "Connected".
#
# If all went well, you'll see messages flowing between the WiFi
# module and the server, and energy data files will start appearing in
# the current directory:
#
# 20150703135901.dat
# 20150703140004.dat
# ... and so on ...
#
# You can specify the directories for the data and the logfile with
# command line options.
#
# For best results use systemd (or inetd, untested) to start the proxy
# server. See the scripts in the systemd directory.
#
################################################################

use warnings;
use strict;

################ Common stuff ################

# Package name.
my $my_package = 'Growatt WiFi Tools';
# Program name and version.
my ($my_name, $my_version) = qw( growatt_server 0.60 );

use Getopt::Long 2.13;
use Config::Properties;
my $props = Config::Properties->new();

################ Command line parameters ################

# Command line options.
my $local_port  = 5279;		# local port. DO NOT CHANGE
my $remote_host;			# remote server, if proxy
#my $remote_host = "server.growatt.com";	# remote server, if proxy
my $remote_port = 5279;		# remote port. DO NOT CHANGE
my $timeout;				# 30 minutes
my $verbose = 0;			# verbose processing
my $sock_act = 0;			# running through inetd or systemd
my $logdir;					# where to put the logfile
my $datadir;				# where to put the data packages
our $configfile;			# location of the config file (if used)
my $multi;					# for multiple inverters

# Development options (not shown with -help).
my $debug = 1;				# debugging (currently default)
my $trace = 0;				# trace (show process)

# Process command line options.
app_options();
$configfile =~ s/\/+$//;

# proxy server (this host)
# If you don't use a property file, be sure to replace 192.168.2.1 by your value
my $local_host = $props->getProperty('local_host', '192.168.2.1');

if(open my $fh, '<', $configfile) {
	$props->load($fh);
    close $fh;
} else {
    print "No properties file found at $configfile \n";
    print "Be sure to specify the right local_host in growatt_server.pl\n";
} 

# This should be replaced by module functions
require "growatt_uploads.pl";

# Post-processing.
$timeout //= $sock_act ? 300 : 1800;

$datadir =~ s/\/+$//;
$logdir =~ s/\/+$//;

$trace |= $debug;
$verbose |= $trace;

################ Presets ################

my $TMPDIR = $ENV{TMPDIR} || $ENV{TEMP} || '/usr/tmp';

################ The Process ################

use IO::Socket::INET;
use IO::Select;
use IO::Handle;
use Fcntl;
use Data::Hexify;

my $ioset = IO::Select->new;
my %socket_map;
my $s_reload = ".reload";
my $s_reboot = ".reboot";
my $s_inject = ".inject";

$| = 1;				# flush standard output

my $server;
my $remote_socket = 0;
my $data_logger;

if ( $sock_act ) {		# running via systemd
	my @tm = localtime(time);
	open( STDOUT, '>>',
		sprintf( "%s/%04d%02d%02d.log", $logdir,
		1900+$tm[5], 1+$tm[4], $tm[3] ) );
	print( ts(), " Starting Growatt ",
		$remote_host ? "proxy server for $remote_host" : "server",
		" version $my_version",
		" on stdin\n" );
	$server = IO::Socket::INET->new;
	$server->fdopen( 0, 'r' );
	print( ts(), " Connection accepted from ",
		client_ip($server), "\n") if $debug;

	if ( $remote_host ) {
		my $remote = new_conn( $remote_host, $remote_port );
		print( ts(), " Connection to $remote_host (",
			$remote->peerhost, ") port $remote_port established\n")
			if $debug;

		$ioset->add($remote);
		$socket_map{$server} = $remote;
		$socket_map{$remote} = $server;
		$remote_socket = $remote;
	} else {
		$socket_map{$server} = $server;
	}
	$ioset->add($server);
} else {
	print( ts(), " Starting Growatt ",
		$remote_host ? "proxy server for $remote_host" : "server",
		" version $my_version",
		" on 0.0.0.0:$local_port\n" );
	$server = new_server( '0.0.0.0', $local_port );
	$ioset->add($server);
	$remote_socket = $server;
}

my $busy;
while ( 1 ) {
	my @sockets = $ioset->can_read($timeout);
	unless ( @sockets ) {
		if ( !$sock_act && ( $busy || -f $s_reload ) ) {
			unlink($s_reload);
			print( "==== ", ts(), " TIMEOUT -- Reloading ====\n\n" );
			exit 0;
		} else {
			print( "==== ", ts(), " TIMEOUT ====\n\n" );
			if ( $sock_act ) {
				unlink($s_reload);
				exit 0;
			}
			next;
		}
	}
	$busy = 1;
	for my $socket ( @sockets ) {
		if ( !$sock_act && $socket == $server ) {
			new_connection( $server, $remote_host, $remote_port );
		} else {
			next unless exists $socket_map{$socket};
			my $dest = $socket_map{$socket};
			my $buffer;
			my $len = $socket->sysread($buffer, 4096);
			if ( $len ) {
				my $did = 0;
				while ( my $msg = split_msg( \$buffer ) ) {
					$did++;
					$msg = preprocess_msg( $socket, $msg );
					foreach ( process_msg( $socket, $msg ) ) {
						$dest->syswrite($_);
						postprocess_msg( $socket, $_ );
					}
				}
				print( "==== ", ts(), " client RAW ====\n", Hexify(\$buffer), "\n" )
					if !$did && $debug;
			} else {
				close_connection($socket);
				if ( $sock_act ) {
					print( ts(), " Server terminating\n\n" );
					exit 0;
				}
			}
		}
	}
}

################ Subroutines ################

sub new_conn {
	my ($host, $port) = @_;
	for ( 0..4 ) {
		my $s = IO::Socket::INET->new( PeerAddr => $host,
						PeerPort => $port
						);
		return $s if $s;
		print( "==== ", ts(), " Unable to connect to $host:$port: $!",
			" (retrying) ====\n\n" );
		sleep 2 + rand(2);
	}
	die( "==== ", ts(), " Unable to connect to $host:$port: $! ====\n\n" );
}

sub new_server {
	my ($host, $port) = @_;
	my $server = IO::Socket::INET->new(
		LocalAddr => $host,
		LocalPort => $port,
		ReuseAddr => 1,
		Listen    => 100
	) || die "Unable to listen on $host:$port: $!";
}

sub ts {
	my @tm = localtime(time);
	sprintf( "%04d-%02d-%02d %02d:%02d:%02d",
		1900 + $tm[5], 1+$tm[4], @tm[3,2,1,0] );
}

sub new_connection {
	my $server = shift;
	my $remote_host = shift;
	my $remote_port = shift;
	
	my $client = $server->accept;
	my $client_ip = client_ip($client);
	
	print( ts(), " Connection from $client_ip accepted\n") if $debug;

	$ioset->add($client);
	
	if ( $remote_host ) {
		my $remote = new_conn( $remote_host, $remote_port );
		print( ts(), " Connection to $remote_host (",
			$remote->peerhost, ") port $remote_port established\n") if $debug;
		
		$ioset->add($remote);
		$remote_socket = $remote;
		$socket_map{$client} = $remote;
		$socket_map{$remote} = $client;
	} else {
		$remote_socket = $client;
		$socket_map{$client} = $client;
	}
}

sub close_connection {
	my $client = shift;
	my $client_ip = client_ip($client);
	my $remote = $socket_map{$client};
	
	if ( $remote == $client ) {
		$ioset->remove($client);
		delete $socket_map{$client};
		$client->close;
	} else {
		$ioset->remove($client);
		$ioset->remove($remote);
		delete $socket_map{$client};
		delete $socket_map{$remote};
		$client->close;
		$remote->close;
	}

	print( ts(), " Connection from $client_ip closed\n" ) if $debug;
}

sub client_ip {
    my $client = shift;
    return ( eval { $client->peerhost } || $ENV{REMOTE_ADDR} || "?.?.?.?" );
}

# Messages always start with pack("nn", HB1, HB2)
sub HB1();	# first word
sub HB2();	# second word
my $msg_pat;	# to match a message start

sub set_proto {
	my ( $msg ) = @_;

	my $vproto = 3;
	my @a = unpack( "nnnn", $msg );
	if ( $a[0] == 1
			&&
			( $a[1] == 0 || $a[1] == 2 )
			&&
			$a[2] >= 3
			&&
			( $a[3] >= 0x103 && $a[3] <= 0x119 )
	) {
		$vproto = 1 if $a[1] == 0;
	}

	if ( $vproto == 1 ) {
		# WiFi sticks version 1.0.0.0 use these.
		eval "sub HB1() { 1 } sub HB2() { 0 }";
	} else {
		# WiFi sticks version >= 3.0.0.0 use these.
		eval "sub HB1() { 1 } sub HB2() { 2 }";
	}
	$msg_pat = eval "qr(".pack("nn", HB1, HB2).")";
}

sub split_msg {
    my ( $bufref ) = @_;
    my $msg;

    # Infer protocol version, if needed.
    set_proto($$bufref) unless $msg_pat;

    # Convenient telnet commands for testing.

    if ( $$bufref =~ /^ping(?:\s+(\S+))?/ ) {
		$msg = m_ping( $1 // $data_logger // "AH12345678" );
	} elsif ( $$bufref =~ /^ahoy(?:\s+(\S+))?/ ) {
		$msg = pack( "n[4]A[10]A[10].",
			HB1, HB2, 0xd9, 0x0103,
			$1 // "AH12345678", "OP24510017", 6 + 0xd9 );
	} elsif ( $$bufref =~ /^data/ ) {
		$msg = pack( "n[4]A[10]A[10].",
			HB1, HB2, 0xd9, 0x0104,
			$1 // "AH12345678", "OP24510017", 6 + 0xd9 );
	} elsif ($$bufref =~ /^q(?:uit)?/ ) {
		print( ts(), " Server terminating\n" );
		exit 0;
	}

	$$bufref = $msg if $msg;
	if ( $$bufref =~ /^$msg_pat(..)/o ) {
		my $length = unpack( "n", $1 );
		return substr( $$bufref, 0, $length+6, '' );
	}
	return;
}

sub disassemble_msg {
    my ( $msg ) = @_;
    return unless $msg =~ /^$msg_pat(..)(..)/o;

    my $length = unpack( "n", $1 );
    return { length => $length,
	     type   => unpack( "n", $2 ),
	     data   => substr( $msg, 8, $length-2 ),
	     prefix => substr( $msg, 0, 8 ) };
}

sub assemble_msg {
    my ( $msg ) = @_;

    # Only data and type is used.
    return pack( "n4", HB1, HB2, 2+length($msg->{data}), $msg->{type} )
      . $msg->{data};
}

sub preprocess_msg {
	my ( $socket, $msg ) = @_;
	my $tag = $socket != $remote_socket ? "client" : "server";
	return $msg unless $remote_host;
	my $orig = $msg;
	my $ts = ts();
	my $a = disassemble_msg($msg);
	
	# Make the Growatt server think we're directly talking to him.
	if ( $a->{type} eq 0x0119 ) {	# query settings
		if ( $a->{data} =~ /^(.{10}\x00(?:\x11|\x13))/ ) {
			# Fake items 11 and 13 to reflect the growatt server.
			$a->{data} = $1
				. pack('n', length($remote_host)) . $remote_host;
			$msg = assemble_msg($a);
		}
	}
	# And refuse to change it :) .
	elsif ( $a->{type} eq 0x0118 ) {	# update settings
		if ( $a->{data} =~ /^(.{10}\x00\x13)/ ) {
			# Refuse to change config item 13.
			$a->{data} = $1
				. pack('n', length($local_host)) . $local_host;
			$msg = assemble_msg($a);
		}
	}
	
	if ( $orig ne $msg ) {
		print( "==== $ts $tag NEEDFIX ====\n", Hexify(\$orig), "\n",
			   "==== $ts $tag FIXED ====\n". Hexify(\$msg), "\n");
	}
	
	return $msg;
}

my $identified;

sub process_msg {
	my ( $socket, $msg ) = @_;
	
	# Processes a message.
	# Returns nothing, a (new) message, or a list of messages.
	
	return $msg if $remote_host; # nothing for us proxy
	
	my $tag = "client";
	my $ts = ts();
	my $m = disassemble_msg($msg);
	
	unless ( $m ) {
		# Error?
		print( "==== $ts $tag ====\n", Hexify(\$msg), "\n" );
		return;
	}
	
	# PING.
	if ( $m->{type} == 0x0116 && $m->{length} == 12 ) {
		my $dl = substr( $m->{data}, 0, 10 );
		print( "==== $ts $tag PING ", $dl, " ====\n\n" ) if $debug;
		if ( $multi && ( !$data_logger || $data_logger ne $dl ) ) {
			switch_log($dl);
			print( "==== $ts $tag PING ", $dl, " ====\n\n" ) if $debug;
		}
		$data_logger = $dl;
		return m_ping();
	}
	
	if ( $m->{type} == 0x0103 && $m->{length} > 200 ) {
		# AHOY
		my $dl = substr( $m->{data}, 0, 10 );
		print( "==== $ts $tag AHOY ====\n", Hexify(\$msg), "\n" ) if $debug;
		if ( $multi && ( !$data_logger || $data_logger ne $dl ) ) {
			switch_log($dl);
			print( "==== $ts $tag AHOY ====\n", Hexify(\$msg), "\n" ) if $debug;
		}
		$data_logger = $dl;
		return $identified
			? m_ack( $m->{type} )
			: ( m_ack( $m->{type} ), m_identify() );
	}
	
	# Save data packets.
    if ( $m->{type} == 0x0104 && $m->{length} > 210 ) {
		save_data( $ts, $msg, $tag );
		return m_ack( $m->{type} );
	}
	
	# Ignore config messages.
	if ( $m->{type} == 0x0119 ) {
		$identified++;
		print( "==== $ts $tag ====\n", Hexify(\$msg), "\n" ) if $debug;
		return;
	}
	
	# Unhandled.
	print( "==== $ts $tag ====\n", Hexify(\$msg), "\n" ) if $debug;
	return;
}

sub postprocess_msg {
	my ( $socket, $msg ) = @_;
	
	my $tag = $socket != $remote_socket ? "client" : "server";
	$tag = "server" unless $remote_host;
	
	my $ts = ts();
	
	my $m = disassemble_msg($msg);
	unless ( $m ) {
		print( "==== $ts $tag ====\n", Hexify(\$msg), "\n" );
		return;
	}
	
	# PING.
	if ( $m->{type} == 0x0116 && $m->{length} == 12 ) {
		print( "==== $ts $tag PING ",
			$data_logger = substr( $m->{data}, 0, 10 ),
			" ====\n\n" ) if $debug;
		return;
	}
	
	# ACK.
	if ( $m->{length} == 3
			&& ( $m->{type} == 0x0104 || $m->{type} == 0x0103 )
	) {
		printf( "==== %s %s ACK %04x %02x ====\n\n",
			$ts, $tag, $m->{type},
			unpack( "C", substr( $m->{data}, 0, 1 ) ) ) if $debug;
	# For development: If there's a file $s_reload in the current
	# directory, stop this instance of the server.
	# When invoked via the "run_server.sh" script this will
	# immedeately start a new server instance. Otherwise, systemd
	# or inetd will start a new instance when the client reconnects.
	# This can be used to upgrade to a new version of the
	# server.
		if ( -f $s_reload ) {
			print( "==== $ts Reloading ====\n" );
			unlink( $s_reload );
			print( "\n" );
			exit 0;
		}
	
	# Similar trick to reboot the WiFi stick.
		if ( -f $s_reboot ) {
			unlink($s_reboot);
			my $m = m_reboot();
			print( "==== $ts $tag REBOOT ====\n", Hexify(\$m), "\n" );
			$socket_map{$socket}->syswrite($m);
		}

	# Similar trick to insert arbitrary data.
		if ( -f $s_inject ) {
			open( my $fd, '<', $s_inject );
			my $data = do { local $/; <$fd> };
			if ( $data ) {
				$data = readhex($data)
			}
			unlink($s_inject);
			if ( $data =~ m/^$msg_pat(..)/o
					&& unpack("n", $1)+6 == length($data)
			) {
				print( "==== $ts INJECT ====\n", Hexify(\$data), "\n" );
				$socket_map{$socket}->syswrite($data);
			} else {
				print( "==== $ts INJECT ERROR (length check) ====\n", Hexify(\$data), "\n" );
			}
		}
		return;
	}
	
	# Dump energy reports to individual files. This is for the proxy only,
	# the standalone server handles this in process().
	if ( $m->{type} == 0x0104 && $m->{length} > 210 ) {
		save_data( $ts, $msg, $tag );
		return;
	}
	
	# Miscellaneous. Try add info to tag.
	if ( $m->{type} == 0x0103 ) {
		if ( $m->{length} > 210 ) {
			$tag .= " AHOY";
			# save_msg( $msg, "ahoy.dat" );
		}
	} elsif ( $m->{type} == 0x0119 ) {
		if ( $socket == $remote_socket ) {
			$tag .= " CONFIGQUERY";
		} else {
			my $hx = sprintf("%02x",
				unpack("n", substr($m->{data},
				length($data_logger),
				2)));
			$tag .= " CONFIG $hx";
			# save_msg( $msg, "config$hx.dat" );
		}
	}
	print( "==== $ts $tag ====\n", Hexify(\$msg), "\n" ) if $debug;
	return;
}

sub switch_log {
	my ( $logger ) = @_;
	
	my $ts = ts();
	print( "==== $ts Switching log for $logger ===\n" );
	
	my @tm = localtime(time);
	my $lf = sprintf( "%s/%04d%02d%02d-%s.log", $logdir,
				1900+$tm[5], 1+$tm[4], $tm[3], $logger );
	if ( open( my $fd, '>>', $lf ) ) {
		close($fd);
	} else {
		print( "==== $ts ERROR: CANNOT SWITCH LOG ===\n" );
		return;
	}
	
	close(STDOUT);
	open( STDOUT, '>>', $lf );
	print( ts(), " Switching Growatt ",
		$remote_host ? "proxy server for $remote_host" : "server",
		" version $my_version",
		" for $logger\n\n" );
}

my $prev_data;

sub save_data {
	my ( $ts, $msg, $tag ) = @_;
	
	if ( $prev_data && $msg eq $prev_data ) {
		$tag .= " DUP";
		print( "==== $ts $tag ====\n", Hexify(\$msg), "\n" ) if $trace;
		return;
	}
	$prev_data = $msg;
	
	#### TODO: If supporting more than one inverter,
	#### prefix the filename by the inverter id.
	
	my $fn = $ts;
	$fn =~ s/[- :]//g;
	$fn = $datadir . "/" . $fn;
	$fn .= "-$data_logger" if $multi && $data_logger;
	$fn .= ".dat";
	$tag .= " DATA";
	save_msg( $msg, $fn )
		or $tag .= " ERROR $fn: $!";
	# save_msg( $msg, "data.dat" );
	
	# Dump message in hex.
	print( "==== $ts $tag ====\n", Hexify(\$msg), "\n" ) if $trace;
	
	eval {
		upload_msg( $ts, $msg );
		1;
	} or do {
		my $e = $@;
		print("Upload went wrong: $e\n");
	};
}

sub save_msg {
	my ( $msg, $fn ) = @_;
	
	my $fd;
	if ( sysopen( $fd, $fn, O_WRONLY|O_CREAT )
		and syswrite( $fd, $msg ) == length($msg)
		and close($fd)
	) {
		return 1;
	} else {
		print( "==== ERROR saving $fn: $! ====\n" );
	}
	return;
}

sub m_ping {
    my ( $dl ) = @_;
    $dl //= $data_logger;
    pack( "nnnn", HB1, HB2, 2+length($dl), 0x0116 ) . $dl;
}

sub m_ack {
    pack( "nnnnC", HB1, HB2, 3, $_[0], 0 );
}

sub m_identify {
    my ( $dl ) = @_;
    $dl //= $data_logger;
    pack( "n[4]A[10]n[2]",
	  HB1, HB2, 6+length($dl), 0x0119,
	  $dl, 4, 0x15 );
}

sub m_reboot {
    my ( $dl ) = @_;
    $dl //= $data_logger;
    pack( "n[4]A[10]n[2]A",
	  HB1, HB2, 7+length($dl), 0x0118,
	  $dl, 0x20, 1, "1" );
}

sub readhex {
    my $d = shift;
    $d =~ s/^  ....: //gm;
    $d =~ s/  .*$//gm;
    $d =~ s/\s+//g;
    $d = pack("H*", $d);
    $d;
}

################ Command line options ################

sub app_options {
    my $help = 0;		# handled locally
    my $ident = 0;		# handled locally

    # Process options, if any.
    my $remote;

    if ( !GetOptions(
		     'listen=i' => \$local_port,
		     'remote:s'  => \$remote,
		     'timeout=i' => \$timeout,
		     'inetd|systemd' => \$sock_act,
		     'datadir=s' => \$datadir,
		     'multi'	=> \$multi,
		     'logdir=s'	=> \$logdir,
		     'configfile=s'	=> \$configfile,
		     'ident'	=> \$ident,
		     'verbose'	=> \$verbose,
		     'trace'	=> \$trace,
		     'help|?'	=> \$help,
		     'debug'	=> \$debug,
		    ) or $help )
    {
		app_usage(2);
    }
	app_ident() if $ident;
	
	$local_port ||= 5279;
	$remote = "server.growatt.com:5279"
		if defined($remote) && $remote eq "";
	if ( $remote ) {
		( $remote_host, $remote_port ) = split( /:/, $remote );
	}
	$datadir    ||= ".";
	$logdir     ||= ".";
	$configfile ||= ".";
}

sub app_ident {
    print STDERR ("This is $my_package [$my_name $my_version]\n");
}

sub app_usage {
    my ($exit) = @_;
    app_ident();
    print STDERR <<EndOfUsage;
Usage: $0 [options]
    --listen=NNNN	Local port to listen to (must be $local_port)
    --remote=XXXX:NNNN	Remote server name and port (must be $remote_host:$remote_port)
    --timeout=NNN	Timeout
    --inetd  --systemd	Running from inetd/systemd
    --logdir=XXX	Where to put the logfiles
    --datadir=XXX	Where to put the datafiles
    --configfile=XXX	Location of the configfile (if used)
    --multi		Prefix logger name to data and logs
    --help		This message
    --ident		Shows identification
    --verbose		More verbose information

EndOfUsage
    exit $exit if defined $exit && $exit != 0;
}
