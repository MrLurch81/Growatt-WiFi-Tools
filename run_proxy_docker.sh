#!/bin/sh
scriptdir=/growatt-proxy
configdir=/config
logdir=$configdir/logs
datadir=$configdir/datafiles
if [! -d $logdir]
then
  mkdir $logdir
fi
if [! -d $configdir]
then
  mkdir $configdir
fi
logfile=$logdir/`date "+%Y%m%d.log"`
export PERL5LIB=$scriptdir/scripts
# Remove --remote for standalone server.
perl $scriptdir/scripts/growatt_server.pl --debug --remote --datadir=$datadir 2>&1 | tee -a $logfile
