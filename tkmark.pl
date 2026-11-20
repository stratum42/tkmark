#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use File::Spec;
use Getopt::Long qw(GetOptions);
use Time::HiRes  qw(time);

BEGIN {
    my $tkmark_root = File::Spec->rel2abs($FindBin::Bin);
    # Push repo blib dirs to the END of @INC so explicit -I (e.g. --stock-blib
    # or installed site_perl) always wins.
    if (!$ENV{TCL_TK_MT_NO_REPO_BLIB}) {
        for my $dir (
            File::Spec->catdir($tkmark_root, 'blib', 'arch'),
            File::Spec->catdir($tkmark_root, 'blib', 'lib'),
        ) {
            push @INC, $dir if -d $dir;
        }
        my $tcl_tk_mt_dir = (defined $ENV{TCL_TK_MT_DIR} && length $ENV{TCL_TK_MT_DIR})
            ? $ENV{TCL_TK_MT_DIR}
            : File::Spec->rel2abs(File::Spec->catdir($tkmark_root, '..', 'tcl-tk-mt'));
        for my $dir (
            File::Spec->catdir($tcl_tk_mt_dir, 'blib', 'arch'),
            File::Spec->catdir($tcl_tk_mt_dir, 'blib', 'lib'),
            File::Spec->catdir($tcl_tk_mt_dir, 'lib'),
        ) {
            push @INC, $dir if -d $dir;
        }
    }
    push @INC, File::Spec->catdir($tkmark_root, 'lib');
}

# Load all TkMark modules BEFORE any MT::Pool creation so worker compartments
# inherit every named worker sub in the frozen interpreter image.
use TkMark::Engine;
use TkMark::SceneFractal;
use TkMark::SceneBoids;
use TkMark::SceneChart;

my $opt_stack        = 'auto';
my $opt_scene        = 'fractal';
my $opt_headless     = 0;
my $opt_frames       = 30;
my $opt_width        = 800;
my $opt_height       = 600;
my $opt_count        = 0;
my $opt_boids        = 20_000;
my $opt_chart_points = 100_000;
my $opt_max_iter     = 128;
my $opt_workers      = 0;
my $opt_backend      = '';
my $opt_cpan_tcltk   = 0;
my $opt_json         = 0;
my $opt_snapshot     = '';
my $opt_snapshot_dir = '';
my $opt_auto_exit_ms = 0;
my $opt_help         = 0;

GetOptions(
    'stack=s'        => \$opt_stack,
    'scene=s'        => \$opt_scene,
    'headless!'      => \$opt_headless,
    'frames=i'       => \$opt_frames,
    'width=i'        => \$opt_width,
    'height=i'       => \$opt_height,
    'count=i'        => \$opt_count,
    'boids=i'        => \$opt_boids,
    'chart-points=i' => \$opt_chart_points,
    'max-iter=i'     => \$opt_max_iter,
    'workers=i'      => \$opt_workers,
    'backend=s'      => \$opt_backend,
    'cpan-tcltk!'    => \$opt_cpan_tcltk,
    'json!'          => \$opt_json,
    'snapshot=s'     => \$opt_snapshot,
    'snapshot-dir=s' => \$opt_snapshot_dir,
    'auto-exit-ms=i' => \$opt_auto_exit_ms,
    'help|h!'        => \$opt_help,
) or die "Run with --help for usage.\n";

if ($opt_help) {
    print <<'USAGE';
TkMark Studio - 3-Stack Tcl::Tk::MT Benchmark & Interactive Suite

Usage:
  perl tkmark.pl [options]

Options:
  --stack=auto|stock|dropin|mt_gpu   Execution stack (default: auto)
  --scene=fractal|boids|chart|all    Active scene or 'all' in headless mode (default: fractal)
  --headless                         Run offscreen benchmark without GUI MainLoop
  --frames=N                         Frames per scene in headless mode (default: 30)
  --width=W --height=H               Viewport dimensions (default: 800x600)
  --count=N                          Generic count override (boids or chart-points)
  --boids=N                          Boids particle count (default: 20000)
  --chart-points=N                   Chart telemetry point count (default: 100000)
  --max-iter=N                       Fractal max iterations (default: 128)
  --workers=N                        MT::Pool workers for mt_gpu (default: auto, up to 8)
  --backend=auto|metal|vulkan|software|off   Explicit gfx backend override
  --cpan-tcltk                       In stock interactive mode, prefer CPAN Tcl::Tk if installed
  --json                             Emit machine-readable JSON in headless mode
  --snapshot=PATH                    Write PPM (P6) snapshot of final frame
  --snapshot-dir=DIR                 Write <DIR>/<scene>_<stack>.ppm snapshots
  --auto-exit-ms=N                   Auto-close GUI window after N ms (for smoke testing)
USAGE
    exit 0;
}

$opt_scene = lc($opt_scene);
die "Invalid --scene '$opt_scene' (expected fractal|boids|chart|all)\n"
    unless $opt_scene eq 'fractal' || $opt_scene eq 'boids' || $opt_scene eq 'chart' || $opt_scene eq 'all';

my $stack   = TkMark::Engine::resolve_stack($opt_stack);
my $backend = TkMark::Engine::resolve_backend($stack, $opt_backend, $opt_headless);
my $workers = ($stack eq 'mt_gpu' && TkMark::Engine::has_pool())
    ? ($opt_workers > 0 ? $opt_workers : TkMark::Engine::detect_cpu_cores())
    : 1;

if ($opt_headless) {
    run_headless();
    TkMark::Engine::shutdown_pool();
    exit 0;
}
else {
    run_interactive();
    TkMark::Engine::shutdown_pool();
    exit 0;
}

# =============================================================================
# Headless Benchmark Runner
# =============================================================================
sub _snapshot_path_for {
    my ($scene_name, $is_all) = @_;
    if (length $opt_snapshot_dir) {
        return File::Spec->catfile($opt_snapshot_dir, "${scene_name}_${stack}.ppm");
    }
    if (length $opt_snapshot) {
        if ($is_all) {
            my $p = $opt_snapshot;
            if ($p =~ s/\.ppm\z//i) {
                return "${p}_${scene_name}.ppm";
            }
            return "${p}_${scene_name}.ppm";
        }
        return $opt_snapshot;
    }
    return undef;
}

sub _bench_one_scene {
    my ($scene_name, $is_all) = @_;
    require Tcl::Tk::MT::Canvas;

    my $w = $opt_width;
    my $h = $opt_height;
    my $bg = ($scene_name eq 'boids') ? '#060911' : '#0b0f17';

    my $canvas = Tcl::Tk::MT::Canvas->new(undef,
        -width    => $w,
        -height   => $h,
        -bg       => $bg,
        -backend  => $backend,
        -headless => 1,
    );

    my $scene;
    if ($scene_name eq 'fractal') {
        $scene = TkMark::SceneFractal->new(
            canvas   => $canvas,
            width    => $w,
            height   => $h,
            stack    => $stack,
            max_iter => $opt_max_iter,
            workers  => $workers,
            headless => 1,
        );
    }
    elsif ($scene_name eq 'boids') {
        my $n = ($opt_count > 0 && !$is_all) ? $opt_count : $opt_boids;
        $scene = TkMark::SceneBoids->new(
            canvas   => $canvas,
            width    => $w,
            height   => $h,
            stack    => $stack,
            count    => $n,
            headless => 1,
        );
    }
    elsif ($scene_name eq 'chart') {
        my $n = ($opt_count > 0 && !$is_all) ? $opt_count : $opt_chart_points;
        $scene = TkMark::SceneChart->new(
            canvas   => $canvas,
            width    => $w,
            height   => $h,
            stack    => $stack,
            count    => $n,
            headless => 1,
        );
    }

    # 1 warmup frame (shader/pipeline/pool warm-up)
    $scene->step_frame('warming up...');

    my (@frame_ms, @comp_ms, @ren_ms);
    my $frames = $opt_frames > 0 ? $opt_frames : 1;

    my $t_all0 = time();
    for my $f (1 .. $frames) {
        my $tf0 = time();
        my $hud = sprintf('frame %d/%d | %s (%s)', $f, $frames, $stack, $canvas->backend_name());
        my ($cm, $rm) = $scene->step_frame($hud);
        my $fm = (time() - $tf0) * 1000.0;
        push @frame_ms, $fm;
        push @comp_ms,  $cm;
        push @ren_ms,   $rm;
    }
    my $total_ms = (time() - $t_all0) * 1000.0;

    my $rgba     = $canvas->readback_rgba();
    my $nonblank = TkMark::Engine::count_nonblank_pixels($rgba, $bg);

    my $snap_path = _snapshot_path_for($scene_name, $is_all);
    if (defined $snap_path) {
        TkMark::Engine::write_ppm($snap_path, $rgba, $w, $h);
    }

    my $fps      = $total_ms > 0 ? ($frames / ($total_ms / 1000.0)) : 0.0;
    my $avg_ms   = TkMark::Engine::mean(\@frame_ms);
    my $p50_ms   = TkMark::Engine::percentile(\@frame_ms, 50);
    my $p95_ms   = TkMark::Engine::percentile(\@frame_ms, 95);
    my $mean_cmp = TkMark::Engine::mean(\@comp_ms);
    my $mean_ren = TkMark::Engine::mean(\@ren_ms);

    return {
        scene           => $scene_name,
        stack           => $stack,
        backend         => $canvas->backend_name(),
        perl_version    => "$^V",
        is_perl5_mt     => TkMark::Engine::json_bool(TkMark::Engine::is_perl5_mt()),
        have_packed_av  => TkMark::Engine::json_bool(TkMark::Engine::have_packed_av()),
        workers         => $workers + 0,
        width           => $w + 0,
        height          => $h + 0,
        count           => $scene->item_count() + 0,
        frames          => $frames + 0,
        fps             => sprintf('%.3f', $fps) + 0,
        total_ms        => sprintf('%.3f', $total_ms) + 0,
        avg_frame_ms    => sprintf('%.3f', $avg_ms) + 0,
        p50_ms          => sprintf('%.3f', $p50_ms) + 0,
        p95_ms          => sprintf('%.3f', $p95_ms) + 0,
        compute_ms      => sprintf('%.3f', $mean_cmp) + 0,
        render_ms       => sprintf('%.3f', $mean_ren) + 0,
        nonblank_pixels => $nonblank + 0,
        snapshot        => defined($snap_path) ? $snap_path : undef,
    };
}

sub run_headless {
    my $is_all = ($opt_scene eq 'all') ? 1 : 0;
    my @scenes = $is_all ? qw(fractal boids chart) : ($opt_scene);

    my @results;
    for my $s (@scenes) {
        push @results, _bench_one_scene($s, $is_all);
    }

    if ($opt_json) {
        if ($is_all) {
            print TkMark::Engine::encode_json_pretty({
                stack          => $stack,
                backend        => $results[0]{backend},
                perl_version   => "$^V",
                is_perl5_mt    => TkMark::Engine::json_bool(TkMark::Engine::is_perl5_mt()),
                have_packed_av => TkMark::Engine::json_bool(TkMark::Engine::have_packed_av()),
                results        => \@results,
            });
        }
        else {
            print TkMark::Engine::encode_json_pretty($results[0]);
        }
        return;
    }

    printf "=== TkMark Studio Headless Benchmark ===\n";
    printf "Stack: %s | Backend: %s | Perl: %s (perl5-mt=%d, packed_av=%d, workers=%d)\n\n",
        $stack, $results[0]{backend}, "$^V",
        TkMark::Engine::is_perl5_mt(), TkMark::Engine::have_packed_av(), $workers;

    printf "%-10s | %9s | %8s | %8s | %9s | %9s | %10s\n",
        'Scene', 'FPS', 'p50 ms', 'p95 ms', 'Comp ms', 'Rend ms', 'NonBlank';
    printf "%s\n", ('-' x 78);
    for my $r (@results) {
        printf "%-10s | %9.2f | %8.2f | %8.2f | %9.2f | %9.2f | %10d\n",
            $r->{scene}, $r->{fps}, $r->{p50_ms}, $r->{p95_ms},
            $r->{compute_ms}, $r->{render_ms}, $r->{nonblank_pixels};
    }
}

# =============================================================================
# Interactive Desktop GUI Mode
# =============================================================================
sub run_interactive {
    my $use_cpan = ($stack eq 'stock' && $opt_cpan_tcltk && eval { require Tcl::Tk; 1 }) ? 1 : 0;
    if (!$use_cpan) {
        require Tcl::Tk::MT;
        Tcl::Tk::MT->import(qw(MainWindow MainLoop));
    }

    my $mw = $use_cpan
        ? Tcl::Tk::tkinit()
        : MainWindow->new(-title => "TkMark Studio [$stack / $backend]");
    $mw->configure(-bg => $TkMark::Engine::THEME{bg_dark});

    # Apply dark ttk styling when running via Tcl::MT
    if (!$use_cpan && $mw->can('interp')) {
        eval {
            $mw->interp->Eval(<<'TCL');
catch { ttk::style theme use clam }
ttk::style configure TFrame -background #121826
ttk::style configure TLabel -background #121826 -foreground #e6edf3
ttk::style configure TButton -background #182132 -foreground #e6edf3 -borderwidth 1
ttk::style map TButton -background {active #26334d}
ttk::style configure TNotebook -background #0b0f17 -borderwidth 0
ttk::style configure TNotebook.Tab -background #182132 -foreground #8b949e -padding {14 6}
ttk::style map TNotebook.Tab -background {selected #26334d} -foreground {selected #38bdf8}
TCL
        };
    }

    # Top telemetry bar (fixed-width monospace HUD label + locked pack propagation)
    my $hdr = $mw->Frame(-bg => $TkMark::Engine::THEME{bg_panel}, -pady => 6, -padx => 10)
                 ->pack(-side => 'top', -fill => 'x');
    $hdr->Label(
        -text => sprintf('TkMark Studio  |  Stack: %s  |  Backend: %s  |  Perl %s%s',
            $stack, $backend, "$^V", TkMark::Engine::is_perl5_mt() ? ' (perl5-mt)' : ''),
        -bg   => $TkMark::Engine::THEME{bg_panel},
        -fg   => $TkMark::Engine::THEME{accent_cyan},
        -font => 'Helvetica 12 bold',
    )->pack(-side => 'left');

    my $hud_fmt = 'FPS: %6.1f  |  p50: %6.1fms  |  p95: %6.1fms  |  comp: %6.1fms  |  rend: %6.1fms';
    my $hud_lbl = $hdr->Label(
        -text   => 'FPS:   --.-  |  p50:   --.-ms  |  p95:   --.-ms  |  comp:   --.-ms  |  rend:   --.-ms',
        -width  => 85,
        -anchor => 'e',
        -bg     => $TkMark::Engine::THEME{bg_panel},
        -fg     => $TkMark::Engine::THEME{accent_green},
        -font   => 'TkFixedFont',
    )->pack(-side => 'right');

    # Tabbed notebook for the three benchmark scenes
    my $nb = $mw->ttkNotebook()->pack(-side => 'top', -fill => 'both', -expand => 1, -padx => 6, -pady => 6);

    my $w = $opt_width;
    my $h = $opt_height;
    my $use_accel = ($stack eq 'stock') ? 0 : 1;

    my %scenes;
    my @tab_order = qw(fractal boids chart);
    my %tab_titles = (
        fractal => '  1. Mandelbrot & Julia  ',
        boids   => '  2. N-Body Galaxy Boids  ',
        chart   => '  3. 100k Telemetry Terminal  ',
    );
    my %tab_frames;

    for my $sname (@tab_order) {
        my $tf = $nb->ttkFrame();
        $nb->add($tf->path, '-text', $tab_titles{$sname});
        $tab_frames{$sname} = $tf;

        my $bar = $tf->Frame(-bg => $TkMark::Engine::THEME{bg_card}, -pady => 4, -padx => 8)
                     ->pack(-side => 'top', -fill => 'x');

        my $bg = ($sname eq 'boids') ? '#060911' : '#0b0f17';
        my @c_opts = (-width => $w, -height => $h, -bg => $bg);
        push @c_opts, (-accel => $use_accel) unless $use_cpan;
        push @c_opts, (-backend => $backend) if $use_accel && !$use_cpan;

        my $canvas = $tf->Canvas(@c_opts)->pack(-side => 'top', -fill => 'both', -expand => 1);

        if ($sname eq 'fractal') {
            my $sc = TkMark::SceneFractal->new(
                canvas   => $canvas,
                width    => $w,
                height   => $h,
                stack    => $stack,
                max_iter => $opt_max_iter,
                workers  => $workers,
                headless => 0,
            );
            $sc->bind_events();
            $scenes{fractal} = $sc;

            $bar->ttkButton(-text => 'Reset View', -command => sub { $sc->reset_view() })
                ->pack(-side => 'left', -padx => 4);
            my $az = 0;
            $bar->ttkButton(-text => 'Toggle Auto-Zoom', -command => sub {
                $az = !$az;
                $sc->set_auto_zoom($az);
            })->pack(-side => 'left', -padx => 4);
            for my $pal (qw(inferno viridis plasma ocean)) {
                $bar->ttkButton(-text => ucfirst($pal), -command => sub { $sc->set_palette($pal) })
                    ->pack(-side => 'left', -padx => 3);
            }
            for my $it (64, 128, 256) {
                $bar->ttkButton(-text => "${it} iter", -command => sub { $sc->set_max_iter($it) })
                    ->pack(-side => 'right', -padx => 3);
            }
        }
        elsif ($sname eq 'boids') {
            my $n = $opt_count > 0 ? $opt_count : $opt_boids;
            my $sc = TkMark::SceneBoids->new(
                canvas   => $canvas,
                width    => $w,
                height   => $h,
                stack    => $stack,
                count    => $n,
                headless => 0,
            );
            $sc->bind_events();
            $scenes{boids} = $sc;

            $bar->ttkButton(-text => 'Reset Galaxy', -command => sub { $sc->reset_galaxy() })
                ->pack(-side => 'left', -padx => 4);
            my $tr = 1;
            $bar->ttkButton(-text => 'Toggle Trails', -command => sub {
                $tr = !$tr;
                $sc->set_trails($tr);
            })->pack(-side => 'left', -padx => 4);
            $bar->Label(
                -text => 'Left-click/drag: Gravity Well  |  Right-drag: Pan  |  Wheel: Zoom',
                -bg   => $TkMark::Engine::THEME{bg_card},
                -fg   => $TkMark::Engine::THEME{text_sec},
            )->pack(-side => 'right', -padx => 8);
        }
        elsif ($sname eq 'chart') {
            my $n = $opt_count > 0 ? $opt_count : $opt_chart_points;
            my $sc = TkMark::SceneChart->new(
                canvas   => $canvas,
                width    => $w,
                height   => $h,
                stack    => $stack,
                count    => $n,
                headless => 0,
            );
            $sc->bind_events();
            $scenes{chart} = $sc;

            my $st = 1;
            $bar->ttkButton(-text => 'Pause / Resume Stream', -command => sub {
                $st = !$st;
                $sc->set_streaming($st);
            })->pack(-side => 'left', -padx => 4);
            my $ind = 1;
            $bar->ttkButton(-text => 'Toggle EMA / BB', -command => sub {
                $ind = !$ind;
                $sc->set_show_indicators($ind);
            })->pack(-side => 'left', -padx => 4);
            $bar->ttkButton(-text => 'Zoom In',    -command => sub { $sc->zoom_candles(0.75) })
                ->pack(-side => 'left', -padx => 3);
            $bar->ttkButton(-text => 'Zoom Out',   -command => sub { $sc->zoom_candles(1.33) })
                ->pack(-side => 'left', -padx => 3);
            $bar->ttkButton(-text => 'Reset View', -command => sub { $sc->reset_view() })
                ->pack(-side => 'left', -padx => 3);
        }
    }

    # Select initial requested scene tab
    my $init_tab = ($opt_scene eq 'all') ? 'fractal' : $opt_scene;
    eval { $nb->select($tab_frames{$init_tab}->path) };

    # Lock header bar geometry after initial layout to prevent resize jitter
    if (!$use_cpan && $mw->can('interp')) {
        eval {
            my $interp = $mw->interp;
            $interp->call('update', 'idletasks');
            my $hdr_w = $interp->call('winfo', 'reqwidth',  $hdr->path);
            my $hdr_h = $interp->call('winfo', 'reqheight', $hdr->path);
            $hdr->configure(-width => $hdr_w, -height => $hdr_h);
            $interp->call('pack', 'propagate', $hdr->path, 0);
        };
    }

    # Rolling 30-frame telemetry window
    my (@win_frame, @win_comp, @win_ren);
    my $tick_cb;
    $tick_cb = sub {
        return unless Tcl::Tk::MT::Exists($mw);

        my $cur_path = eval { $nb->select() } || $tab_frames{fractal}->path;
        my $active_name = 'fractal';
        for my $sname (@tab_order) {
            if ($tab_frames{$sname}->path eq $cur_path) {
                $active_name = $sname;
                last;
            }
        }
        my $sc = $scenes{$active_name};
        my $t0 = time();
        my $hud_short = '';
        if (@win_frame) {
            my $avg = TkMark::Engine::mean(\@win_frame);
            my $fps = $avg > 0 ? (1000.0 / $avg) : 0.0;
            $hud_short = sprintf('%.1f FPS | p50 %.1fms | p95 %.1fms',
                $fps,
                TkMark::Engine::percentile(\@win_frame, 50),
                TkMark::Engine::percentile(\@win_frame, 95));
        }

        my ($cm, $rm) = $sc->step_frame($hud_short);
        my $fm = (time() - $t0) * 1000.0;

        push @win_frame, $fm;
        push @win_comp,  $cm;
        push @win_ren,   $rm;
        if (@win_frame > 30) {
            shift @win_frame;
            shift @win_comp;
            shift @win_ren;
        }

        my $avg = TkMark::Engine::mean(\@win_frame);
        my $fps = $avg > 0 ? (1000.0 / $avg) : 0.0;
        $hud_lbl->configure(-text => sprintf(
            $hud_fmt,
            $fps,
            TkMark::Engine::percentile(\@win_frame, 50),
            TkMark::Engine::percentile(\@win_frame, 95),
            TkMark::Engine::mean(\@win_comp),
            TkMark::Engine::mean(\@win_ren),
        ));

        $mw->after(16, $tick_cb);
    };

    $mw->after(50, $tick_cb);
    if ($opt_auto_exit_ms > 0) {
        $mw->after($opt_auto_exit_ms, sub {
            eval { $mw->destroy() };
        });
    }
    if ($use_cpan) {
        Tcl::Tk::MainLoop();
    }
    else {
        Tcl::Tk::MT::MainLoop($mw);
    }
}
