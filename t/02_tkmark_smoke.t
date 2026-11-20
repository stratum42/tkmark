#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Spec;
use File::Temp qw(tempfile);
use FindBin;
use JSON::PP   qw(decode_json);
use POSIX      ();

BEGIN {
    if (!$ENV{TCL_TK_MT_NO_REPO_BLIB}) {
        my $tcl_tk_mt_dir = (defined $ENV{TCL_TK_MT_DIR} && length $ENV{TCL_TK_MT_DIR})
            ? $ENV{TCL_TK_MT_DIR}
            : File::Spec->rel2abs(File::Spec->catdir($FindBin::Bin, '..', '..', 'tcl-tk-mt'));
        for my $dir (
            File::Spec->catdir($tcl_tk_mt_dir, 'blib', 'arch'),
            File::Spec->catdir($tcl_tk_mt_dir, 'blib', 'lib'),
            File::Spec->catdir($tcl_tk_mt_dir, 'lib'),
        ) {
            push @INC, $dir if -d $dir;
        }
    }
}

use TkMark::Compute;
use Tcl::Tk::MT::Gfx;

my $repo_root = File::Spec->rel2abs(File::Spec->catdir($FindBin::Bin, '..'));
my $tkmark_pl = File::Spec->catfile($repo_root, 'tkmark.pl');

ok(-f $tkmark_pl, 'tkmark.pl exists')
    or BAIL_OUT("Missing $tkmark_pl");

my $is_mt = TkMark::Compute::is_perl5_mt() ? 1 : 0;
my @stacks = ('dropin');
push @stacks, 'mt_gpu' if $is_mt;

my @scenes = (
    { name => 'fractal', args => [ '--width=160', '--height=120', '--max-iter=32' ] },
    { name => 'boids',   args => [ '--width=200', '--height=150', '--boids=200' ] },
    { name => 'chart',   args => [ '--width=240', '--height=160', '--chart-points=1000' ] },
);

# Preserve caller @INC (e.g. prove -b, -I/tmp/tkmark-blib-stock/..., perl5-mt/lib)
my @inc_flags = map { "-I$_" } grep { defined && !ref($_) && -d $_ } @INC;
my $has_custom_blib = grep { defined && !ref($_) && /blib/ } @INC;

for my $stack (@stacks) {
    for my $sc (@scenes) {
        my $scene = $sc->{name};
        my $label = "$stack/$scene";

        my @cmd = (
            $^X,
            @inc_flags,
            $tkmark_pl,
            '--headless',
            '--json',
            "--stack=$stack",
            "--scene=$scene",
            '--frames=3',
            @{ $sc->{args} },
        );

        my ($ok, $stdout, $stderr, $rc) = run_capture(\@cmd, {
            ($has_custom_blib ? (TCL_TK_MT_NO_REPO_BLIB => '1') : ()),
        });

        ok($ok, "$label exited cleanly (rc=$rc)")
            or diag("CMD: @cmd\nSTDERR:\n$stderr\nSTDOUT:\n$stdout");

        my $data = eval { decode_json($stdout) };
        ok($data && ref($data) eq 'HASH', "$label emitted valid JSON")
            or do {
                diag("JSON parse error: $@\nSTDOUT:\n$stdout\nSTDERR:\n$stderr");
                next;
            };

        is($data->{scene}, $scene, "$label JSON scene matches");
        is($data->{stack}, $stack, "$label JSON stack matches");
        cmp_ok($data->{frames} // 0, '==', 3, "$label rendered 3 frames");
        cmp_ok($data->{fps} // 0, '>', 0, "$label reported non-zero FPS (" . ($data->{fps} // 0) . ")");
        cmp_ok($data->{nonblank_pixels} // 0, '>', 0,
            "$label produced non-blank pixels (" . ($data->{nonblank_pixels} // 0) . ")");
        ok(defined $data->{backend} && length($data->{backend}), "$label reported backend ($data->{backend})");
        ok(defined $data->{p50_ms} && $data->{p50_ms} >= 0, "$label reported p50_ms");
        ok(defined $data->{p95_ms} && $data->{p95_ms} >= 0, "$label reported p95_ms");
    }
}

done_testing();

sub run_capture {
    my ($cmd_ref, $env_ref) = @_;

    my ($err_fh, $err_file) = tempfile(UNLINK => 1);
    close $err_fh;

    my %saved_env;
    for my $k (keys %$env_ref) {
        $saved_env{$k} = exists $ENV{$k} ? $ENV{$k} : undef;
        $ENV{$k} = $env_ref->{$k};
    }

    my $pid = open(my $out_fh, '-|');
    if (!defined $pid) {
        restore_env(\%saved_env);
        return (0, '', "fork failed: $!", -1);
    }

    if ($pid == 0) {
        open STDERR, '>', $err_file or POSIX::_exit(126);
        { exec(@$cmd_ref); }
        print STDERR "exec failed for $cmd_ref->[0]: $!\n";
        POSIX::_exit(127);
    }

    local $/;
    my $stdout = <$out_fh>;
    $stdout = '' unless defined $stdout;
    close $out_fh;
    my $status = $?;

    restore_env(\%saved_env);

    my $stderr = '';
    if (open my $rfh, '<', $err_file) {
        $stderr = <$rfh>;
        $stderr = '' unless defined $stderr;
        close $rfh;
    }

    my $rc = ($status == -1) ? -1 : ($status >> 8);
    return ($status == 0 ? 1 : 0, $stdout, $stderr, $rc);
}

sub restore_env {
    my ($saved) = @_;
    for my $k (keys %$saved) {
        if (defined $saved->{$k}) {
            $ENV{$k} = $saved->{$k};
        }
        else {
            delete $ENV{$k};
        }
    }
}
