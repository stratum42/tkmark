use strict;
use warnings;
use Test::More;
use Digest::SHA qw(sha256_hex);
use File::Spec;
use FindBin;

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

my $has_gfx     = eval { require Tcl::Tk::MT::Gfx; 1 } ? 1 : 0;
my $have_packed = TkMark::Compute::have_packed_av();
my $has_mt_arr  = ($have_packed && eval { require MT::Array; 1 }) ? 1 : 0;

ok(defined(&TkMark::Compute::step_particles_2d),    'step_particles_2d XSUB exists');
ok(defined(&TkMark::Compute::render_fractal_rgba8), 'render_fractal_rgba8 XSUB exists');

sub rgba_u32 {
    my ($r, $g, $b, $a) = @_;
    return ($r & 0xFF) | (($g & 0xFF) << 8) | (($b & 0xFF) << 16) | (($a & 0xFF) << 24);
}

# Build a deterministic 256-color RGBA palette (both U8 flat 1024-byte and u32 256-entry)
my @pal_u8;
my @pal_u32;
for my $i (0 .. 255) {
    my $r = ($i * 3) & 255;
    my $g = (255 - $i) & 255;
    my $b = (($i * 5) + 40) & 255;
    my $a = 255;
    push @pal_u8, $r, $g, $b, $a;
    push @pal_u32, rgba_u32($r, $g, $b, $a);
}
my $pal_str    = pack('C*', @pal_u8);
my $pal_u8_ref = $has_mt_arr ? MT::Array::packed('U8', @pal_u8) : \@pal_u8;

sub make_nv_buf {
    my (@vals) = @_;
    return $has_mt_arr ? MT::Array::packed('NV', @vals) : \@vals;
}

sub make_u8_buf {
    my ($len) = @_;
    return $has_mt_arr ? MT::Array::packed('U8', (0) x $len) : [ (0) x $len ];
}

sub hash_doubles {
    my ($aref) = @_;
    return sha256_hex(pack('d<*', @$aref));
}

sub hash_u8_aref {
    my ($aref) = @_;
    return sha256_hex(pack('C*', @$aref));
}

# =========================================================================
# 1. Kernel 1: step_particles_2d correctness vs pure-Perl reference
# =========================================================================
{
    my $n = 65; # odd count to exercise SIMD pairs + scalar tail
    my ($w, $h) = (800.0, 600.0);
    my ($ax, $ay, $grav, $dt, $damp) = (412.5, 295.25, 260.0, 0.85, 0.992);
    my $trail_step = 4;
    my $n_trails_exp = int(($n + $trail_step - 1) / $trail_step);

    srand(42);
    my (@x0, @y0, @vx0, @vy0);
    for my $i (0 .. $n - 1) {
        push @x0,  rand($w);
        push @y0,  rand($h);
        push @vx0, (rand(10.0) - 5.0);
        push @vy0, (rand(10.0) - 5.0);
    }

    # Pure-Perl reference step
    my @rx  = @x0;
    my @ry  = @y0;
    my @rvx = @vx0;
    my @rvy = @vy0;
    my @rinst   = (0.0) x ($n * 4);
    my @rtrails = (0.0) x ($n_trails_exp * 4);
    for my $i (0 .. $n - 1) {
        my $dx  = $ax - $rx[$i];
        my $dy  = $ay - $ry[$i];
        my $d2  = $dx * $dx + $dy * $dy + 225.0;
        my $f   = $grav / $d2;
        my $nvx = ($rvx[$i] + $dx * $f) * $damp;
        my $nvy = ($rvy[$i] + $dy * $f) * $damp;
        my $nx  = $rx[$i] + $nvx * $dt;
        my $ny  = $ry[$i] + $nvy * $dt;
        if ($nx < 0.0) { $nx += $w; } elsif ($nx >= $w) { $nx -= $w; }
        if ($ny < 0.0) { $ny += $h; } elsif ($ny >= $h) { $ny -= $h; }
        $rx[$i]  = $nx;
        $ry[$i]  = $ny;
        $rvx[$i] = $nvx;
        $rvy[$i] = $nvy;

        my $spd2 = $nvx * $nvx + $nvy * $nvy;
        my $cidx = int($spd2 * 6.5);
        $cidx = 255 if $cidx > 255;
        my $sz = $spd2 > 18.0 ? 3.2 : 2.2;
        $rinst[$i * 4 + 0] = $nx;
        $rinst[$i * 4 + 1] = $ny;
        $rinst[$i * 4 + 2] = $pal_u32[$cidx] + 0.0;
        $rinst[$i * 4 + 3] = $sz;

        if ($i % $trail_step == 0) {
            my $ti = int($i / $trail_step);
            $rtrails[$ti * 4 + 0] = $nx - $nvx * 2.5;
            $rtrails[$ti * 4 + 1] = $ny - $nvy * 2.5;
            $rtrails[$ti * 4 + 2] = $nx;
            $rtrails[$ti * 4 + 3] = $ny;
        }
    }

    my $px     = make_nv_buf(@x0);
    my $py     = make_nv_buf(@y0);
    my $vx     = make_nv_buf(@vx0);
    my $vy     = make_nv_buf(@vy0);
    my $inst   = make_nv_buf((0.0) x ($n * 4));
    my $trails = make_nv_buf((0.0) x ($n_trails_exp * 4));

    if ($has_mt_arr) {
        is(TkMark::Compute::av_packed_type($px),   2, 'px is AV_PACKED_NV');
        is(TkMark::Compute::av_packed_type($inst), 2, 'inst is AV_PACKED_NV');
    }

    my $written = TkMark::Compute::step_particles_2d(
        $px, $py, $vx, $vy, $inst, $pal_u8_ref,
        $n, $w, $h, $ax, $ay, $grav, $dt, $damp,
        $trails, $trail_step, 4
    );
    is($written, $n_trails_exp, 'step_particles_2d returned expected trail segment count');

    my $max_err = 0.0;
    for my $i (0 .. $n - 1) {
        for my $d (
            abs($px->[$i] - $rx[$i]),
            abs($py->[$i] - $ry[$i]),
            abs($vx->[$i] - $rvx[$i]),
            abs($vy->[$i] - $rvy[$i]),
        ) {
            $max_err = $d if $d > $max_err;
        }
    }
    cmp_ok($max_err, '<', 1e-12, "particle physics matches Perl reference (max_err=$max_err)");

    my $inst_err = 0.0;
    for my $i (0 .. ($n * 4) - 1) {
        my $d = abs($inst->[$i] - $rinst[$i]);
        $inst_err = $d if $d > $inst_err;
    }
    cmp_ok($inst_err, '<', 1e-12, "fused instance buffer matches Perl reference (max_err=$inst_err)");

    my $trail_err = 0.0;
    for my $i (0 .. ($n_trails_exp * 4) - 1) {
        my $d = abs($trails->[$i] - $rtrails[$i]);
        $trail_err = $d if $d > $trail_err;
    }
    cmp_ok($trail_err, '<', 1e-12, "fused trail buffer matches Perl reference (max_err=$trail_err)");

    # Verify u32 palette arrayref variant produces identical output
    my $px2     = make_nv_buf(@x0);
    my $py2     = make_nv_buf(@y0);
    my $vx2     = make_nv_buf(@vx0);
    my $vy2     = make_nv_buf(@vy0);
    my $inst2   = make_nv_buf((0.0) x ($n * 4));
    my $trails2 = make_nv_buf((0.0) x ($n_trails_exp * 4));
    TkMark::Compute::step_particles_2d(
        $px2, $py2, $vx2, $vy2, $inst2, \@pal_u32,
        $n, $w, $h, $ax, $ay, $grav, $dt, $damp,
        $trails2, $trail_step, 4
    );
    is(hash_doubles($inst2), hash_doubles($inst), 'u32 palette arrayref matches U8 RGBA palette LUT bit-for-bit');

    # Verify instance buffer feeds cleanly into Scene::create_instances
    SKIP: {
        skip 'Tcl::Tk::MT::Gfx not available', 1 unless $has_gfx;
        my $scene = Tcl::Tk::MT::Gfx::create_scene(800, 600);
        my $inst_id = $scene->create_instances($inst, 2, 1, 4);
        ok($inst_id > 0, 'fused instance buffer accepted by Scene::create_instances');
    }
}

# =========================================================================
# 2. Kernel 1: exact bit-for-bit parity (SIMD+pthreads vs PERL_FORCE_SCALAR=1)
# =========================================================================
{
    my $n = 1025; # odd count across multiple cache-line blocks
    my ($w, $h) = (800.0, 600.0);
    my ($ax, $ay, $grav, $dt, $damp) = (390.0, 310.0, 260.0, 0.85, 0.992);
    my $trail_step = 4;
    my $n_trails   = int(($n + $trail_step - 1) / $trail_step);

    srand(1337);
    my (@x0, @y0, @vx0, @vy0);
    for my $i (0 .. $n - 1) {
        push @x0,  rand($w);
        push @y0,  rand($h);
        push @vx0, (rand(8.0) - 4.0);
        push @vy0, (rand(8.0) - 4.0);
    }

    my %hashes;
    for my $mode (qw(simd scalar)) {
        local $ENV{PERL_FORCE_SCALAR} = ($mode eq 'scalar') ? 1 : 0;
        my $px     = make_nv_buf(@x0);
        my $py     = make_nv_buf(@y0);
        my $vx     = make_nv_buf(@vx0);
        my $vy     = make_nv_buf(@vy0);
        my $inst   = make_nv_buf((0.0) x ($n * 4));
        my $trails = make_nv_buf((0.0) x ($n_trails * 4));

        for my $step (1 .. 5) {
            TkMark::Compute::step_particles_2d(
                $px, $py, $vx, $vy, $inst, $pal_u8_ref,
                $n, $w, $h, $ax + $step * 3.5, $ay - $step * 2.25,
                $grav, $dt, $damp, $trails, $trail_step, 4
            );
        }
        $hashes{$mode} = {
            px     => hash_doubles($px),
            py     => hash_doubles($py),
            vx     => hash_doubles($vx),
            vy     => hash_doubles($vy),
            inst   => hash_doubles($inst),
            trails => hash_doubles($trails),
        };
    }

    for my $k (qw(px py vx vy inst trails)) {
        is($hashes{simd}{$k}, $hashes{scalar}{$k},
            "step_particles_2d bit-identical SIMD+pthreads vs PERL_FORCE_SCALAR=1 ($k)");
    }
}

# =========================================================================
# 3. Kernel 2: render_fractal_rgba8 correctness, zero-copy U8 AV, & parity
# =========================================================================
{
    my ($w, $h) = (127, 95); # odd width & height to test SIMD tail + row tiles
    my ($cx, $cy, $scale, $max_iter) = (-0.5, 0.0, 3.0, 64);

    my $buf_simd   = make_u8_buf($w * $h * 4);
    my $buf_scalar = make_u8_buf($w * $h * 4);

    if ($has_mt_arr) {
        is(TkMark::Compute::av_packed_type($buf_simd), 3, 'fractal output is AV_PACKED_U8');
    }

    {
        local $ENV{PERL_FORCE_SCALAR} = 0;
        my $rc = TkMark::Compute::render_fractal_rgba8(
            $buf_simd, $pal_u8_ref, $w, $h, $cx, $cy, $scale, $max_iter, 0, 0.0, 0.0, 4
        );
        is($rc, 0, 'render_fractal_rgba8 (Mandelbrot SIMD+pthreads) succeeded');
    }
    {
        local $ENV{PERL_FORCE_SCALAR} = 1;
        my $rc = TkMark::Compute::render_fractal_rgba8(
            $buf_scalar, $pal_u8_ref, $w, $h, $cx, $cy, $scale, $max_iter, 0, 0.0, 0.0, 4
        );
        is($rc, 0, 'render_fractal_rgba8 (Mandelbrot scalar) succeeded');
    }

    is(hash_u8_aref($buf_simd), hash_u8_aref($buf_scalar),
        'Mandelbrot bit-identical SIMD+pthreads vs PERL_FORCE_SCALAR=1');

    # Check interior pixel near c = (-0.5, 0) (center of image) is (6, 8, 16, 255)
    my $mid_off = (int($h / 2) * $w + int($w / 2)) * 4;
    is_deeply(
        [ @{$buf_simd}[$mid_off .. $mid_off + 3] ],
        [ 6, 8, 16, 255 ],
        'Mandelbrot interior point (-0.5, 0) has expected interior RGBA (6, 8, 16, 255)'
    );

    # Check corner pixel (0, 0) escaped and is colored from palette (not interior)
    my @corner = @{$buf_simd}[0 .. 3];
    is($corner[3], 255, 'Mandelbrot exterior pixel has alpha=255');
    ok(!($corner[0] == 6 && $corner[1] == 8 && $corner[2] == 16),
        'Mandelbrot exterior corner pixel is colored (not interior)');

    # Verify writable scalar byte-string output produces identical bytes
    my $str_out = '';
    my $rc_str = TkMark::Compute::render_fractal_rgba8(
        $str_out, $pal_str, $w, $h, $cx, $cy, $scale, $max_iter, 0, 0.0, 0.0, 4
    );
    is($rc_str, 0, 'render_fractal_rgba8 with writable byte-string output succeeded');
    is(length($str_out), $w * $h * 4, 'byte-string output has exact w*h*4 length');
    is(sha256_hex($str_out), hash_u8_aref($buf_simd),
        'byte-string output matches packed U8 AV output bit-for-bit');

    # Verify zero-copy upload to headless software surface via put_rgba_packed
    SKIP: {
        skip 'Tcl::Tk::MT::Gfx not available', 2 unless $has_gfx;
        my $surf = Tcl::Tk::MT::Gfx::create_surface($w, $h, 'software', 1.0, 1);
        ok(defined $surf, 'created headless software surface');
        my $tid = $surf->put_rgba_packed(0, $w, $h, $buf_simd);
        ok($tid > 0, 'put_rgba_packed accepted zero-copy fractal U8 buffer');
    }
}

# =========================================================================
# 4. Kernel 2: Julia mode bit-for-bit parity (SIMD+pthreads vs PERL_FORCE_SCALAR=1)
# =========================================================================
{
    my ($w, $h) = (97, 73);
    my ($cx, $cy, $scale, $max_iter) = (0.0, 0.0, 3.2, 64);
    my ($jr, $ji) = (-0.74543, 0.11301);

    my $j_simd   = make_u8_buf($w * $h * 4);
    my $j_scalar = make_u8_buf($w * $h * 4);

    {
        local $ENV{PERL_FORCE_SCALAR} = 0;
        my $rc = TkMark::Compute::render_fractal_rgba8(
            $j_simd, $pal_u8_ref, $w, $h, $cx, $cy, $scale, $max_iter, 1, $jr, $ji, 4
        );
        is($rc, 0, 'render_fractal_rgba8 (Julia SIMD+pthreads) succeeded');
    }
    {
        local $ENV{PERL_FORCE_SCALAR} = 1;
        my $rc = TkMark::Compute::render_fractal_rgba8(
            $j_scalar, $pal_u8_ref, $w, $h, $cx, $cy, $scale, $max_iter, 1, $jr, $ji, 4
        );
        is($rc, 0, 'render_fractal_rgba8 (Julia scalar) succeeded');
    }

    is(hash_u8_aref($j_simd), hash_u8_aref($j_scalar),
        'Julia bit-identical SIMD+pthreads vs PERL_FORCE_SCALAR=1');

    # Ensure Julia rendered non-uniform pixels
    my %distinct;
    for (my $i = 0; $i < $w * $h * 4; $i += 4) {
        $distinct{"$j_simd->[$i],$j_simd->[$i+1],$j_simd->[$i+2]"} = 1;
    }
    cmp_ok(scalar(keys %distinct), '>', 5, 'Julia image contains multiple distinct palette colors');
}

done_testing();
