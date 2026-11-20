#!/usr/bin/env perl
use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use JSON::PP     qw(decode_json encode_json);
use File::Spec;
use File::Path   qw(make_path);
use File::Temp   qw(tempfile);
use Cwd          qw(abs_path);
use FindBin;
use POSIX        qw(strftime);

my $repo_root = abs_path(File::Spec->catdir($FindBin::Bin, '..'));
my $tkmark_pl = File::Spec->catfile($repo_root, 'tkmark.pl');

my $default_tcl_tk_mt_dir = (defined $ENV{TCL_TK_MT_DIR} && length $ENV{TCL_TK_MT_DIR})
    ? $ENV{TCL_TK_MT_DIR}
    : File::Spec->rel2abs(File::Spec->catdir($repo_root, '..', 'tcl-tk-mt'));

my $sibling_mt_perl = File::Spec->rel2abs(File::Spec->catfile($repo_root, '..', 'perl5-mt', 'perl'));
my $sibling_mt_lib  = File::Spec->rel2abs(File::Spec->catdir($repo_root, '..', 'perl5-mt', 'lib'));

my $default_stock_perl = -x '/opt/homebrew/bin/perl' ? '/opt/homebrew/bin/perl' : $^X;
my $default_mt_perl    = (defined $ENV{PERL5_MT} && length $ENV{PERL5_MT})
    ? $ENV{PERL5_MT}
    : (-x $sibling_mt_perl ? $sibling_mt_perl : $^X);
my $default_mt_lib     = (defined $ENV{PERL5_MT_LIB} && length $ENV{PERL5_MT_LIB})
    ? $ENV{PERL5_MT_LIB}
    : (-d $sibling_mt_lib ? $sibling_mt_lib : '');
my $default_accel      = ($^O eq 'darwin') ? 'metal' : 'auto';

my $stock_perl   = $default_stock_perl;
my $stock_blib   = '';
my $mt_perl      = $default_mt_perl;
my $mt_lib       = -d $default_mt_lib ? $default_mt_lib : '';
my $mt_blib      = File::Spec->catdir($repo_root, 'blib');
my $tcl_tk_mt_dir = $default_tcl_tk_mt_dir;
my $accel        = $default_accel;
my $frames       = 20;
my $boids        = 20_000;
my $chart_points = 100_000;
my $fractal_size = '640x480';
my $width        = 800;
my $height       = 600;
my $max_iter     = 128;
my $workers      = 0;
my $scenes_opt   = 'fractal,boids,chart';
my $stacks_opt   = 'stock,dropin,mt_gpu';
my $snapshot_dir = '';
my $json_out     = '';
my $verbose      = 0;
my $help         = 0;

GetOptions(
    'stock-perl=s'   => \$stock_perl,
    'stock-blib=s'   => \$stock_blib,
    'mt-perl=s'      => \$mt_perl,
    'mt-lib=s'       => \$mt_lib,
    'mt-blib=s'      => \$mt_blib,
    'tcl-tk-mt-dir=s'=> \$tcl_tk_mt_dir,
    'accel=s'        => \$accel,
    'frames=i'       => \$frames,
    'boids=i'        => \$boids,
    'chart-points=i' => \$chart_points,
    'fractal-size=s' => \$fractal_size,
    'width=i'        => \$width,
    'height=i'       => \$height,
    'max-iter=i'     => \$max_iter,
    'workers=i'      => \$workers,
    'scenes=s'       => \$scenes_opt,
    'stacks=s'       => \$stacks_opt,
    'snapshot-dir=s' => \$snapshot_dir,
    'json-out=s'     => \$json_out,
    'verbose!'       => \$verbose,
    'help|h'         => \$help,
) or die usage();

if ($help) {
    print usage();
    exit 0;
}

die "Cannot find $tkmark_pl\n" unless -f $tkmark_pl;

my ($frac_w, $frac_h) = $fractal_size =~ /\A(\d+)[xX](\d+)\z/
    or die "Invalid --fractal-size '$fractal_size' (expected WxH, e.g. 640x480)\n";

my @scenes = grep { length } split /,/, $scenes_opt;
my @stacks = grep { length } split /,/, $stacks_opt;

if ($snapshot_dir) {
    make_path($snapshot_dir) unless -d $snapshot_dir;
}

my %stack_spec = (
    stock => {
        label  => 'stock',
        perl   => $stock_perl,
        blib   => $stock_blib || File::Spec->catdir($repo_root, 'blib'),
        extra_lib => '',
        accel  => 'off',
        custom_blib => $stock_blib ? 1 : 0,
    },
    dropin => {
        label  => 'dropin',
        perl   => $stock_perl,
        blib   => $stock_blib || File::Spec->catdir($repo_root, 'blib'),
        extra_lib => '',
        accel  => $accel,
        custom_blib => $stock_blib ? 1 : 0,
    },
    mt_gpu => {
        label  => 'mt_gpu',
        perl   => $mt_perl,
        blib   => $mt_blib,
        extra_lib => $mt_lib,
        accel  => $accel,
        custom_blib => ($mt_blib ne File::Spec->catdir($repo_root, 'blib')) ? 1 : 0,
    },
);

my %scene_title = (
    fractal => "Fractal (${frac_w}x${frac_h}, iter=${max_iter})",
    boids   => "Boids (" . format_count($boids) . ")",
    chart   => "Chart (" . format_count($chart_points) . " pts)",
);

my %results;   # $results{$scene}{$stack} = $hashref
my @raw_runs;
my @errors;

for my $scene (@scenes) {
    for my $stack (@stacks) {
        my $spec = $stack_spec{$stack}
            or die "Unknown stack '$stack' (expected stock, dropin, mt_gpu)\n";

        unless ($spec->{perl} && -x $spec->{perl}) {
            my $err = "Perl binary not executable: " . ($spec->{perl} // '<unset>');
            $results{$scene}{$stack} = { error => $err, scene => $scene, stack => $stack };
            push @errors, "$scene/$stack: $err";
            next;
        }

        my @cmd = ($spec->{perl});
        push @cmd, "-I$spec->{extra_lib}" if $spec->{extra_lib} && -d $spec->{extra_lib};
        if ($spec->{blib} && -d $spec->{blib}) {
            my $blib_arch = File::Spec->catdir($spec->{blib}, 'arch');
            my $blib_lib  = File::Spec->catdir($spec->{blib}, 'lib');
            push @cmd, "-I$blib_arch" if -d $blib_arch;
            push @cmd, "-I$blib_lib"  if -d $blib_lib;
        }
        if (!$spec->{custom_blib} && $tcl_tk_mt_dir && -d $tcl_tk_mt_dir) {
            for my $dir (
                File::Spec->catdir($tcl_tk_mt_dir, 'blib', 'arch'),
                File::Spec->catdir($tcl_tk_mt_dir, 'blib', 'lib'),
                File::Spec->catdir($tcl_tk_mt_dir, 'lib'),
            ) {
                push @cmd, "-I$dir" if -d $dir;
            }
        }
        push @cmd, "-I" . File::Spec->catdir($repo_root, 'lib');
        push @cmd, $tkmark_pl, '--headless', '--json', "--scene=$scene", "--stack=$stack", "--frames=$frames";

        if ($scene eq 'fractal') {
            push @cmd, "--width=$frac_w", "--height=$frac_h", "--max-iter=$max_iter";
        }
        elsif ($scene eq 'boids') {
            push @cmd, "--width=$width", "--height=$height", "--boids=$boids";
        }
        elsif ($scene eq 'chart') {
            push @cmd, "--width=$width", "--height=$height", "--chart-points=$chart_points";
        }
        else {
            push @cmd, "--width=$width", "--height=$height";
        }

        push @cmd, "--workers=$workers" if $workers > 0;
        push @cmd, "--snapshot-dir=$snapshot_dir" if $snapshot_dir;

        my %env = (
            TCL_TK_MT_ACCEL => $spec->{accel},
            ($tcl_tk_mt_dir ? (TCL_TK_MT_DIR => $tcl_tk_mt_dir) : ()),
        );
        $env{TCL_TK_MT_NO_REPO_BLIB} = '1' if $spec->{custom_blib};

        if ($verbose) {
            warn sprintf("[run %s/%s] TCL_TK_MT_ACCEL=%s %s\n",
                $scene, $stack, $spec->{accel}, join(' ', @cmd));
        }

        my ($ok, $stdout, $stderr, $rc) = run_capture(\@cmd, \%env);
        if (!$ok) {
            my $msg = "exit=$rc";
            $msg .= " stderr=" . trim_one_line($stderr) if defined $stderr && length $stderr;
            $results{$scene}{$stack} = { error => $msg, scene => $scene, stack => $stack };
            push @errors, "$scene/$stack: $msg";
            next;
        }

        warn "[json $scene/$stack] $stdout\n" if $verbose;

        my $data = parse_json_output($stdout);
        if (!$data || ref($data) ne 'HASH') {
            my $msg = "invalid JSON output: " . trim_one_line($stdout);
            $results{$scene}{$stack} = { error => $msg, scene => $scene, stack => $stack };
            push @errors, "$scene/$stack: $msg";
            next;
        }

        $results{$scene}{$stack} = $data;
        push @raw_runs, $data;
    }
}

# Print Markdown report
my $ts = strftime('%Y-%m-%d %H:%M:%S %Z', localtime());
print "# TkMark Studio: 3-Stack Benchmark Comparison\n\n";
print "- **Date:** $ts\n";
print "- **Platform:** `$^O` | **Accel:** `$accel` | **Frames/scene:** `$frames`\n";
print "- **Workloads:** Fractal `${frac_w}x${frac_h}` (`max_iter=$max_iter`), Boids `" . format_count($boids) . "`, Chart `" . format_count($chart_points) . "` pts\n";
print "- **Stock Perl:** `$stock_perl`" . ($stock_blib ? " (blib: `$stock_blib`)" : '') . "\n";
print "- **perl5-mt:** `$mt_perl`" . ($mt_blib ? " (blib: `$mt_blib`)" : '') . "\n\n";

print "## Detailed Frame Timings\n\n";
print "| Scene | Stack | Backend | Perl | FPS | p50 (ms) | p95 (ms) | Compute (ms) | Render (ms) | vs Stock |\n";
print "| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |\n";

for my $scene (@scenes) {
    my $stock_fps = ($results{$scene}{stock} && !$results{$scene}{stock}{error})
        ? ($results{$scene}{stock}{fps} || 0)
        : 0;
    my $label = $scene_title{$scene} // $scene;

    for my $stack (@stacks) {
        my $r = $results{$scene}{$stack} || { error => 'missing' };
        if ($r->{error}) {
            printf "| %s | `%s` | ERR | - | - | - | - | - | - | - |\n",
                $label, $stack;
            next;
        }
        my $fps     = $r->{fps}        // 0;
        my $p50     = $r->{p50_ms}     // 0;
        my $p95     = $r->{p95_ms}     // 0;
        my $comp    = $r->{compute_ms} // 0;
        my $rend    = $r->{render_ms}  // 0;
        my $be      = $r->{backend}    // 'n/a';
        my $pver    = ($r->{perl_version} // '?') . ($r->{is_perl5_mt} ? ' (mt)' : '');
        my $speedup = ($stack eq 'stock') ? '1.00x'
                    : ($stock_fps > 0 && $fps > 0) ? sprintf('**%.2fx**', $fps / $stock_fps)
                    : '-';

        printf "| %s | `%s` | `%s` | %s | %.2f | %.2f | %.2f | %.2f | %.2f | %s |\n",
            $label, $stack, $be, $pver, $fps, $p50, $p95, $comp, $rend, $speedup;
    }
}

print "\n## Speedup Summary\n\n";
print "| Scene | `stock` FPS | `dropin` FPS | `mt_gpu` FPS | `dropin` vs `stock` | `mt_gpu` vs `stock` | `mt_gpu` vs `dropin` |\n";
print "| --- | ---: | ---: | ---: | ---: | ---: | ---: |\n";

for my $scene (@scenes) {
    my $label = $scene_title{$scene} // $scene;
    my $s_fps = valid_fps($results{$scene}{stock});
    my $d_fps = valid_fps($results{$scene}{dropin});
    my $m_fps = valid_fps($results{$scene}{mt_gpu});

    printf "| %s | %s | %s | %s | %s | %s | %s |\n",
        $label,
        fmt_num($s_fps),
        fmt_num($d_fps),
        fmt_num($m_fps),
        fmt_ratio($d_fps, $s_fps),
        fmt_ratio($m_fps, $s_fps),
        fmt_ratio($m_fps, $d_fps);
}

if ($snapshot_dir) {
    my @snaps = grep { defined && length } map { $_->{snapshot} } @raw_runs;
    if (@snaps) {
        print "\n## Visual Comparison Snapshots\n\n";
        print "- `$_`\n" for @snaps;
    }
}

if (@errors) {
    print "\n## Errors\n\n";
    print "- $_\n" for @errors;
}

if ($json_out) {
    open my $out_fh, '>', $json_out or die "Cannot write $json_out: $!\n";
    print {$out_fh} JSON::PP->new->utf8->pretty->canonical->encode({
        timestamp => $ts,
        platform  => $^O,
        accel     => $accel,
        frames    => $frames,
        workloads => {
            fractal_size => $fractal_size,
            max_iter     => $max_iter,
            boids        => $boids,
            chart_points => $chart_points,
        },
        runs      => \@raw_runs,
        errors    => \@errors,
    });
    close $out_fh;
}

exit(@errors ? 1 : 0);

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

sub parse_json_output {
    my ($text) = @_;
    return undef unless defined $text && length $text;
    my $parsed = eval { decode_json($text) };
    return $parsed if $parsed;
    if ($text =~ /(\{.*\})/s) {
        $parsed = eval { decode_json($1) };
        return $parsed if $parsed;
    }
    return undef;
}

sub valid_fps {
    my ($r) = @_;
    return undef unless $r && ref($r) eq 'HASH' && !$r->{error};
    return defined $r->{fps} ? $r->{fps} : undef;
}

sub fmt_num {
    my ($v) = @_;
    return defined $v ? sprintf('%.2f', $v) : '-';
}

sub fmt_ratio {
    my ($num, $den) = @_;
    return '-' unless defined $num && defined $den && $den > 0 && $num > 0;
    return sprintf('**%.2fx**', $num / $den);
}

sub format_count {
    my ($n) = @_;
    return sprintf('%.0fk', $n / 1000) if $n >= 1000 && ($n % 1000 == 0);
    return $n;
}

sub trim_one_line {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/\s+/ /g;
    $s =~ s/\A\s+|\s+\z//g;
    $s = substr($s, 0, 240) . '...' if length($s) > 240;
    return $s;
}

sub usage {
    return <<"USAGE";
Usage: $0 [options]

Compare TkMark Studio across 3 stacks (stock, dropin, mt_gpu) and 3 scenes (fractal, boids, chart).

Options:
  --stock-perl=PATH    Stock Perl 5 binary (default: $default_stock_perl)
  --stock-blib=DIR     Separate blib/ built for stock Perl (enables side-by-side runs)
  --mt-perl=PATH       perl5-mt binary (default: $default_mt_perl)
  --mt-lib=DIR         perl5-mt lib directory (default: $default_mt_lib)
  --mt-blib=DIR        blib/ built for perl5-mt (default: <repo>/blib)
  --tcl-tk-mt-dir=DIR  Path to Tcl::Tk::MT checkout (default: \$ENV{TCL_TK_MT_DIR} or ../tcl-tk-mt)
  --accel=BACKEND      TCL_TK_MT_ACCEL for dropin/mt_gpu (default: $default_accel)
  --frames=N           Frames per scene (default: $frames)
  --boids=N            Boids particle count (default: $boids)
  --chart-points=N     Chart data points (default: $chart_points)
  --fractal-size=WxH   Fractal resolution (default: $fractal_size)
  --width=W            Viewport width for boids/chart (default: $width)
  --height=H           Viewport height for boids/chart (default: $height)
  --max-iter=N         Fractal max iterations (default: $max_iter)
  --workers=N          Worker count for mt_gpu (default: 0 = auto)
  --scenes=LIST        Comma-separated scenes (default: fractal,boids,chart)
  --stacks=LIST        Comma-separated stacks (default: stock,dropin,mt_gpu)
  --snapshot-dir=DIR   Save PPM visual comparison snapshots into DIR
  --json-out=PATH      Write raw JSON benchmark data to PATH
  --verbose            Print commands and raw JSON to STDERR
  --help               Show this help
USAGE
}
