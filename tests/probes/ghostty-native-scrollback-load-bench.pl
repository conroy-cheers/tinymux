#!/usr/bin/env perl
use strict;
use warnings;
use Time::HiRes qw(time);

my $lines = $ENV{LINES_TO_LOAD} // 10_000;
my $cols = $ENV{COLUMNS_TO_LOAD} // ($ENV{COLUMNS} // 120);
$cols = 20 if $cols < 20;
my $payload_cols = $cols - 32;
$payload_cols = 1 if $payload_cols < 1;

$| = 1;
print "\e[r\e[?25l\e[2J\e[H";
print "Ghostty native scrollback load benchmark\n";
print "Writing $lines lines at approximately $cols columns. Token: TINYMUX_NATIVE_LOAD_BENCH_000001\n";
print "Starting in 1s...\n";
select undef, undef, undef, 1.0;

my $payload = "x" x $payload_cols;
my $start = time();
my $bytes = 0;
for my $i (1 .. $lines) {
    my $line = sprintf("TINYMUX_NATIVE_LOAD_BENCH_%06d %s\n", $i, $payload);
    $bytes += length($line);
    print $line;
}
my $elapsed = time() - $start;
my $mb = $bytes / 1_000_000;
my $ms = $elapsed * 1000.0;
my $mbps = $elapsed > 0 ? $mb / $elapsed : 0;

print "\e[?25h";
printf "\nloaded_lines=%d bytes=%d elapsed_ms=%.1f throughput_mbps=%.1f\n", $lines, $bytes, $ms, $mbps;
print "Use Ghostty search for TINYMUX_NATIVE_LOAD_BENCH_000001, then press Enter to exit. ";
<STDIN>;
