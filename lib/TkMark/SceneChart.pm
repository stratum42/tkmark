package TkMark::SceneChart;

use strict;
use warnings;
use Time::HiRes qw(time);
use TkMark::Engine ();

our $VERSION = '0.01';

sub new {
    my ($class, %opts) = @_;
    my $w        = int($opts{width}  || 800);
    my $h        = int($opts{height} || 600);
    my $stack    = $opts{stack}      || 'dropin';
    my $points   = int($opts{count}  || 100_000);
    my $headless = $opts{headless} ? 1 : 0;

    my $self = bless {
        canvas          => $opts{canvas},
        width           => $w,
        height          => $h,
        stack           => $stack,
        points          => $points,
        headless        => $headless,
        use_packed      => ($stack eq 'mt_gpu' && TkMark::Engine::have_packed_av()) ? 1 : 0,
        streaming       => 1,
        show_indicators => 1,
        visible_candles => 120,
        scroll_offset   => 0,
        crosshair_x     => -1,
        crosshair_y     => -1,
        frame_num       => 0,
        # Raw 100k-point telemetry channels + OHLCV candles
        raw_ch1         => undef,
        raw_ch2         => undef,
        candles         => [],   # [ [o, h, l, c, vol], ... ]
        ema20           => [],
        ema50           => [],
        bb_up           => [],
        bb_dn           => [],
        last_price      => 420.0,
        pan_drag        => undef,
    }, $class;

    $self->_generate_dataset();
    return $self;
}

sub name       { 'chart' }
sub item_count { $_[0]{points} }

sub set_streaming       { $_[0]{streaming}       = $_[1] ? 1 : 0 }
sub set_show_indicators { $_[0]{show_indicators} = $_[1] ? 1 : 0 }

sub zoom_candles {
    my ($self, $factor) = @_;
    my $v = int($self->{visible_candles} * $factor + 0.5);
    $v = 30  if $v < 30;
    $v = 400 if $v > 400;
    $self->{visible_candles} = $v;
}

sub reset_view {
    my ($self) = @_;
    $self->{visible_candles} = 120;
    $self->{scroll_offset}   = 0;
}

sub _generate_dataset {
    my ($self) = @_;
    my $n = $self->{points};
    srand(2026);

    my (@ch1, @ch2);
    $#ch1 = $n - 1;
    $#ch2 = $n - 1;

    my $price = 420.0;
    my $ch2_v = 0.0;

    # Aggregate into ~400 OHLCV candles from the tail of the 100k stream
    my $candle_stride = int($n / 400);
    $candle_stride = 1 if $candle_stride < 1;

    my @candles;
    my ($co, $ch, $cl, $cc, $cvol) = ($price, $price, $price, $price, 0.0);
    my $in_bucket = 0;

    for (my $i = 0; $i < $n; $i++) {
        # Deterministic pseudo-random walk with harmonic drift
        my $r1    = (rand() - 0.498) * 1.45;
        my $wave  = 0.35 * sin($i * 0.0025) + 0.18 * cos($i * 0.011);
        $price   += $r1 + $wave * 0.05;
        $price    = 50.0 if $price < 50.0;

        $ch2_v    = 0.85 * $ch2_v + 0.15 * ($r1 * 14.0 + 3.0 * sin($i * 0.017));
        $ch1[$i]  = $price;
        $ch2[$i]  = $ch2_v;

        if ($in_bucket == 0) {
            $co   = $price;
            $ch   = $price;
            $cl   = $price;
            $cvol = 0.0;
        }
        $ch    = $price if $price > $ch;
        $cl    = $price if $price < $cl;
        $cc    = $price;
        $cvol += abs($r1) * 120.0 + 10.0;
        $in_bucket++;

        if ($in_bucket >= $candle_stride) {
            push @candles, [ $co, $ch, $cl, $cc, $cvol ];
            $in_bucket = 0;
        }
    }
    push @candles, [ $co, $ch, $cl, $cc, $cvol ] if $in_bucket > 0;

    $self->{raw_ch1}    = $self->{use_packed} ? MT::Array::packed('NV', @ch1) : \@ch1;
    $self->{raw_ch2}    = $self->{use_packed} ? MT::Array::packed('NV', @ch2) : \@ch2;
    $self->{candles}    = \@candles;
    $self->{last_price} = $price;

    $self->_recompute_indicators();
}

sub _recompute_indicators {
    my ($self) = @_;
    my $candles = $self->{candles};
    my $nc      = scalar @$candles;
    return unless $nc > 0;

    my (@ema20, @ema50, @bb_up, @bb_dn);
    $#ema20 = $nc - 1;
    $#ema50 = $nc - 1;
    $#bb_up = $nc - 1;
    $#bb_dn = $nc - 1;

    my $k20 = 2.0 / 21.0;
    my $k50 = 2.0 / 51.0;
    my $e20 = $candles->[0][3];
    my $e50 = $candles->[0][3];

    for (my $i = 0; $i < $nc; $i++) {
        my $cl = $candles->[$i][3];
        $e20 = $cl * $k20 + $e20 * (1.0 - $k20);
        $e50 = $cl * $k50 + $e50 * (1.0 - $k50);
        $ema20[$i] = $e20;
        $ema50[$i] = $e50;

        # 20-period rolling stddev for Bollinger Bands
        my $lo  = $i >= 19 ? $i - 19 : 0;
        my $cnt = $i - $lo + 1;
        my $sum = 0.0;
        for (my $j = $lo; $j <= $i; $j++) { $sum += $candles->[$j][3]; }
        my $mean = $sum / $cnt;
        my $var  = 0.0;
        for (my $j = $lo; $j <= $i; $j++) {
            my $d = $candles->[$j][3] - $mean;
            $var += $d * $d;
        }
        my $sd = sqrt($var / $cnt);
        $bb_up[$i] = $mean + 2.0 * $sd;
        $bb_dn[$i] = $mean - 2.0 * $sd;
    }

    $self->{ema20} = \@ema20;
    $self->{ema50} = \@ema50;
    $self->{bb_up} = \@bb_up;
    $self->{bb_dn} = \@bb_dn;
}

sub _append_live_tick {
    my ($self) = @_;
    my $candles = $self->{candles};
    return unless @$candles;

    my $last  = $candles->[-1];
    my $delta = (rand() - 0.495) * 2.4 + 0.4 * sin($self->{frame_num} * 0.15);
    my $open  = $last->[3];
    my $close = $open + $delta;
    $close = 50.0 if $close < 50.0;
    my $hi    = ($open > $close ? $open : $close) + abs(rand() * 1.8);
    my $lo    = ($open < $close ? $open : $close) - abs(rand() * 1.8);
    my $vol   = 400.0 + abs($delta) * 550.0 + rand() * 300.0;

    push @$candles, [ $open, $hi, $lo, $close, $vol ];
    shift @$candles if @$candles > 450;
    $self->{last_price} = $close;
    $self->_recompute_indicators();
}

sub bind_events {
    my ($self) = @_;
    my $c = $self->{canvas};
    return unless defined $c && $c->can('bind') && defined $c->{interp};

    $c->bind('<Motion>', [ sub {
        my ($w, $x, $y) = @_;
        $self->{crosshair_x} = $x;
        $self->{crosshair_y} = $y;
    }, Tcl::Tk::MT::Ev('x', 'y') ]);

    $c->bind('<ButtonPress-1>', [ sub {
        my ($w, $x, $y) = @_;
        $self->{pan_drag} = $x;
    }, Tcl::Tk::MT::Ev('x', 'y') ]);

    $c->bind('<B1-Motion>', [ sub {
        my ($w, $x, $y) = @_;
        return unless defined $self->{pan_drag};
        my $dx = $x - $self->{pan_drag};
        $self->{pan_drag} = $x;
        my $step = int($dx / 5);
        if ($step != 0) {
            $self->{scroll_offset} += $step;
            $self->{scroll_offset} = 0 if $self->{scroll_offset} < 0;
            my $max_off = scalar(@{ $self->{candles} }) - $self->{visible_candles};
            $max_off = 0 if $max_off < 0;
            $self->{scroll_offset} = $max_off if $self->{scroll_offset} > $max_off;
        }
    }, Tcl::Tk::MT::Ev('x', 'y') ]);

    $c->bind('<MouseWheel>', [ sub {
        my ($w, $delta) = @_;
        $self->zoom_candles($delta > 0 ? 0.85 : 1.18);
    }, Tcl::Tk::MT::Ev('D') ]);
}

# Step & render one frame; returns ($compute_ms, $render_ms)
sub step_frame {
    my ($self, $hud_fps_text) = @_;
    my $c     = $self->{canvas};
    my $w     = $self->{width};
    my $h     = $self->{height};
    my $stack = $self->{stack};

    $self->{frame_num}++;

    my $t_comp0 = time();
    $self->_append_live_tick() if $self->{streaming};

    my $candles = $self->{candles};
    my $nc      = scalar @$candles;
    my $vis     = $self->{visible_candles};
    $vis = $nc if $vis > $nc;
    my $end_i   = $nc - 1 - $self->{scroll_offset};
    $end_i = $nc - 1 if $end_i >= $nc;
    $end_i = $vis - 1 if $end_i < $vis - 1;
    my $start_i = $end_i - $vis + 1;
    $start_i = 0 if $start_i < 0;

    # Chart layout regions
    my $pad_l   = 18;
    my $pad_r   = 68;
    my $pad_t   = 44;
    my $pad_b   = 26;
    my $plot_w  = $w - $pad_l - $pad_r;
    my $main_h  = int(($h - $pad_t - $pad_b) * 0.72);
    my $vol_top = $pad_t + $main_h + 12;
    my $vol_h   = ($h - $pad_b) - $vol_top;

    # Find visible price & volume min/max
    my ($p_min, $p_max, $v_max) = (1e18, -1e18, 1.0);
    for (my $i = $start_i; $i <= $end_i; $i++) {
        my $cd = $candles->[$i];
        $p_max = $cd->[1] if $cd->[1] > $p_max;
        $p_min = $cd->[2] if $cd->[2] < $p_min;
        $v_max = $cd->[4] if $cd->[4] > $v_max;
    }
    my $p_span = ($p_max - $p_min) || 1.0;
    $p_min -= $p_span * 0.06;
    $p_max += $p_span * 0.06;
    $p_span = $p_max - $p_min;

    my $dx     = $plot_w / ($vis > 0 ? $vis : 1);
    my $body_w = $dx * 0.65;
    $body_w = 2.0 if $body_w < 2.0;

    # Pre-build geometry arrays
    my (@grid_segs, @wick_bull, @wick_bear, @ema20_segs, @ema50_segs, @bb_segs);
    my (@rect_insts);      # [x, y, w, h, rgba] stride 5 for mt_gpu
    my (@candle_rects);    # [x0, y0, x1, y1, color] for stock/dropin

    # Grid lines (5 horizontal, 6 vertical)
    for my $g (0 .. 4) {
        my $gy = $pad_t + ($g / 4.0) * $main_h;
        push @grid_segs, $pad_l, $gy, $pad_l + $plot_w, $gy;
    }
    for my $g (0 .. 5) {
        my $gx = $pad_l + ($g / 5.0) * $plot_w;
        push @grid_segs, $gx, $pad_t, $gx, $h - $pad_b;
    }

    my $bull_u32     = TkMark::Engine::rgba(34, 197, 94, 240);
    my $bear_u32     = TkMark::Engine::rgba(239, 68, 68, 240);
    my $vol_bull_u32 = TkMark::Engine::rgba(34, 197, 94, 120);
    my $vol_bear_u32 = TkMark::Engine::rgba(239, 68, 68, 120);

    my $ema20 = $self->{ema20};
    my $ema50 = $self->{ema50};
    my $bb_up = $self->{bb_up};
    my $bb_dn = $self->{bb_dn};

    my ($prev_cx, $prev_e20, $prev_e50, $prev_bu, $prev_bd);

    for (my $i = $start_i; $i <= $end_i; $i++) {
        my $slot = $i - $start_i;
        my $cx   = $pad_l + ($slot + 0.5) * $dx;
        my $cd   = $candles->[$i];
        my ($o, $hi, $lo, $cl, $vol) = @$cd;

        my $y_o  = $pad_t + (1.0 - ($o  - $p_min) / $p_span) * $main_h;
        my $y_c  = $pad_t + (1.0 - ($cl - $p_min) / $p_span) * $main_h;
        my $y_hi = $pad_t + (1.0 - ($hi - $p_min) / $p_span) * $main_h;
        my $y_lo = $pad_t + (1.0 - ($lo - $p_min) / $p_span) * $main_h;

        my $bull = ($cl >= $o) ? 1 : 0;
        if ($bull) {
            push @wick_bull, $cx, $y_hi, $cx, $y_lo;
        }
        else {
            push @wick_bear, $cx, $y_hi, $cx, $y_lo;
        }

        my $ry0 = $y_o < $y_c ? $y_o : $y_c;
        my $ry1 = $y_o > $y_c ? $y_o : $y_c;
        $ry1 = $ry0 + 1.5 if ($ry1 - $ry0) < 1.5;

        my $vh  = ($vol / $v_max) * $vol_h;
        my $vy0 = ($vol_top + $vol_h) - $vh;

        if ($stack eq 'mt_gpu') {
            push @rect_insts,
                $cx - $body_w * 0.5, $ry0, $body_w, $ry1 - $ry0, ($bull ? $bull_u32 : $bear_u32),
                $cx - $body_w * 0.5, $vy0, $body_w, $vh,         ($bull ? $vol_bull_u32 : $vol_bear_u32);
        }
        else {
            push @candle_rects,
                [ $cx - $body_w * 0.5, $ry0, $cx + $body_w * 0.5, $ry1, ($bull ? '#22c55e' : '#ef4444') ],
                [ $cx - $body_w * 0.5, $vy0, $cx + $body_w * 0.5, $vol_top + $vol_h, ($bull ? '#14532d' : '#7f1d1d') ];
        }

        if ($self->{show_indicators}) {
            my $ye20 = $pad_t + (1.0 - ($ema20->[$i] - $p_min) / $p_span) * $main_h;
            my $ye50 = $pad_t + (1.0 - ($ema50->[$i] - $p_min) / $p_span) * $main_h;
            my $ybu  = $pad_t + (1.0 - ($bb_up->[$i] - $p_min) / $p_span) * $main_h;
            my $ybd  = $pad_t + (1.0 - ($bb_dn->[$i] - $p_min) / $p_span) * $main_h;
            if (defined $prev_cx) {
                push @ema20_segs, $prev_cx, $prev_e20, $cx, $ye20;
                push @ema50_segs, $prev_cx, $prev_e50, $cx, $ye50;
                push @bb_segs,    $prev_cx, $prev_bu,  $cx, $ybu,
                                  $prev_cx, $prev_bd,  $cx, $ybd;
            }
            ($prev_cx, $prev_e20, $prev_e50, $prev_bu, $prev_bd) = ($cx, $ye20, $ye50, $ybu, $ybd);
        }
    }

    # High-density raw tick trace (same segment count across all stacks)
    my $raw = $self->{raw_ch2};
    my $n_raw = scalar @$raw;
    my $wave_pts = $n_raw > 12_000 ? 12_000 : $n_raw;
    my $wave_step = int($n_raw / $wave_pts);
    $wave_step = 1 if $wave_step < 1;
    my $wave_phase = ($self->{frame_num} * 37) % $n_raw;

    my @wave_segs;
    $#wave_segs = (($wave_pts - 1) * 4) - 1 if $wave_pts > 1;
    my $wi = 0;
    my $wave_mid = $vol_top + $vol_h * 0.5;
    my $wave_amp = $vol_h * 0.018;
    my $wx_step  = $plot_w / ($wave_pts > 1 ? ($wave_pts - 1) : 1);

    my $prev_wx = $pad_l;
    my $prev_wy = $wave_mid - $raw->[$wave_phase] * $wave_amp;
    for (my $k = 1; $k < $wave_pts; $k++) {
        my $idx = ($wave_phase + $k * $wave_step) % $n_raw;
        my $wx  = $pad_l + $k * $wx_step;
        my $wy  = $wave_mid - $raw->[$idx] * $wave_amp;
        $wave_segs[$wi++] = $prev_wx;
        $wave_segs[$wi++] = $prev_wy;
        $wave_segs[$wi++] = $wx;
        $wave_segs[$wi++] = $wy;
        $prev_wx = $wx;
        $prev_wy = $wy;
    }

    my ($grid_ref, $wbull_ref, $wbear_ref, $e20_ref, $e50_ref, $bb_ref, $wave_ref, $rects_ref);
    if ($self->{use_packed}) {
        $grid_ref  = MT::Array::packed('NV', @grid_segs);
        $wbull_ref = MT::Array::packed('NV', @wick_bull);
        $wbear_ref = MT::Array::packed('NV', @wick_bear);
        $e20_ref   = MT::Array::packed('NV', @ema20_segs);
        $e50_ref   = MT::Array::packed('NV', @ema50_segs);
        $bb_ref    = MT::Array::packed('NV', @bb_segs);
        $wave_ref  = MT::Array::packed('NV', @wave_segs);
        $rects_ref = MT::Array::packed('NV', @rect_insts);
    }
    else {
        $grid_ref  = \@grid_segs;
        $wbull_ref = \@wick_bull;
        $wbear_ref = \@wick_bear;
        $e20_ref   = \@ema20_segs;
        $e50_ref   = \@ema50_segs;
        $bb_ref    = \@bb_segs;
        $wave_ref  = \@wave_segs;
        $rects_ref = \@rect_insts;
    }

    my $compute_ms = (time() - $t_comp0) * 1000.0;

    my $t_ren0 = time();
    my $draw_scene = sub {
        $c->delete('all');

        if ($stack eq 'mt_gpu') {
            $c->createLinesBatch($grid_ref,  { -fill => '#1c2536', -width => 1.0 }) if @$grid_ref >= 4;
            $c->createLinesBatch($wave_ref,  { -fill => '#38bdf8', -width => 1.0 }) if @$wave_ref >= 4;
            $c->createLinesBatch($wbull_ref, { -fill => '#22c55e', -width => 1.2 }) if @$wbull_ref >= 4;
            $c->createLinesBatch($wbear_ref, { -fill => '#ef4444', -width => 1.2 }) if @$wbear_ref >= 4;
            $c->createInstances($rects_ref,  { -shape => 'rect', -aa => 1, -stride => 5 }) if @$rects_ref >= 5;
            if ($self->{show_indicators}) {
                $c->createLinesBatch($bb_ref,  { -fill => '#a855f7', -width => 1.0 }) if @$bb_ref >= 4;
                $c->createLinesBatch($e20_ref, { -fill => '#38bdf8', -width => 1.6 }) if @$e20_ref >= 4;
                $c->createLinesBatch($e50_ref, { -fill => '#f59e0b', -width => 1.6 }) if @$e50_ref >= 4;
            }
        }
        else {
            # stock & dropin: standard Tk Canvas createLine / createRectangle calls
            for (my $i = 0; $i + 3 < @$grid_ref; $i += 4) {
                $c->createLine($grid_ref->[$i], $grid_ref->[$i+1], $grid_ref->[$i+2], $grid_ref->[$i+3],
                    -fill => '#1c2536', -width => 1);
            }
            for (my $i = 0; $i + 3 < @$wave_ref; $i += 4) {
                $c->createLine($wave_ref->[$i], $wave_ref->[$i+1], $wave_ref->[$i+2], $wave_ref->[$i+3],
                    -fill => '#38bdf8', -width => 1);
            }
            for (my $i = 0; $i + 3 < @$wbull_ref; $i += 4) {
                $c->createLine($wbull_ref->[$i], $wbull_ref->[$i+1], $wbull_ref->[$i+2], $wbull_ref->[$i+3],
                    -fill => '#22c55e', -width => 1.2);
            }
            for (my $i = 0; $i + 3 < @$wbear_ref; $i += 4) {
                $c->createLine($wbear_ref->[$i], $wbear_ref->[$i+1], $wbear_ref->[$i+2], $wbear_ref->[$i+3],
                    -fill => '#ef4444', -width => 1.2);
            }
            for my $r (@candle_rects) {
                $c->createRectangle($r->[0], $r->[1], $r->[2], $r->[3], -fill => $r->[4], -outline => '');
            }
            if ($self->{show_indicators}) {
                for (my $i = 0; $i + 3 < @$bb_ref; $i += 4) {
                    $c->createLine($bb_ref->[$i], $bb_ref->[$i+1], $bb_ref->[$i+2], $bb_ref->[$i+3],
                        -fill => '#a855f7', -width => 1);
                }
                for (my $i = 0; $i + 3 < @$e20_ref; $i += 4) {
                    $c->createLine($e20_ref->[$i], $e20_ref->[$i+1], $e20_ref->[$i+2], $e20_ref->[$i+3],
                        -fill => '#38bdf8', -width => 1.6);
                }
                for (my $i = 0; $i + 3 < @$e50_ref; $i += 4) {
                    $c->createLine($e50_ref->[$i], $e50_ref->[$i+1], $e50_ref->[$i+2], $e50_ref->[$i+3],
                        -fill => '#f59e0b', -width => 1.6);
                }
            }
        }

        # Price axis labels on right
        for my $g (0 .. 4) {
            my $gy   = $pad_t + ($g / 4.0) * $main_h;
            my $pval = $p_max - ($g / 4.0) * $p_span;
            $c->createText($pad_l + $plot_w + 6, $gy - 6, -anchor => 'nw',
                -text => sprintf('%.2f', $pval), -fill => '#a8b3c2', -font => 'Courier 11');
        }

        # Interactive crosshair
        if ($self->{crosshair_x} >= $pad_l && $self->{crosshair_x} <= $pad_l + $plot_w
            && $self->{crosshair_y} >= $pad_t && $self->{crosshair_y} <= $h - $pad_b)
        {
            my ($mx, $my) = ($self->{crosshair_x}, $self->{crosshair_y});
            $c->createLine($mx, $pad_t, $mx, $h - $pad_b, -fill => '#475569', -width => 1.0);
            $c->createLine($pad_l, $my, $pad_l + $plot_w, $my, -fill => '#475569', -width => 1.0);
        }

        # Top telemetry bar
        my $first_p = $candles->[$start_i][0] || 1.0;
        my $pct     = (($self->{last_price} - $first_p) / $first_p) * 100.0;
        my $pct_col = $pct >= 0 ? '#22c55e' : '#ef4444';

        $c->createText(18, 12, -anchor => 'nw',
            -text => sprintf('TKMT-USD  %.2f  (%+.2f%%)  |  %d pts  |  EMA20 / EMA50 / BB',
                $self->{last_price}, $pct, $self->{points}),
            -fill => $pct_col, -font => 'Helvetica 12');

        if (defined $hud_fps_text) {
            $c->createText($w - 18, 12, -anchor => 'ne',
                -text => $hud_fps_text, -fill => '#38bdf8', -font => 'Courier 11');
        }
    };

    if (($stack eq 'mt_gpu' || $stack eq 'dropin') && $c->can('batch')) {
        $c->batch($draw_scene);
    }
    else {
        $draw_scene->();
    }

    if ($c->can('is_accelerated') && $c->is_accelerated) {
        $c->render();
    }
    else {
        $c->interp->icall('update', 'idletasks');
    }

    my $render_ms = (time() - $t_ren0) * 1000.0;
    return ($compute_ms, $render_ms);
}

1;

__END__

=head1 NAME

TkMark::SceneChart - Candlestick and raw-tick chart workload for TkMark Studio

=head1 DESCRIPTION

Renders OHLCV candlesticks, volume bars, EMA20/EMA50/Bollinger overlays, and a
12k-segment raw-tick trace. Indicator math and waveform sampling run in Perl
across all stacks; C<mt_gpu> packs coordinates into C<NV> arrays and submits
batched draw calls via C<createLinesBatch> and C<createInstances>.

=head1 LICENSE

This module is available under the same terms as Perl 5 itself.

=cut
