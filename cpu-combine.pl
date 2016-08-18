#!/usr/bin/env perl
#
use Data::Dumper;

# combine database stats for CPU
#
#

open CSV,'<','cpu-combine-test-data.csv' || die "cannot open file - $!\n";

# group on timestamp 
# take the greater of CPU_OS
# add the others together

my @timestampIDX=();
my %cpuData=();

# field numbers
my %f = (
	timestamp => 0,
	database => 1,
	host_name => 2,
	instance => 3,
	begin_time => 4,
	end_time => 5,
	cores => 6,
	cpu_total => 7,
	cpu_os => 8,
	cpu_ora => 9,
	cpu_ora_wait => 10,
	commit => 11,
	readio => 12,
	wait => 13
);

# get and print the header line
my $dummy=<CSV>;
print $dummy;

my $cpuOraPrevious;

while (<CSV>) {
	chomp;
	my @data=split(/,/);
	my $timestamp = $data[$f{timestamp}];
	push @timestampIDX, $timestamp if ! exists $cpuData{$timestamp};

	$cpuData{$timestamp}->[$f{database}] = 'COMBINED';
	$cpuData{$timestamp}->[$f{host_name}] = $data[$f{host_name}];
	$cpuData{$timestamp}->[$f{instance}] = 'COMBINED';
	$cpuData{$timestamp}->[$f{begin_time}] = $data[$f{begin_time}];
	$cpuData{$timestamp}->[$f{end_time}] = $data[$f{end_time}];
	$cpuData{$timestamp}->[$f{cores}] = $data[$f{cores}];

	# not sure this is entirely correct for cpu_total
	# certain they are not additive though - see cpu-assm.pl
	# cpu_total = cpu_os + cpu_ora in original data
	#
	#print "Timestamp: $timestamp\n";
	if ( ! defined( $cpuData{$timestamp}->[$f{cpu_total}] ) ) {
		$cpuOraPrevious = $data[$f{cpu_ora}];
		#print "Not Defined: $cpuOraPrevious\n";
		$cpuData{$timestamp}->[$f{cpu_total}] = $data[$f{cpu_total}];
	} else {
		if ( $data[$f{cpu_total}] > $cpuData{$timestamp}->[$f{cpu_total}] ) {
				#print "IF cpu_ora: $cpuOraPrevious\n";
				$cpuData{$timestamp}->[$f{cpu_total}] = $data[$f{cpu_total}];
				$cpuData{$timestamp}->[$f{cpu_total}] += $cpuOraPrevious;
		} else {
				#print "ELSE cpu_ora: $cpuOraPrevious\n";
				$cpuData{$timestamp}->[$f{cpu_total}] += $data[$f{cpu_ora}];
		}
		$cpuOraPrevious = 0;
	}

	if ( defined( $cpuData{$timestamp}->[$f{cpu_os}] ) ) {
		$cpuData{$timestamp}->[$f{cpu_os}] = $data[$f{cpu_os}];
	} else {
		$cpuData{$timestamp}->[$f{cpu_os}] = $cpuData{$timestamp}->[$f{cpu_os}] >= $data[$f{cpu_os}] ? $cpuData{$timestamp}->[$f{cpu_os}] : $data[$f{cpu_os}];
	}

	$cpuData{$timestamp}->[$f{cpu_ora}] += $data[$f{cpu_ora}];
	$cpuData{$timestamp}->[$f{cpu_ora_wait}] += $data[$f{cpu_ora_wait}];
	$cpuData{$timestamp}->[$f{commit}] += $data[$f{commit}];
	$cpuData{$timestamp}->[$f{readio}] += $data[$f{readio}];
	$cpuData{$timestamp}->[$f{wait}] += $data[$f{wait}];

}

#print Dumper(\@timestampIDX);
#

foreach my $timestamp ( @timestampIDX ) {

	print "$timestamp", join(',',@{$cpuData{$timestamp}}), "\n";

}


