#!/bin/sh
scriptdir=/growatt-proxy
configdir=/config
logdir=$configdir/logs
datadir=$configdir/datafiles
if [ ! -d $logdir ]; then mkdir -p $logdir; fi;
if [ ! -d $datadir ]; then mkdir $datadir; fi;
logfile=$logdir/`date "+%Y%m%d.log"`
export PERL5LIB=$scriptdir/scripts
# Remove --remote for standalone server.
perl $scriptdir/scripts/growatt_server.pl --debug --remote --datadir=$datadir --configfile=$configdir/config.properties 2>&1 | tee -a $logfile
