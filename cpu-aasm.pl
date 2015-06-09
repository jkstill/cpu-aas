#!/usr/local/bin/perl
#!/u01/app/oracle/product/11.2.0/oms/perl/bin/perl

# see http://datavirtualizer.com/oracle-cpu-time/

use Data::Dumper;
use warnings;
use FileHandle;
use DBI;
use strict;
use Getopt::Long;
use Pod::Usage;

my $debug=0;
my ($man,$help);
my %optctl=();

GetOptions(\%optctl,
	"interval=i",
	"iterations=i",
	"delimiter=s",
	"sysdba!",
	'debug!' => \$debug,
	'help|?' => \$help, man => \$man
) or pod2usage(2) ;

pod2usage(1) if $help;
pod2usage(-verbose => 2) if $man;

my $interval = defined($optctl{interval}) ? $optctl{interval} : 67;
my $iterations = defined($optctl{iterations}) ? $optctl{iterations} : 5;
my $delimiter = defined($optctl{delimiter}) ? $optctl{delimiter} : ',';

my $connectionMode = 0;
if ( $optctl{sysdba} ) { $connectionMode = 2 }

# this script will connect to an arbitrary number of databases
# look for connections file
# something on the command line
# curr dir
# home

my $connectionsFileName='cpu-aas-connect.txt';

if (-r $connectionsFileName) {
	print "Using connections file: $connectionsFileName\n" if $debug;
	open CONN,'<',$connectionsFileName;
} else {
	die "No connections file found\n";
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
      	ora_session_mode => $connectionMode # 0=normal 1=sysoper 2=sysdba
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

print join($delimiter,qw(TIMESTAMP DATABASE HOST_NAME INSTANCE BEGIN_TIME END_TIME CORES CPU_TOTAL CPU_OS CPU_ORA CPU_ORA_WAIT COMMIT READIO WAIT)),"\n";

# do not buffer output
$|=1;

# run for ~8 days
#my $interval=67;
#my $iterations=10300;

my @pFormat=(
	'%s', # timestamp
	'%s', # database
	'%s', # host_name
	'%i', # instance
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

my $pFormat = join($delimiter,@pFormat);

for (my $i=0;$i < $iterations; $i++) {
	# use sysdate from first service for all for each pass
	my ($timestamp)=('','');

	foreach my $service ( keys %dbh ) {
   	$sth{$service}->execute;
		# if using the '@ary = @{$something}' form in the loop
		# there is always an undef on the last iteration
		# dunno if bug in DBI/DBD/Perl, whatever
		# stuffing the contents of the array ref in to a private array
		# as a workaround for shift to work.

   	#while ( my @ary = @{$sth{$service}->fetchrow_arrayref} ) {
   	while ( my $ary = $sth{$service}->fetchrow_arrayref ) {
			my @ary = @{$ary};
			#print "Array: ", join(',',@ary),"\n";
			if ($timestamp) {
				shift @ary; # throw away first element if timestamp already captured
			} else {
				$timestamp = shift @ary;
			}
   		#print "$timestamp,$service,$instanceID,", join(',',@ary),"\n";
   		printf "$pFormat\n", $timestamp, @ary;
		}
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
	select inst_id, class, sum(AAS) AAS, begin_time, end_time
	from (
		select m.inst_id,
			decode(n.wait_class
				,'User I/O','User I/O',
				'Commit','Commit',
				'Wait'
			) CLASS,
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
			group by  m.inst_id, decode(n.wait_class,'User I/O','User I/O', 'Commit','Commit', 'Wait') , BEGIN_TIME, END_TIME
			order by begin_time
	)
	group by inst_id, class, begin_time, end_time
),
CORES as (
	select inst_id, cpu_count_current cpu_core_count from gv$license
),
AASSTAT as (
	select inst_id, class, aas, begin_time, end_time from aasio
union
	select inst_id,
		'CPU_ORA_CONSUMED'                                     CLASS,
		round(sum(value)/100,3)                                     AAS,
		min(BEGIN_TIME) begin_time,
		max(END_TIME) end_time
	from gv$sysmetric
	where metric_name='CPU Usage Per Sec'
		and group_id=2
	group by inst_id,metric_name
union
	select prcnt.inst_id,
		'CPU_OS'                                                CLASS ,
		round((prcnt.busy*cores.cpu_core_count)/100,3)          AAS,
		BEGIN_TIME ,
		END_TIME
	from
		(
			select inst_id,
				sum(value) busy,
				min(BEGIN_TIME) begin_time,
				max(END_TIME) end_time
			from gv$sysmetric
			where metric_name='Host CPU Utilization (%)'
				and group_id=2
			group by inst_id
		) prcnt,
		cores
		where cores.inst_id = prcnt.inst_id
union
	select ash.inst_id,
		'CPU_ORA_DEMAND'                                            CLASS,
		nvl(round( sum(decode(session_state,'ON CPU',1,0))/60,2),0) AAS,
		cast(min(SAMPLE_TIME) as date) BEGIN_TIME ,
		cast(max(SAMPLE_TIME) as date) END_TIME
	from gv$active_session_history ash
	where SAMPLE_TIME >= (select min(BEGIN_TIME) begin_time from gv$sysmetric where metric_name='CPU Usage Per Sec' and group_id=2 )
		and SAMPLE_TIME < (select max(END_TIME) end_time from gv$sysmetric where metric_name='CPU Usage Per Sec' and group_id=2 )
	group by ash.inst_id
)
select
		 to_char(sysdate,'YYYY-MM-DD HH24:MI:SS') TIMESTAMP,
		 d.name database,
		 i.host_name,
		 stats.inst_id,
       to_char(BEGIN_TIME,'YYYY-MM-DD HH24:MI:SS') BEGIN_TIME,
       to_char(END_TIME,'YYYY-MM-DD HH24:MI:SS') END_TIME,
       cpu.cpu_core_count cores,
       (
		 	decode(sign(CPU_OS-CPU_ORA_CONSUMED), -1, 0, (CPU_OS - CPU_ORA_CONSUMED ))
			+ CPU_ORA_CONSUMED
			+ decode(sign(CPU_ORA_DEMAND-CPU_ORA_CONSUMED), -1, 0, (CPU_ORA_DEMAND - CPU_ORA_CONSUMED ))
		 ) CPU_TOTAL,
       decode(sign(CPU_OS-CPU_ORA_CONSUMED), -1, 0, (CPU_OS - CPU_ORA_CONSUMED )) CPU_OS,
       CPU_ORA_CONSUMED CPU_ORA,
       decode(sign(CPU_ORA_DEMAND-CPU_ORA_CONSUMED), -1, 0, (CPU_ORA_DEMAND - CPU_ORA_CONSUMED )) CPU_ORA_WAIT,
       COMMIT,
       READIO,
       WAIT
from (
	select
		inst_id,
		min(BEGIN_TIME) BEGIN_TIME,
		max(END_TIME) END_TIME,
		sum(decode(CLASS,'CPU_ORA_CONSUMED',AAS,0)) CPU_ORA_CONSUMED,
		sum(decode(CLASS,'CPU_ORA_DEMAND'  ,AAS,0)) CPU_ORA_DEMAND,
		sum(decode(CLASS,'CPU_OS'          ,AAS,0)) CPU_OS,
		sum(decode(CLASS,'Commit'          ,AAS,0)) COMMIT,
		sum(decode(CLASS,'User I/O'        ,AAS,0)) READIO,
		sum(decode(CLASS,'Wait'            ,AAS,0)) WAIT
	from AASSTAT
	group by inst_id
) stats
	, cores cpu
	, gv$instance i
	, gv$database d
where cpu.inst_id = stats.inst_id
and i.inst_id = stats.inst_id
and d.inst_id = stats.inst_id
};
};


__END__

=head1 NAME

cpu-aasm.pl

--help brief help message
--man  full documentation
--interval seconds between snapshots - default is 0
--sysdba - connect as sysdba
--iterations number of snapshots - default is 5
--delimiter output field delimiter - default is ,

=head1 SYNOPSIS

sample [options] [file ...]

 Options:
   --help brief help message
   --man  full documentation
   --sysdba connect as sysdba if this option is used
   --interval seconds between snapshots - default is 0
   --iterations number of snapshots - default is 5
   --delimiter output field delimiter - default is ,

=head1 OPTIONS

=over 8

=item B<--help>

Print a brief help message and exits.

=item B<--man>

Prints the manual page and exits.

=item B<--interval>

The integer number of seconds between each snapshot of ASM storage metrics

=item B<--iterations>

The integer number of the number of snapshots of ASM storage metrics

=item B<--delimiter>

The character used as a delimiter between output fields for the CSV output.

=back 

=head1 DESCRIPTION

B<cpu-aasm.pl> will connect as SYSDBA to the currently set ORACLE_SID.

Collects CPU Metrics from an Oracle perspective.

Database connections are defined in ./cpu-aas-connect.txt
 username:password:connect_string

Output is to STDOUT, so it will be necessary to redirect to a file if results are to be saved.

This script inspired by http://datavirtualizer.com/oracle-cpu-time/


=head1 EXAMPLE

20 snapshots at 10 second intervals

  cpu-aasm.pl  -interval 10 -iterations 20 -delimiter ,

=cut

