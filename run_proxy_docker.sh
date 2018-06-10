#!/bin/sh
scriptdir=/growatt-proxy
logfile=$scriptdir/logs/`date "+%Y%m%d.log"`
export PERL5LIB=$scriptdir/scripts
# Remove --remote for standalone server.
perl $scriptdir/scripts/growatt_server.pl --debug --remote --datadir=/growatt-proxy/datafiles 2>&1 | tee -a $logfile
