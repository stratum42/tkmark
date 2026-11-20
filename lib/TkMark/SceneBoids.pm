package TkMark::SceneBoids;

use strict;
use warnings;
use Time::HiRes qw(time);
use TkMark::Engine ();
BEGIN { eval { require TkMark::Compute; 1 }; }

our $VERSION = '0.01';

sub new {
    my ($class, %opts) = @_;
    my $w        = int($opts{width}    || 800);
    my $h        = int($opts{height}   || 600);
    my $stack    = $opts{stack}        || 'dropin';
    my $count    = int($opts{count}    || 20_000);
    my $workers  = int($opts{workers}  || 0);
    my $headless = $opts{headless} ? 1 : 0;
    my $trails   = exists $opts{trails} ? ($opts{trails} ? 1 : 0) : 1;

    my $self = bless {
        canvas        => $opts{canvas},
        width         => $w,
        height        => $h,
        stack         => $stack,
        count         => $count,
        workers       => $workers,
        headless      => $headless,
        show_trails   => $trails,
        attr_x        => $w * 0.5,
        attr_y        => $h * 0.5,
        attr_strength => 260.0,
        frame_num     => 0,
        use_packed    => ($stack eq 'mt_gpu' && TkMark::Engine::have_packed_av()) ? 1 : 0,
        has_compute   => ($stack eq 'mt_gpu' && defined(&TkMark::Compute::step_particles_2d)) ? 1 : 0,
        # Physics arrays (persistent packed NV arrays in mt_gpu; plain Perl arrays in stock/dropin)
        px            => undef,
        py            => undef,
        vx            => undef,
        vy            => undef,
        # Persistent preallocated buffers for mt_gpu zero-copy compute + rendering
        inst_buf      => undef,
        trail_buf     => undef,
        trail_step    => ($count > 256 ? int($count / 256) : 1),
        pal_lut       => undef,
        # Canvas item handles
        inst_id       => undef,
        trail_tag     => 'boids_trails',
        oval_ids      => [],
        ring_ids      => [],
        hud_info      => undef,
        hud_perf      => undef,
        pan_drag      => undef,
    }, $class;

    $self->reset_galaxy();
    $self->_init_canvas_items() if defined $self->{canvas};
    return $self;
}

sub name       { 'boids' }
sub item_count { $_[0]{count} }

sub set_trails {
    my ($self, $v) = @_;
    $self->{show_trails} = $v ? 1 : 0;
}

sub set_attractor_strength {
    my ($self, $v) = @_;
    $self->{attr_strength} = $v + 0 if defined $v;
}

sub set_attractor {
    my ($self, $x, $y) = @_;
    $self->{attr_x} = $x + 0;
    $self->{attr_y} = $y + 0;
}

sub reset_galaxy {
    my ($self) = @_;
    my $n = $self->{count};
    my $w = $self->{width};
    my $h = $self->{height};

    srand(1337);
    my (@px, @py, @vx, @vy);
    $#px = $n - 1;
    $#py = $n - 1;
    $#vx = $n - 1;
    $#vy = $n - 1;

    my $c1x = $w * 0.38;
    my $c1y = $h * 0.48;
    my $c2x = $w * 0.62;
    my $c2y = $h * 0.52;
    my $rad = ($w < $h ? $w : $h) * 0.34;

    for (my $i = 0; $i < $n; $i++) {
        my $arm   = $i & 1;
        my $cx    = $arm ? $c2x : $c1x;
        my $cy    = $arm ? $c2y : $c1y;
        my $u     = rand();
        my $r     = (0.06 + 0.94 * ($u * $u)) * $rad;
        my $theta = rand() * 6.283185307179586;

        $px[$i] = $cx + $r * cos($theta);
        $py[$i] = $cy + $r * sin($theta);

        # Tangential orbital velocity for spiral swirl
        my $speed = 1.2 + 2.8 / (0.15 + $r / ($rad || 1.0));
        my $dir   = $arm ? -1.0 : 1.0;
        $vx[$i]   = -$dir * sin($theta) * $speed;
        $vy[$i]   =  $dir * cos($theta) * $speed;
    }

    if ($self->{stack} eq 'mt_gpu') {
        my $trail_step = $n > 256 ? int($n / 256) : 1;
        my $n_trails   = int(($n + $trail_step - 1) / $trail_step);
        my $pal        = TkMark::Engine::get_palette('plasma');
        $self->{trail_step} = $trail_step;

        if ($self->{use_packed}) {
            $self->{px}        = MT::Array::packed('NV', @px);
            $self->{py}        = MT::Array::packed('NV', @py);
            $self->{vx}        = MT::Array::packed('NV', @vx);
            $self->{vy}        = MT::Array::packed('NV', @vy);
            $self->{inst_buf}  = MT::Array::packed('NV', (0.0) x ($n * 4));
            $self->{trail_buf} = MT::Array::packed('NV', (0.0) x ($n_trails * 4));

            my @pal_u8;
            $#pal_u8 = 1023;
            my $pi = 0;
            for my $rgb (@{ $pal->{rgb} }) {
                $pal_u8[$pi++] = $rgb->[0];
                $pal_u8[$pi++] = $rgb->[1];
                $pal_u8[$pi++] = $rgb->[2];
                $pal_u8[$pi++] = 255;
            }
            $self->{pal_lut} = MT::Array::packed('U8', @pal_u8);
        }
        else {
            $self->{px}        = \@px;
            $self->{py}        = \@py;
            $self->{vx}        = \@vx;
            $self->{vy}        = \@vy;
            $self->{inst_buf}  = [ (0.0) x ($n * 4) ];
            $self->{trail_buf} = [ (0.0) x ($n_trails * 4) ];
            $self->{pal_lut}   = join('', @{ $pal->{bytes} });
        }
    }
    else {
        $self->{px} = \@px;
        $self->{py} = \@py;
        $self->{vx} = \@vx;
        $self->{vy} = \@vy;
    }
    $self->{attr_x} = $w * 0.5;
    $self->{attr_y} = $h * 0.5;
}

sub _init_canvas_items {
    my ($self) = @_;
    my $c = $self->{canvas};
    my $w = $self->{width};
    my $h = $self->{height};
    my $n = $self->{count};

    my $pal = TkMark::Engine::get_palette('plasma');
    my $phex = $pal->{hex};

    if ($self->{stack} eq 'mt_gpu') {
        # mt_gpu uses a single createInstances batch + createLinesBatch per frame
        $self->{inst_id} = undef;
    }
    else {
        # stock & dropin: standard Tk Canvas items (createOval)
        my $px = $self->{px};
        my $py = $self->{py};
        my @ids;
        $#ids = $n - 1;

        my $create_all = sub {
            for (my $i = 0; $i < $n; $i++) {
                my $x   = $px->[$i];
                my $y   = $py->[$i];
                my $col = $phex->[ ($i * 7) & 255 ];
                $ids[$i] = $c->createOval($x - 1.5, $y - 1.5, $x + 1.5, $y + 1.5,
                    -fill => $col, -outline => '');
            }
        };

        if ($self->{stack} eq 'dropin' && $c->can('batch')) {
            $c->batch($create_all);
        }
        else {
            $create_all->();
        }
        $self->{oval_ids} = \@ids;
    }

    # Attractor indicator rings
    my ($ax, $ay) = ($self->{attr_x}, $self->{attr_y});
    $self->{ring_ids} = [
        $c->createOval($ax - 18, $ay - 18, $ax + 18, $ay + 18, -outline => '#38bdf8', -width => 1.5),
        $c->createOval($ax - 9,  $ay - 9,  $ax + 9,  $ay + 9,  -outline => '#a855f7', -width => 1.2),
    ];

    # Top-left HUD card
    if ($c->can('is_accelerated') && $c->is_accelerated) {
        $c->createRectangle(10, 10, 340, 86,
            -fill => '#0b0f17', -outline => '#26334d', -width => 1.0);
        $c->createText(20, 18, -anchor => 'nw',
            -text => 'TkMark Studio :: N-Body Galaxy Boids', -fill => '#e6edf3', -font => 'Helvetica 12');
        $self->{hud_info} = $c->createText(20, 38, -anchor => 'nw',
            -text => sprintf('particles=%d  stack=%s', $n, $self->{stack}),
            -fill => '#a8b3c2', -font => 'Courier 11');
        $self->{hud_perf} = $c->createText(20, 58, -anchor => 'nw',
            -text => '', -fill => '#22c55e', -font => 'Courier 11');
    }
}

sub bind_events {
    my ($self) = @_;
    my $c = $self->{canvas};
    return unless defined $c && $c->can('bind') && defined $c->{interp};

    $c->bind('<ButtonPress-1>', [ sub {
        my ($w, $x, $y) = @_;
        $self->set_attractor($x, $y);
    }, Tcl::Tk::MT::Ev('x', 'y') ]);

    $c->bind('<B1-Motion>', [ sub {
        my ($w, $x, $y) = @_;
        $self->set_attractor($x, $y);
    }, Tcl::Tk::MT::Ev('x', 'y') ]);

    $c->bind('<ButtonPress-3>', [ sub {
        my ($w, $x, $y) = @_;
        $self->{pan_drag} = [ $x, $y ];
    }, Tcl::Tk::MT::Ev('x', 'y') ]);

    $c->bind('<B3-Motion>', [ sub {
        my ($w, $x, $y) = @_;
        return unless $self->{pan_drag};
        my ($lx, $ly) = @{ $self->{pan_drag} };
        $c->pan($x - $lx, $y - $ly) if $c->can('pan');
        $self->{pan_drag} = [ $x, $y ];
    }, Tcl::Tk::MT::Ev('x', 'y') ]);

    $c->bind('<MouseWheel>', [ sub {
        my ($w, $delta, $x, $y) = @_;
        my $factor = ($delta > 0) ? 1.1 : 0.909;
        $c->zoom($factor, $x, $y) if $c->can('zoom');
    }, Tcl::Tk::MT::Ev('D', 'x', 'y') ]);
}

# Step physics + render one frame; returns ($compute_ms, $render_ms)
sub step_frame {
    my ($self, $hud_fps_text) = @_;
    my $c     = $self->{canvas};
    my $w     = $self->{width};
    my $h     = $self->{height};
    my $n     = $self->{count};
    my $stack = $self->{stack};

    $self->{frame_num}++;

    # Orbit attractor in headless mode to exercise dynamic particle trajectories
    if ($self->{headless}) {
        my $t = $self->{frame_num} * 0.12;
        $self->{attr_x} = $w * 0.5 + cos($t) * ($w * 0.16);
        $self->{attr_y} = $h * 0.5 + sin($t * 1.3) * ($h * 0.14);
    }

    my $ax   = $self->{attr_x};
    my $ay   = $self->{attr_y};
    my $grav = $self->{attr_strength};
    my $dt   = 0.85;
    my $damp = 0.992;

    my $pal  = TkMark::Engine::get_palette('plasma');
    my $pu32 = $pal->{u32};

    my $t_comp0 = time();

    my $px = $self->{px};
    my $py = $self->{py};
    my $vx = $self->{vx};
    my $vy = $self->{vy};

    my ($inst_ref, $trail_ref);

    if ($stack eq 'mt_gpu') {
        if ($self->{has_compute}) {
            my $do_trails  = $self->{show_trails};
            my $trail_step = $do_trails ? $self->{trail_step} : 0;
            my $trail_arg  = $do_trails ? $self->{trail_buf}  : undef;
            my $n_trails   = TkMark::Compute::step_particles_2d(
                $px, $py, $vx, $vy,
                $self->{inst_buf},
                $self->{pal_lut},
                $n,
                $w + 0.0, $h + 0.0,
                $ax + 0.0, $ay + 0.0,
                $grav + 0.0, $dt, $damp,
                $trail_arg, $trail_step, $self->{workers},
            );
            $inst_ref  = $self->{inst_buf};
            $trail_ref = ($do_trails && $n_trails > 0) ? $self->{trail_buf} : undef;
        }
        else {
            my @inst;
            $#inst = ($n * 4) - 1;
            my @trails;
            my $do_trails  = $self->{show_trails};
            my $trail_step = $n > 256 ? int($n / 256) : 1;

            for (my $i = 0; $i < $n; $i++) {
                my $x  = $px->[$i];
                my $y  = $py->[$i];
                my $dx = $ax - $x;
                my $dy = $ay - $y;
                my $d2 = $dx * $dx + $dy * $dy + 225.0;
                my $f  = $grav / $d2;

                my $nvx = ($vx->[$i] + $dx * $f) * $damp;
                my $nvy = ($vy->[$i] + $dy * $f) * $damp;
                $x += $nvx * $dt;
                $y += $nvy * $dt;

                # Soft wrap at viewport boundaries
                if ($x < 0.0)   { $x += $w; } elsif ($x >= $w) { $x -= $w; }
                if ($y < 0.0)   { $y += $h; } elsif ($y >= $h) { $y -= $h; }

                $px->[$i] = $x;
                $py->[$i] = $y;
                $vx->[$i] = $nvx;
                $vy->[$i] = $nvy;

                my $spd2 = $nvx * $nvx + $nvy * $nvy;
                my $cidx = int($spd2 * 6.5);
                $cidx = 255 if $cidx > 255;
                my $sz = $spd2 > 18.0 ? 3.2 : 2.2;

                my $o = $i * 4;
                $inst[$o]     = $x;
                $inst[$o + 1] = $y;
                $inst[$o + 2] = $pu32->[$cidx] + 0.0;
                $inst[$o + 3] = $sz;

                if ($do_trails && ($i % $trail_step == 0)) {
                    push @trails, $x - $nvx * 2.5, $y - $nvy * 2.5, $x, $y;
                }
            }

            if ($self->{use_packed}) {
                $inst_ref  = MT::Array::packed('NV', @inst);
                $trail_ref = @trails ? MT::Array::packed('NV', @trails) : undef;
            }
            else {
                $inst_ref  = \@inst;
                $trail_ref = @trails ? \@trails : undef;
            }
        }
    }
    else {
        # stock & dropin: boxed Perl physics
        for (my $i = 0; $i < $n; $i++) {
            my $x  = $px->[$i];
            my $y  = $py->[$i];
            my $dx = $ax - $x;
            my $dy = $ay - $y;
            my $d2 = $dx * $dx + $dy * $dy + 225.0;
            my $f  = $grav / $d2;

            my $nvx = ($vx->[$i] + $dx * $f) * $damp;
            my $nvy = ($vy->[$i] + $dy * $f) * $damp;
            $x += $nvx * $dt;
            $y += $nvy * $dt;

            if ($x < 0.0) { $x += $w; } elsif ($x >= $w) { $x -= $w; }
            if ($y < 0.0) { $y += $h; } elsif ($y >= $h) { $y -= $h; }

            $px->[$i] = $x;
            $py->[$i] = $y;
            $vx->[$i] = $nvx;
            $vy->[$i] = $nvy;
        }
    }

    my $compute_ms = (time() - $t_comp0) * 1000.0;

    my $t_ren0 = time();

    # Update gravity attractor rings
    my $rings = $self->{ring_ids};
    if ($rings && @$rings >= 2) {
        $c->coords($rings->[0], $ax - 18, $ay - 18, $ax + 18, $ay + 18);
        $c->coords($rings->[1], $ax - 9,  $ay - 9,  $ax + 9,  $ay + 9);
    }

    if ($stack eq 'mt_gpu') {
        $c->batch(sub {
            if (defined $self->{inst_id}) {
                $c->delete($self->{inst_id});
                $self->{inst_id} = undef;
            }
            if ($self->{trail_ids_active}) {
                $c->delete('boids_trails');
                $self->{trail_ids_active} = 0;
            }
            $self->{inst_id} = $c->createInstances($inst_ref, { -shape => 'circle', -aa => 1 });
            if (defined $trail_ref && @$trail_ref >= 4) {
                $c->createLinesBatch($trail_ref, { -fill => '#38bdf8', -width => 1.0 });
            }
        });
        if (defined $hud_fps_text && defined $self->{hud_perf}) {
            $c->itemconfigure($self->{hud_perf}, -text => $hud_fps_text);
        }
        $c->render();
        # Delete this frame's trail line items after render so they do not accumulate across frames
        if (defined $trail_ref && @$trail_ref >= 4) {
            my $all = $c->find('all');
            # Trail lines are the last N/4 items created after inst_id
            my $n_trails = int(scalar(@$trail_ref) / 4);
            if ($all && @$all > $n_trails + 5) {
                my $start = scalar(@$all) - $n_trails;
                $c->batch(sub {
                    for my $idx ($start .. $#$all) {
                        $c->delete($all->[$idx]);
                    }
                });
            }
        }
    }
    elsif ($stack eq 'dropin') {
        my $ids = $self->{oval_ids};
        $c->batch(sub {
            for (my $i = 0; $i < $n; $i++) {
                my $x = $px->[$i];
                my $y = $py->[$i];
                $c->coords($ids->[$i], $x - 1.5, $y - 1.5, $x + 1.5, $y + 1.5);
            }
        });
        if (defined $hud_fps_text && defined $self->{hud_perf}) {
            $c->itemconfigure($self->{hud_perf}, -text => $hud_fps_text);
        }
        $c->render();
    }
    else {
        # stock: unbatched per-item coords update
        my $ids = $self->{oval_ids};
        for (my $i = 0; $i < $n; $i++) {
            my $x = $px->[$i];
            my $y = $py->[$i];
            $c->coords($ids->[$i], $x - 1.5, $y - 1.5, $x + 1.5, $y + 1.5);
        }
        if ($c->can('is_accelerated') && $c->is_accelerated) {
            if (defined $hud_fps_text && defined $self->{hud_perf}) {
                $c->itemconfigure($self->{hud_perf}, -text => $hud_fps_text);
            }
            $c->render();
        }
        else {
            $c->interp->icall('update', 'idletasks');
        }
    }

    my $render_ms = (time() - $t_ren0) * 1000.0;
    return ($compute_ms, $render_ms);
}

1;

__END__

=head1 NAME

TkMark::SceneBoids - 2D particle attractor workload for TkMark Studio

=head1 DESCRIPTION

Simulates 2D particles orbiting a softened inverse-square attractor. Under
C<stock> and C<dropin>, physics runs in Perl and updates individual canvas
ovals. Under C<mt_gpu>, C<TkMark::Compute::step_particles_2d> updates packed
C<NV> arrays in place and renders particles and optional trails via
C<createInstances> and C<createLinesBatch>.

=head1 LICENSE

This module is available under the same terms as Perl 5 itself.

=cut
