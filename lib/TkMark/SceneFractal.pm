package TkMark::SceneFractal;

use strict;
use warnings;
use Time::HiRes qw(time);
use TkMark::Engine ();
BEGIN { eval { require TkMark::Compute; 1 }; }

our $VERSION = '0.01';

my $INV_LN2 = 1.0 / log(2.0);
my $INTERIOR_BYTES = pack('CCCC', 6, 8, 16, 255);
my $INTERIOR_HEX   = '#060810';

# Named worker sub for MT::Pool parallel tile rendering (must be package-level named sub).
# Spec format: "y0,y1,w,h,cx,cy,scale,max_iter,palette"
sub _worker_render_strip {
    my ($spec) = @_;
    my ($y0, $y1, $w, $h, $cx, $cy, $scale, $max_iter, $pal_name) = split /,/, $spec;

    my $pal      = TkMark::Engine::get_palette($pal_name);
    my $pbytes   = $pal->{bytes};
    my $half_w   = $w * 0.5;
    my $half_h   = $h * 0.5;
    my $step     = $scale / ($w > 0 ? $w : 1);
    my $x_origin = $cx - $half_w * $step;
    my $y_origin = $cy - $half_h * $step;

    my @rows;
    $#rows = ($y1 - $y0) - 1 if $y1 > $y0;
    my $ri = 0;

    for (my $py = $y0; $py < $y1; $py++) {
        my $ci = $y_origin + $py * $step;
        my $row = '';
        for (my $px = 0; $px < $w; $px++) {
            my $cr = $x_origin + $px * $step;

            # Cardioid / period-2 bulb early reject
            my $q = ($cr - 0.25) * ($cr - 0.25) + $ci * $ci;
            if ($q * ($q + ($cr - 0.25)) <= 0.25 * $ci * $ci
                || ($cr + 1.0) * ($cr + 1.0) + $ci * $ci <= 0.0625)
            {
                $row .= $INTERIOR_BYTES;
                next;
            }

            my ($zr, $zi, $zr2, $zi2) = (0.0, 0.0, 0.0, 0.0);
            my $iter = 0;
            while ($iter < $max_iter && ($zr2 + $zi2) <= 4.0) {
                $zi  = 2.0 * $zr * $zi + $ci;
                $zr  = $zr2 - $zi2 + $cr;
                $zr2 = $zr * $zr;
                $zi2 = $zi * $zi;
                $iter++;
            }

            if ($iter >= $max_iter) {
                $row .= $INTERIOR_BYTES;
            }
            else {
                my $mag2 = $zr2 + $zi2;
                my $nu   = $mag2 > 1.0 ? (log(log($mag2) * 0.5) * $INV_LN2) : 0.0;
                my $smooth = $iter + 1.0 - $nu;
                my $idx = int($smooth * 5.0) & 255;
                $row .= $pbytes->[$idx];
            }
        }
        $rows[$ri++] = $row;
    }

    return join('', @rows);
}

# Render small Julia set inset (returns raw RGBA8888 byte string)
sub _render_julia_rgba {
    my ($w, $h, $cre, $cim, $max_iter, $pal_name) = @_;
    my $pal    = TkMark::Engine::get_palette($pal_name);
    my $pbytes = $pal->{bytes};
    my $j_iter = $max_iter > 64 ? 64 : $max_iter;
    my $step_x = 3.2 / $w;
    my $step_y = 2.4 / $h;

    my @rows;
    for (my $py = 0; $py < $h; $py++) {
        my $y0  = -1.2 + $py * $step_y;
        my $row = '';
        for (my $px = 0; $px < $w; $px++) {
            my $zr  = -1.6 + $px * $step_x;
            my $zi  = $y0;
            my $zr2 = $zr * $zr;
            my $zi2 = $zi * $zi;
            my $iter = 0;
            while ($iter < $j_iter && ($zr2 + $zi2) <= 4.0) {
                $zi  = 2.0 * $zr * $zi + $cim;
                $zr  = $zr2 - $zi2 + $cre;
                $zr2 = $zr * $zr;
                $zi2 = $zi * $zi;
                $iter++;
            }
            if ($iter >= $j_iter) {
                $row .= $INTERIOR_BYTES;
            }
            else {
                my $idx = int($iter * 7) & 255;
                $row .= $pbytes->[$idx];
            }
        }
        push @rows, $row;
    }
    return join('', @rows);
}

# Stock Perl classic Tk Photo string-put renderer (builds {#rrggbb ...} row list)
sub _render_mandelbrot_stock_rows {
    my ($w, $h, $cx, $cy, $scale, $max_iter, $pal_name) = @_;
    my $pal    = TkMark::Engine::get_palette($pal_name);
    my $phex   = $pal->{hex};
    my $half_w = $w * 0.5;
    my $half_h = $h * 0.5;
    my $step   = $scale / ($w > 0 ? $w : 1);
    my $x_orig = $cx - $half_w * $step;
    my $y_orig = $cy - $half_h * $step;

    my @row_strs;
    $#row_strs = $h - 1;
    for (my $py = 0; $py < $h; $py++) {
        my $ci = $y_orig + $py * $step;
        my @cols;
        $#cols = $w - 1;
        for (my $px = 0; $px < $w; $px++) {
            my $cr = $x_orig + $px * $step;
            my $q  = ($cr - 0.25) * ($cr - 0.25) + $ci * $ci;
            if ($q * ($q + ($cr - 0.25)) <= 0.25 * $ci * $ci
                || ($cr + 1.0) * ($cr + 1.0) + $ci * $ci <= 0.0625)
            {
                $cols[$px] = $INTERIOR_HEX;
                next;
            }
            my ($zr, $zi, $zr2, $zi2) = (0.0, 0.0, 0.0, 0.0);
            my $iter = 0;
            while ($iter < $max_iter && ($zr2 + $zi2) <= 4.0) {
                $zi  = 2.0 * $zr * $zi + $ci;
                $zr  = $zr2 - $zi2 + $cr;
                $zr2 = $zr * $zr;
                $zi2 = $zi * $zi;
                $iter++;
            }
            if ($iter >= $max_iter) {
                $cols[$px] = $INTERIOR_HEX;
            }
            else {
                my $mag2   = $zr2 + $zi2;
                my $nu     = $mag2 > 1.0 ? (log(log($mag2) * 0.5) * $INV_LN2) : 0.0;
                my $smooth = $iter + 1.0 - $nu;
                my $idx    = int($smooth * 5.0) & 255;
                $cols[$px] = $phex->[$idx];
            }
        }
        $row_strs[$py] = '{' . join(' ', @cols) . '}';
    }
    return \@row_strs;
}

# Convert classic Tk Photo {#rrggbb ...} rows to RGBA8888 bytes for headless software surface
sub _stock_rows_to_rgba {
    my ($row_strs) = @_;
    my @out;
    for my $r (@$row_strs) {
        my $s = $r;
        $s =~ s/\A\{//;
        $s =~ s/\}\z//;
        my $row_bytes = '';
        for my $hex (split / /, $s) {
            my $rv = hex(substr($hex, 1, 2));
            my $gv = hex(substr($hex, 3, 2));
            my $bv = hex(substr($hex, 5, 2));
            $row_bytes .= pack('CCCC', $rv, $gv, $bv, 255);
        }
        push @out, $row_bytes;
    }
    return join('', @out);
}

sub new {
    my ($class, %opts) = @_;
    my $w        = int($opts{width}    || 640);
    my $h        = int($opts{height}   || 480);
    my $stack    = $opts{stack}        || 'dropin';
    my $max_iter = int($opts{max_iter} || 128);
    my $palette  = $opts{palette}      || 'inferno';
    my $workers  = int($opts{workers}  || 0);
    my $headless = $opts{headless} ? 1 : 0;

    my $self = bless {
        canvas       => $opts{canvas},
        width        => $w,
        height       => $h,
        stack        => $stack,
        max_iter     => $max_iter,
        palette      => $palette,
        workers      => $workers,
        headless     => $headless,
        use_packed   => ($stack eq 'mt_gpu' && TkMark::Engine::have_packed_av()) ? 1 : 0,
        has_compute  => ($stack eq 'mt_gpu' && defined(&TkMark::Compute::render_fractal_rgba8)) ? 1 : 0,
        # Persistent preallocated U8 buffers for mt_gpu zero-copy compute + Photo upload
        rgba_buf     => undef,
        julia_buf    => undef,
        pal_lut      => undef,
        pal_lut_name => '',
        # Default viewport centered on Seahorse Valley
        cx           => -0.743643887037151,
        cy           =>  0.131825904205330,
        scale        =>  2.8,
        auto_zoom    => $headless ? 1 : 0,
        julia_re     => -0.74543,
        julia_im     =>  0.11301,
        julia_w      => 128,
        julia_h      => 96,
        frame_num    => 0,
        dirty        => 1,
        photo        => undef,
        julia_photo  => undef,
        tk_photo     => undef,
        img_id       => undef,
        julia_id     => undef,
        hud_ids      => [],
        drag_start   => undef,
        drag_rect    => undef,
    }, $class;

    $self->_ensure_mt_buffers() if $self->{stack} eq 'mt_gpu';
    $self->_init_canvas_items() if defined $self->{canvas};
    return $self;
}

sub _ensure_mt_buffers {
    my ($self) = @_;
    return unless $self->{stack} eq 'mt_gpu';

    my $use_packed = $self->{use_packed};
    if (!defined $self->{rgba_buf}) {
        my $len = $self->{width} * $self->{height} * 4;
        $self->{rgba_buf} = $use_packed
            ? MT::Array::packed('U8', (0) x $len)
            : ("\x00" x $len);
    }
    if (!defined $self->{julia_buf}) {
        my $jlen = $self->{julia_w} * $self->{julia_h} * 4;
        $self->{julia_buf} = $use_packed
            ? MT::Array::packed('U8', (0) x $jlen)
            : ("\x00" x $jlen);
    }
    if (!defined $self->{pal_lut} || $self->{pal_lut_name} ne $self->{palette}) {
        my $pal = TkMark::Engine::get_palette($self->{palette});
        if ($use_packed) {
            my @u8;
            $#u8 = 1023;
            my $idx = 0;
            for my $rgb (@{ $pal->{rgb} }) {
                $u8[$idx++] = $rgb->[0];
                $u8[$idx++] = $rgb->[1];
                $u8[$idx++] = $rgb->[2];
                $u8[$idx++] = 255;
            }
            $self->{pal_lut} = MT::Array::packed('U8', @u8);
        }
        else {
            $self->{pal_lut} = join('', @{ $pal->{bytes} });
        }
        $self->{pal_lut_name} = $self->{palette};
    }
}

sub name       { 'fractal' }
sub item_count { $_[0]{width} * $_[0]{height} }

sub reset_view {
    my ($self) = @_;
    $self->{cx}    = -0.743643887037151;
    $self->{cy}    =  0.131825904205330;
    $self->{scale} =  2.8;
    $self->{dirty} =  1;
}

sub set_max_iter {
    my ($self, $v) = @_;
    $self->{max_iter} = int($v) if defined $v && $v >= 16;
    $self->{dirty}    = 1;
}

sub set_palette {
    my ($self, $p) = @_;
    $self->{palette} = $p if defined $p && length $p;
    $self->{dirty}   = 1;
}

sub set_auto_zoom {
    my ($self, $v) = @_;
    $self->{auto_zoom} = $v ? 1 : 0;
}

sub _init_canvas_items {
    my ($self) = @_;
    my $c = $self->{canvas};
    my $w = $self->{width};
    my $h = $self->{height};

    if ($c->can('is_accelerated') && $c->is_accelerated) {
        require Tcl::Tk::MT::Photo;
        $self->{photo} = Tcl::Tk::MT::Photo->new(
            surface => $c->surface,
            width   => $w,
            height  => $h,
        );
        $self->{julia_photo} = Tcl::Tk::MT::Photo->new(
            surface => $c->surface,
            width   => $self->{julia_w},
            height  => $self->{julia_h},
        );
        # Pre-seed with black pixels so texture IDs exist
        my $blank = "\x06\x08\x10\xff" x ($w * $h);
        $self->{photo}->put_rgba_packed($blank, $w, $h);
        my $jblank = "\x06\x08\x10\xff" x ($self->{julia_w} * $self->{julia_h});
        $self->{julia_photo}->put_rgba_packed($jblank, $self->{julia_w}, $self->{julia_h});

        $self->{img_id} = $c->createImage(0, 0, -anchor => 'nw', -image => $self->{photo});

        # Julia inset border + image in bottom-right
        my $jx = $w - $self->{julia_w} - 14;
        my $jy = $h - $self->{julia_h} - 14;
        $c->createRectangle($jx - 3, $jy - 20, $jx + $self->{julia_w} + 3, $jy + $self->{julia_h} + 3,
            -fill => '#0b0f17', -outline => '#38bdf8', -width => 1.5);
        $self->{julia_id} = $c->createImage($jx, $jy, -anchor => 'nw', -image => $self->{julia_photo});
        $self->{julia_lbl} = $c->createText($jx + 4, $jy - 16, -anchor => 'nw',
            -text => 'Julia Preview', -fill => '#38bdf8', -font => 'Helvetica 11');

        # Top-left HUD card
        $c->createRectangle(10, 10, 340, 86,
            -fill => '#0b0f17', -outline => '#26334d', -width => 1.0);
        $self->{hud_title} = $c->createText(20, 18, -anchor => 'nw',
            -text => 'TkMark Studio :: Mandelbrot & Julia', -fill => '#e6edf3', -font => 'Helvetica 12');
        $self->{hud_info} = $c->createText(20, 38, -anchor => 'nw',
            -text => '', -fill => '#a8b3c2', -font => 'Courier 11');
        $self->{hud_perf} = $c->createText(20, 58, -anchor => 'nw',
            -text => '', -fill => '#22c55e', -font => 'Courier 11');
    }
    else {
        # Native Tk Canvas (interactive stock mode)
        my $interp = $c->interp;
        my $pname  = 'tkmark_fractal_photo_' . int(rand(100000));
        $interp->icall('image', 'create', 'photo', $pname, '-width', $w, '-height', $h);
        $self->{tk_photo} = $pname;
        $self->{img_id}   = $c->createImage(0, 0, -anchor => 'nw', -image => $pname);
        $self->{hud_info} = $c->createText(14, 14, -anchor => 'nw',
            -text => 'TkMark Studio :: Mandelbrot (stock)', -fill => '#e6edf3');
    }
}

sub bind_events {
    my ($self) = @_;
    my $c = $self->{canvas};
    return unless defined $c && $c->can('bind') && defined $c->{interp};

    $c->bind('<ButtonPress-1>', [ sub {
        my ($w, $x, $y) = @_;
        $self->{drag_start} = [ $x, $y ];
        if ($self->{drag_rect}) {
            eval { $c->delete($self->{drag_rect}) };
            $self->{drag_rect} = undef;
        }
    }, Tcl::Tk::MT::Ev('x', 'y') ]);

    $c->bind('<B1-Motion>', [ sub {
        my ($w, $x, $y) = @_;
        return unless $self->{drag_start};
        my ($x0, $y0) = @{ $self->{drag_start} };
        if ($self->{drag_rect}) {
            $c->coords($self->{drag_rect}, $x0, $y0, $x, $y);
        }
        else {
            $self->{drag_rect} = $c->createRectangle($x0, $y0, $x, $y,
                -outline => '#38bdf8', -width => 1.5);
        }
    }, Tcl::Tk::MT::Ev('x', 'y') ]);

    $c->bind('<ButtonRelease-1>', [ sub {
        my ($w, $x, $y) = @_;
        return unless $self->{drag_start};
        my ($x0, $y0) = @{ delete $self->{drag_start} };
        if ($self->{drag_rect}) {
            eval { $c->delete($self->{drag_rect}) };
            $self->{drag_rect} = undef;
        }
        my $dx = abs($x - $x0);
        my $dy = abs($y - $y0);
        if ($dx > 8 && $dy > 8) {
            my $step = $self->{scale} / $self->{width};
            my $mx   = ($x0 + $x) * 0.5;
            my $my   = ($y0 + $y) * 0.5;
            $self->{cx}    += ($mx - $self->{width}  * 0.5) * $step;
            $self->{cy}    += ($my - $self->{height} * 0.5) * $step;
            $self->{scale} *= ($dx / $self->{width});
            $self->{dirty}  = 1;
        }
    }, Tcl::Tk::MT::Ev('x', 'y') ]);

    $c->bind('<Motion>', [ sub {
        my ($w, $x, $y) = @_;
        my $step = $self->{scale} / $self->{width};
        $self->{julia_re} = $self->{cx} + ($x - $self->{width}  * 0.5) * $step;
        $self->{julia_im} = $self->{cy} + ($y - $self->{height} * 0.5) * $step;
    }, Tcl::Tk::MT::Ev('x', 'y') ]);

    $c->bind('<MouseWheel>', [ sub {
        my ($w, $delta, $x, $y) = @_;
        my $factor = ($delta > 0) ? 0.8 : 1.25;
        $self->_zoom_at($x, $y, $factor);
    }, Tcl::Tk::MT::Ev('D', 'x', 'y') ]);

    $c->bind('<Double-Button-1>', sub { $self->reset_view() });
    $c->bind('<Button-3>',        sub { $self->reset_view() });
}

sub _zoom_at {
    my ($self, $x, $y, $factor) = @_;
    my $step = $self->{scale} / $self->{width};
    my $re   = $self->{cx} + ($x - $self->{width}  * 0.5) * $step;
    my $im   = $self->{cy} + ($y - $self->{height} * 0.5) * $step;
    $self->{scale} *= $factor;
    my $nstep = $self->{scale} / $self->{width};
    $self->{cx} = $re - ($x - $self->{width}  * 0.5) * $nstep;
    $self->{cy} = $im - ($y - $self->{height} * 0.5) * $nstep;
    $self->{dirty} = 1;
}

# Step & render one frame; returns ($compute_ms, $render_ms)
sub step_frame {
    my ($self, $hud_fps_text) = @_;
    my $c     = $self->{canvas};
    my $w     = $self->{width};
    my $h     = $self->{height};
    my $stack = $self->{stack};

    $self->{frame_num}++;
    if ($self->{auto_zoom}) {
        $self->{scale} *= 0.94;
        $self->{scale}  = 2.8 if $self->{scale} < 1e-6;
        my $ang = $self->{frame_num} * 0.08;
        $self->{julia_re} = -0.745 + 0.06 * cos($ang);
        $self->{julia_im} =  0.113 + 0.06 * sin($ang);
        $self->{dirty}    = 1;
    }

    my $t_comp0 = time();
    my ($rgba_main, $stock_rows, $rgba_julia);

    if ($stack eq 'mt_gpu') {
        if ($self->{has_compute}) {
            $self->_ensure_mt_buffers();
            TkMark::Compute::render_fractal_rgba8(
                $self->{rgba_buf},
                $self->{pal_lut},
                $w, $h,
                $self->{cx} + 0.0,
                $self->{cy} + 0.0,
                $self->{scale} + 0.0,
                $self->{max_iter},
                0, 0.0, 0.0,
                $self->{workers},
            );
            my $j_iter = $self->{max_iter} > 64 ? 64 : $self->{max_iter};
            TkMark::Compute::render_fractal_rgba8(
                $self->{julia_buf},
                $self->{pal_lut},
                $self->{julia_w}, $self->{julia_h},
                0.0, 0.0,
                3.2,
                $j_iter,
                1,
                $self->{julia_re} + 0.0,
                $self->{julia_im} + 0.0,
                $self->{workers},
            );
            $rgba_main  = $self->{rgba_buf};
            $rgba_julia = $self->{julia_buf};
        }
        else {
            my $pool = TkMark::Engine::get_pool($self->{workers});
            if ($pool) {
                my $n_strips = (TkMark::Engine::pool_workers() || 4) * 2;
                $n_strips = $h if $n_strips > $h;
                my @specs;
                for my $s (0 .. $n_strips - 1) {
                    my $y0 = int(($s * $h) / $n_strips);
                    my $y1 = int((($s + 1) * $h) / $n_strips);
                    push @specs, join(',', $y0, $y1, $w, $h,
                        $self->{cx}, $self->{cy}, $self->{scale},
                        $self->{max_iter}, $self->{palette});
                }
                my @strips = $pool->map(\&_worker_render_strip, @specs);
                $rgba_main = join('', @strips);
            }
            else {
                my $spec = join(',', 0, $h, $w, $h,
                    $self->{cx}, $self->{cy}, $self->{scale},
                    $self->{max_iter}, $self->{palette});
                $rgba_main = _worker_render_strip($spec);
            }
            $rgba_julia = _render_julia_rgba(
                $self->{julia_w}, $self->{julia_h},
                $self->{julia_re}, $self->{julia_im},
                $self->{max_iter}, $self->{palette}
            );
        }
    }
    elsif ($stack eq 'dropin') {
        my $spec = join(',', 0, $h, $w, $h,
            $self->{cx}, $self->{cy}, $self->{scale},
            $self->{max_iter}, $self->{palette});
        $rgba_main  = _worker_render_strip($spec);
        $rgba_julia = _render_julia_rgba(
            $self->{julia_w}, $self->{julia_h},
            $self->{julia_re}, $self->{julia_im},
            $self->{max_iter}, $self->{palette}
        );
    }
    else {
        # stock: classic Perl loop + Tk Photo {#rrggbb ...} row-string formatting
        $stock_rows = _render_mandelbrot_stock_rows(
            $w, $h, $self->{cx}, $self->{cy}, $self->{scale},
            $self->{max_iter}, $self->{palette}
        );
        if ($c->can('is_accelerated') && $c->is_accelerated) {
            # Headless software canvas path: decode the classic string rows to RGBA
            $rgba_main  = _stock_rows_to_rgba($stock_rows);
            $rgba_julia = _render_julia_rgba(
                $self->{julia_w}, $self->{julia_h},
                $self->{julia_re}, $self->{julia_im},
                $self->{max_iter}, $self->{palette}
            );
        }
    }
    my $compute_ms = (time() - $t_comp0) * 1000.0;

    my $t_ren0 = time();
    if ($c->can('is_accelerated') && $c->is_accelerated) {
        $self->{photo}->put_rgba_packed($rgba_main, $w, $h);
        $self->{julia_photo}->put_rgba_packed($rgba_julia, $self->{julia_w}, $self->{julia_h})
            if defined $rgba_julia;

        my $zoom = 2.8 / ($self->{scale} || 1e-12);
        $c->itemconfigure($self->{hud_info},
            -text => sprintf('c=(%.4f, %.4f)  zoom=%.1fx  iter=%d',
                $self->{cx}, $self->{cy}, $zoom, $self->{max_iter}));
        if (defined $hud_fps_text) {
            $c->itemconfigure($self->{hud_perf}, -text => $hud_fps_text);
        }
        $c->itemconfigure($self->{julia_lbl},
            -text => sprintf('Julia (%.2f, %.2fi)', $self->{julia_re}, $self->{julia_im}));
        $c->render();
    }
    else {
        # Native Tk Photo string put
        my $interp = $c->interp;
        $interp->icall($self->{tk_photo}, 'put', '{' . join(' ', @$stock_rows) . '}');
        $interp->icall('update', 'idletasks');
    }
    my $render_ms = (time() - $t_ren0) * 1000.0;

    $self->{dirty} = 0;
    return ($compute_ms, $render_ms);
}

1;

__END__

=head1 NAME

TkMark::SceneFractal - Mandelbrot and Julia workload for TkMark Studio

=head1 DESCRIPTION

Renders the Mandelbrot set with smooth escape-time coloring and a Julia preview
inset. Under C<stock> and C<dropin>, escape loops run in Perl. Under C<mt_gpu>,
C<TkMark::Compute::render_fractal_rgba8> renders into a packed C<U8> buffer
that is uploaded directly via C<Photo::put_rgba_packed>.

=head1 LICENSE

This module is available under the same terms as Perl 5 itself.

=cut
