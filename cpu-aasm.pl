#!/usr/local/bin/perl
#!/u01/app/oracle/product/11.2.0/oms/perl/bin/perl

# see http://datavirtualizer.com/oracle-cpu-time/

use Data::Dumper;
use warnings;
use FileHandle;
use DBI;
use strict;

my $debug=0;

# this script will connect to an arbitrary number of databases
# look for connections file
# something on the command line
# curr dir
# home

my $connectionsFileName='cpu-aas-connect.txt';

my @connectionsFileLocations = (
	"$connectionsFileName"
	,"$ENV{HOME}/$connectionsFileName"
);

if ($ARGV[0]) { unshift(@connectionsFileLocations,$ARGV[0]) }

#print Dumper(\@connectionsFileLocations);
#exit;

# open the first file found from the list

foreach my $f (@connectionsFileLocations) {
	if (-r $f) {
		print "Using connections file: $f\n" if $debug;
		open CONN,'<',$f;
		last;
	}
}

my @connections=<CONN>;
close CONN;
chomp @connections;

@connections = grep(!/^#|^\s*$/,@connections);

#print Dumper(\@connections);
#exit;

my %dbh=();

foreach my $connectInfo (@connections) {

	my ($username,$password,$service) = split(/:/,$connectInfo);

	print "username: $username\n" if $debug;
	print "oassword: $password\n" if $debug;
	print "service : $service\n" if $debug;

	print "Connecting to: $service\n" if $debug;

	$dbh{$service} = DBI->connect(
   	'dbi:Oracle:' . $service,$username,$password,
   	{
      	RaiseError => 1,
      	AutoCommit => 0,
      	ora_session_mode => 0 # 0=normal 1=sysoper 2=sysdba
   	}
   	);

	die "Connect failed \n" unless $dbh{$service};

	$dbh{$service}->{RowCacheSize} = 100;
}

our $sql;

prep_sql();

my %sth=();
foreach my $service ( keys %dbh ) {
	$sth{$service} = $dbh{$service}->prepare($sql,{ora_check_sql => 0});
}

print "TIMESTAMP,DATABASE,BEGIN_TIME,END_TIME,CORES,CPU_TOTAL,CPU_OS,CPU_ORA,CPU_ORA_WAIT,COMMIT,READIO,WAIT\n";

# do not buffer output
$|=1;

# run for ~8 days

my $interval=67;
my $iterations=10300;
$interval=3;
$iterations=3;

my @pFormat=(
	'%s', # timestamp
	'%s', # database
	'%s', # begin_time
	'%s', # end_time
	'%i', # cores
	'%.3f', # CPU total
	'%.3f', # CPU OS
	'%.3f', # CPU oracle
	'%.3f', # CPU oracle wait
	'%.3f', # commit
	'%.3f', # READ IO
	'%.3f' # Wait
);

my $pFormat = join(',',@pFormat);


for (my $i=0;$i < $iterations; $i++) {
	# use sysdate from first service for all for each pass
	my ($timestamp)=('','');

	foreach my $service ( keys %dbh ) {
   	$sth{$service}->execute;
   	my @ary = @{$sth{$service}->fetchrow_arrayref};
		if ($timestamp) {
			shift @ary; # throw away first element if timestamp already captured
		} else {
			$timestamp = shift @ary;
		}
   	#print "$timestamp,$service,", join(',',@ary),"\n";
   	printf "$pFormat\n", $timestamp,$service, @ary;
	}
   sleep $interval;
}

foreach my $service ( keys %dbh ) {
	$sth{$service}->finish;
	$dbh{$service}->disconnect;
}

exit;

sub prep_sql {
$sql=q{with AASIO as (
           select
              class, sum(AAS) AAS, begin_time, end_time
              from (
                 select
                 decode(n.wait_class,'User I/O','User I/O',
                                     'Commit','Commit',
                                     'Wait')                               CLASS,
                 sum(round(m.time_waited/m.INTSIZE_CSEC,3))  AAS,
                 -- normalize the begin/end times between instances
                 -- not perfect but I think close enough for general trends
                 -- should never be more than 2 minutes variance assuming 3+ instances
                 -- 1 minute variance for 2 instances
                 min(BEGIN_TIME) over (partition by decode(n.wait_class,'User I/O','User I/O', 'Commit','Commit', 'Wait')) begin_time ,
                 min(END_TIME) over (partition by decode(n.wait_class,'User I/O','User I/O', 'Commit','Commit', 'Wait')) end_time
           from  gv$waitclassmetric  m,
                 gv$system_wait_class n
           where m.wait_class_id=n.wait_class_id
             and n.wait_class != 'Idle'
                                 and n.inst_id = m.inst_id
           group by  decode(n.wait_class,'User I/O','User I/O', 'Commit','Commit', 'Wait'), BEGIN_TIME, END_TIME
           order by begin_time
         ) 
         group by class, begin_time, end_time
),
CORES as (
   select cpu_core_count from dba_cpu_usage_statistics where timestamp= (select max(timestamp) from dba_cpu_usage_statistics)
),
AASSTAT as (
             select class, aas, begin_time, end_time from aasio
          union
             select 'CPU_ORA_CONSUMED'                                     CLASS,
                    round(sum(value)/100,3)                                     AAS,
                 min(BEGIN_TIME) begin_time,
                 max(END_TIME) end_time
             from gv$sysmetric
             where metric_name='CPU Usage Per Sec'
               and group_id=2
            group by metric_name
          union
           select 'CPU_OS'                                                CLASS ,
                    round((prcnt.busy*parameter.cpu_count)/100,3)          AAS,
                 BEGIN_TIME ,
                 END_TIME
            from
              ( select sum(value) busy, min(BEGIN_TIME) begin_time,max(END_TIME) end_time from gv$sysmetric where metric_name='Host CPU Utilization (%)' and group_id=2 ) prcnt,
              ( select sum(value) cpu_count from gv$parameter where name='cpu_count' )  parameter
          union
             select
               'CPU_ORA_DEMAND'                                            CLASS,
               nvl(round( sum(decode(session_state,'ON CPU',1,0))/60,2),0) AAS,
               cast(min(SAMPLE_TIME) as date) BEGIN_TIME ,
               cast(max(SAMPLE_TIME) as date) END_TIME
             from gv$active_session_history ash
              where SAMPLE_TIME >= (select min(BEGIN_TIME) begin_time from gv$sysmetric where metric_name='CPU Usage Per Sec' and group_id=2 )
               and SAMPLE_TIME < (select max(END_TIME) end_time from gv$sysmetric where metric_name='CPU Usage Per Sec' and group_id=2 )
)
select
       to_char(sysdate,'YYYY-MM-DD HH24:MI:SS') TIMESTAMP,
       to_char(BEGIN_TIME,'YYYY-MM-DD HH24:MI:SS') BEGIN_TIME,
       to_char(END_TIME,'YYYY-MM-DD HH24:MI:SS') END_TIME,
       cpu.cpu_core_count cores,
       ( decode(sign(CPU_OS-CPU_ORA_CONSUMED), -1, 0, (CPU_OS - CPU_ORA_CONSUMED )) +
       CPU_ORA_CONSUMED +
        decode(sign(CPU_ORA_DEMAND-CPU_ORA_CONSUMED), -1, 0, (CPU_ORA_DEMAND - CPU_ORA_CONSUMED ))) CPU_TOTAL,
       decode(sign(CPU_OS-CPU_ORA_CONSUMED), -1, 0, (CPU_OS - CPU_ORA_CONSUMED )) CPU_OS,
       CPU_ORA_CONSUMED CPU_ORA,
       decode(sign(CPU_ORA_DEMAND-CPU_ORA_CONSUMED), -1, 0, (CPU_ORA_DEMAND - CPU_ORA_CONSUMED )) CPU_ORA_WAIT,
       COMMIT,
       READIO,
       WAIT
from (
select
       min(BEGIN_TIME) BEGIN_TIME,
       max(END_TIME) END_TIME,
       sum(decode(CLASS,'CPU_ORA_CONSUMED',AAS,0)) CPU_ORA_CONSUMED,
       sum(decode(CLASS,'CPU_ORA_DEMAND'  ,AAS,0)) CPU_ORA_DEMAND,
       sum(decode(CLASS,'CPU_OS'          ,AAS,0)) CPU_OS,
       sum(decode(CLASS,'Commit'          ,AAS,0)) COMMIT,
       sum(decode(CLASS,'User I/O'        ,AAS,0)) READIO,
       sum(decode(CLASS,'Wait'            ,AAS,0)) WAIT
from AASSTAT
)
, cores cpu
};
};
