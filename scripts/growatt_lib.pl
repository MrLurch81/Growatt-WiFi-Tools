#!/usr/bin/perl -w

# Author          : MrLurch81
# Created On      : 
# Last Modified By: 
# Last Modified On: 
# Update Count    : 
# Status          : Unknown, Use with caution!

################ Common stuff ################

use strict;
use warnings;
use utf8;

# Package name.
my $my_package = 'Growatt WiFi Tools';
# Program name and version.
my ($my_name, $my_version) = qw( growatt_data 0.07 );

################ Command line parameters ################

# none

################ Library routines ################

use Data::Hexify;

sub disassemble_datafile {
	my ( $gwversion, $data ) = @_;
	my $off = 0;
	
	# Mote common case for unpacking data.
	my $up = sub {
		my ( $len, $scale ) = @_;
		my $val = up( $data, $off, $len, $scale );
		$off += $len;
		return $val;
	};
	
	# All data messages start with 00 01 00 02 ll ll 01 04.
	unless ( $up->(2) == 0x0001
			and
			$up->(2) == 0x0002
			and
			$up->(2) == length($data) - 6
			and
			$up->(2) == 0x0104
	) {
		warn("Invalid data package\n");
		warn(Hexify(\$data),"\n");
		return;
	}
	
	my %a;
	
	$a{DataLoggerId} = substr($data, $off, 10); $off += 10;
	$a{InverterId}   = substr($data, $off, 10); $off += 10;
	
	$off += 5;
	$off += 6 if $gwversion >= 2;	# for V2.0.0.0 and up
									# verified up to 4.0.0.0
	
	my $off0 = $off - 15;			# for assertion
	
	$a{InvStat} = $up->(2);
	$a{InvStattxt} = (qw( waiting normal fault ))[$a{InvStat}];
	$a{Ppv} = $up->(4, 1);
	$a{Vpv1} = $up->(2, 1);
	$a{Ipv1} = $up->(2, 1);
	$a{Ppv1} = $up->(4, 1);
	$a{Vpv2} = $up->(2, 1);
	$a{Ipv2} = $up->(2, 1);
	$a{Ppv2} = $up->(4, 1);
	$a{Pac} = $up->(4, 1);
	$a{Fac} = sprintf("%.2f", up($data, $off, 2)/100 ); $off += 2;
	$a{Vac1} = $up->(2, 1);
	$a{Iac1} = $up->(2, 1);
	$a{Pac1} = $up->(4, 1);
	$a{Vac2} = $up->(2, 1);
	$a{Iac2} = $up->(2, 1);
	$a{Pac2} = $up->(4, 1);
	$a{Vac3} = $up->(2, 1);
	$a{Iac3} = $up->(2, 1);
	$a{Pac3} = $up->(4, 1);
	$a{E_Today} = sprintf("%.2f", $up->(4) / 10);		# KWh
	$a{E_Total} = sprintf("%.2f", $up->(4) / 10);		# KWh
	$a{Tall} = sprintf("%.2f", $up->(4) / (60*60*2));
	$a{Tmp} = $up->(2, 1);
	$a{ISOF} = $up->(2, 1);
	$a{GFCIF} = sprintf("%.2f", up($data, $off, 2)/10 ); $off += 2;
	$a{DCIF} = sprintf("%.2f", up($data, $off, 2)/10 ); $off += 2;
	$a{Vpvfault} = $up->(2, 1);
	$a{Vacfault} = $up->(2, 1);
	$a{Facfault} = sprintf("%.2f", up($data, $off, 2)/100 ); $off += 2;
	$a{Tmpfault} = $up->(2, 1);
	$a{Faultcode} = $up->(2);
	$a{IPMtemp} = $up->(2, 1);
	$a{Pbusvolt} = $up->(2, 1);
	$a{Nbusvolt} = $up->(2, 1);
	
	# Assertion.
	warn("offset = ", $off-$off0, ", should be 103\n")
		unless $off-$off0 == 103;
	$off += 12;
	
	$a{Epv1today} = sprintf("%.2f", up($data, $off, 4)/10  ); $off += 4;
	$a{Epv1total} = sprintf("%.2f", up($data, $off, 4)/10  ); $off += 4;
	$a{Epv2today} = sprintf("%.2f", up($data, $off, 4)/10  ); $off += 4;
	$a{Epv2total} = sprintf("%.2f", up($data, $off, 4)/10  ); $off += 4;
	$a{Epvtotal}  = sprintf("%.2f", up($data, $off, 4)/10  ); $off += 4;
	$a{Rac}       = sprintf("%.2f", up($data, $off, 4)*100 ); $off += 4;
	$a{ERactoday} = sprintf("%.2f", up($data, $off, 4)*100 ); $off += 4;
	$a{ERactotal} = sprintf("%.2f", up($data, $off, 4)*100 ); $off += 4;
	
	return \%a;
}

# Unpack 2 or 4 bytes unsigned data, optionally scaling it.
sub up {
	my ( $data, $offset, $len, $scale ) = ( @_, 0 );
	my $v = unpack( $len == 2 ? "n" : "N",
			substr( $data, $offset, $len ) );
	if ( $scale ) {
		return sprintf("%.${scale}f", $v/(10**$scale));
	}
	return $v;
}
