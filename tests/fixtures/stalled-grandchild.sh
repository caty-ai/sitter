#!/usr/bin/env bash
set -euo pipefail

# Keep the wrapped parent alive and quiet while its marked descendant holds
# the inherited log fd open. Directly killing this parent leaks the child.
exec perl -e '
  my $pid = fork // die "fork: $!";
  if ($pid == 0) {
    exec $^X, "-e", "sleep 300", $ARGV[0];
    die "exec: $!";
  }
  open my $pid_file, ">", $ENV{SITTER_GRANDCHILD_PID_FILE} or die "pid file: $!";
  print {$pid_file} "$pid\n";
  close $pid_file or die "close pid file: $!";
  $SIG{TERM} = sub { waitpid $pid, 0; exit 0; };
  sleep 300;
' "${SITTER_TEST_MARKER:?missing marker}"
