#!/bin/bash


# trap exits from parameter tests
trap "usage;exit 1" 0

usage() {
	echo
	echo usage: $0 oracle_instance_name interval_seconds iterations
	echo
	echo example: run for 1 day at 1 minute intervals
	echo  $0 60 1440
	echo
	echo it is assumed this is a bequeath connection as SYSDBA
	echo
}

ORACLE_INSTANCE=$1
INTERVAL=$2
ITERATIONS=$3

: ${ORACLE_INSTANCE:?} ${INTERVAL:?} ${ITERATIONS:?} 

trap 0

mkdir -p data
mkdir -p logs

unset ORAENV_ASK
. /usr/local/bin/oraenv <<< orcl

timestamp=$(date '+%Y%m%d-%H%M%S')
CSVFile="data/cpu-aasm-${ORACLE_SID}_${timestamp}.csv"
LogFile="logs/cpu-aasm-${ORACLE_SID}_${timestamp}.log"

echo 
echo Running with these parameters as SYSDBA:
echo " ORACLE_SID: $ORACLE_SID"
echo "   Interval: $INTERVAL seconds"
echo " Iterations: $ITERATIONS"
echo 


echo "CMD used: nohup $ORACLE_HOME/perl/bin/perl cpu-aasm.pl --sysdba --interval $INTERVAL --iterations $ITERATIONS > $CSVFile 2> $LogFile "
echo
nohup $ORACLE_HOME/perl/bin/perl cpu-aasm.pl --sysdba --interval $INTERVAL --iterations $ITERATIONS > $CSVFile 2> $LogFile & 


