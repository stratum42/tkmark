package TkMark::Engine;

use strict;
use warnings;
use Time::HiRes qw(time);
use POSIX qw(floor);

our $VERSION = '0.01';

# Dark telemetry palette constants
our %THEME = (
    bg_dark       => '#0b0f17',
    bg_panel      => '#121826',
    bg_card       => '#182132',
    border        => '#26334d',
    grid          => '#1c2536',
    text_pri      => '#e6edf3',
    text_sec      => '#8b949e',
    accent_cyan   => '#38bdf8',
    accent_green  => '#22c55e',
    accent_red    => '#ef4444',
    accent_amber  => '#f59e0b',
    accent_purple => '#a855f7',
);

# Capability flags populated in BEGIN (do not reset at runtime)
our ($HAS_MT_GFX, $IS_PERL5_MT, $HAVE_PACKED, $HAS_POOL, $HAS_CHANNEL, $HAS_ARRAY);

BEGIN {
    $HAS_MT_GFX  = 0;
    $IS_PERL5_MT = 0;
    $HAVE_PACKED = 0;
    $HAS_POOL    = 0;
    $HAS_CHANNEL = 0;
    $HAS_ARRAY   = 0;

    $HAS_MT_GFX = eval { require Tcl::Tk::MT::Gfx; Tcl::Tk::MT::Gfx::init(); 1 } ? 1 : 0;
    if ($HAS_MT_GFX) {
        $IS_PERL5_MT = eval { Tcl::Tk::MT::Gfx::is_perl5_mt() } ? 1 : 0;
        $HAVE_PACKED = eval { Tcl::Tk::MT::Gfx::have_packed_av() } ? 1 : 0;
    }
    $HAS_ARRAY   = ($IS_PERL5_MT && eval { require MT::Array; 1 })   ? 1 : 0;
    $HAS_POOL    = ($IS_PERL5_MT && eval { require MT::Pool; 1 })    ? 1 : 0;
    $HAS_CHANNEL = ($IS_PERL5_MT && eval { require MT::Channel; 1 }) ? 1 : 0;
}

# Lazily initialized worker pool for mt_gpu mode (created after module load)
my $SHARED_POOL;
my $SHARED_POOL_WORKERS = 0;

sub is_perl5_mt    { $IS_PERL5_MT }
sub have_packed_av { ($HAVE_PACKED && $HAS_ARRAY) ? 1 : 0 }
sub has_pool       { $HAS_POOL }

sub detect_cpu_cores {
    my $cores = 4;
    if ($^O eq 'darwin') {
        my $out = `sysctl -n hw.ncpu 2>/dev/null`;
        $cores = int($out) if defined $out && $out =~ /^\s*(\d+)/;
    }
    elsif (-r '/proc/cpuinfo') {
        if (open my $fh, '<', '/proc/cpuinfo') {
            my $c = 0;
            while (<$fh>) { $c++ if /^processor\s*:/; }
            close $fh;
            $cores = $c if $c > 0;
        }
    }
    $cores = 1 if $cores < 1;
    $cores = 8 if $cores > 8;
    return $cores;
}

sub gpu_backend_available {
    return '' unless $HAS_MT_GFX;
    return 'metal'  if eval { Tcl::Tk::MT::Gfx::backend_available('metal') };
    return 'vulkan' if eval { Tcl::Tk::MT::Gfx::backend_available('vulkan') };
    return '';
}

sub resolve_stack {
    my ($requested) = @_;
    $requested = 'auto' unless defined $requested && length $requested;
    $requested = lc($requested);

    if ($requested eq 'auto') {
        my $env_accel = defined($ENV{TCL_TK_MT_ACCEL}) ? lc($ENV{TCL_TK_MT_ACCEL}) : 'auto';
        if ($env_accel eq 'off') {
            return 'stock';
        }
        my $gpu = gpu_backend_available();
        if ($IS_PERL5_MT && have_packed_av() && $gpu) {
            return 'mt_gpu';
        }
        if ($gpu) {
            return 'dropin';
        }
        return 'stock';
    }

    die "Invalid --stack '$requested' (expected auto|stock|dropin|mt_gpu)\n"
        unless $requested eq 'stock' || $requested eq 'dropin' || $requested eq 'mt_gpu';
    return $requested;
}

sub resolve_backend {
    my ($stack, $explicit, $headless) = @_;
    if (defined $explicit && length $explicit && lc($explicit) ne 'auto') {
        return lc($explicit);
    }
    if ($stack eq 'stock') {
        return $headless ? 'software' : 'off';
    }
    # dropin or mt_gpu
    my $env_accel = defined($ENV{TCL_TK_MT_ACCEL}) ? lc($ENV{TCL_TK_MT_ACCEL}) : '';
    if ($env_accel eq 'metal' || $env_accel eq 'vulkan' || $env_accel eq 'software') {
        return $env_accel if eval { Tcl::Tk::MT::Gfx::backend_available($env_accel) };
    }
    my $gpu = gpu_backend_available();
    return $gpu if $gpu;
    return 'software';
}

sub get_pool {
    my ($workers) = @_;
    return undef unless $HAS_POOL;
    $workers = detect_cpu_cores() unless defined $workers && $workers > 0;
    return undef if $workers <= 1;
    if (!$SHARED_POOL) {
        $SHARED_POOL = eval { MT::Pool->new(workers => $workers) };
        $SHARED_POOL_WORKERS = $SHARED_POOL ? $workers : 0;
    }
    return $SHARED_POOL;
}

sub pool_workers { $SHARED_POOL_WORKERS }

sub shutdown_pool {
    if ($SHARED_POOL) {
        eval { $SHARED_POOL->shutdown() };
        $SHARED_POOL = undef;
        $SHARED_POOL_WORKERS = 0;
    }
}

# Packed little-endian RGBA8888 (matches tkmark_rgba in Compute.xs)
sub rgba {
    my ($r, $g, $b, $a) = @_;
    $a = 255 unless defined $a;
    return (($r & 0xFF) | (($g & 0xFF) << 8) | (($b & 0xFF) << 16) | (($a & 0xFF) << 24));
}

# Build smooth 256-entry RGB palettes for Fractal & Boids
my %PALETTE_CACHE;

sub _lerp_stops {
    my ($stops) = @_;
    my @rgb;
    my @u32;
    my @hex;
    my @bytes;
    my $n_stops = scalar @$stops;
    for my $i (0 .. 255) {
        my $t = $i / 255.0;
        my ($s0, $s1) = ($stops->[0], $stops->[-1]);
        for my $j (0 .. $n_stops - 2) {
            if ($t >= $stops->[$j][0] && $t <= $stops->[$j + 1][0]) {
                $s0 = $stops->[$j];
                $s1 = $stops->[$j + 1];
                last;
            }
        }
        my $span = $s1->[0] - $s0->[0];
        my $u    = $span > 0 ? (($t - $s0->[0]) / $span) : 0.0;
        my $r    = int($s0->[1] + ($s1->[1] - $s0->[1]) * $u + 0.5);
        my $g    = int($s0->[2] + ($s1->[2] - $s0->[2]) * $u + 0.5);
        my $b    = int($s0->[3] + ($s1->[3] - $s0->[3]) * $u + 0.5);
        $r = 0 if $r < 0; $r = 255 if $r > 255;
        $g = 0 if $g < 0; $g = 255 if $g > 255;
        $b = 0 if $b < 0; $b = 255 if $b > 255;
        push @rgb,   [ $r, $g, $b ];
        push @u32,   rgba($r, $g, $b, 255);
        push @hex,   sprintf('#%02x%02x%02x', $r, $g, $b);
        push @bytes, pack('CCCC', $r, $g, $b, 255);
    }
    return {
        rgb   => \@rgb,
        u32   => \@u32,
        hex   => \@hex,
        bytes => \@bytes,
    };
}

sub get_palette {
    my ($name) = @_;
    $name = 'inferno' unless defined $name && length $name;
    $name = lc($name);
    return $PALETTE_CACHE{$name} if exists $PALETTE_CACHE{$name};

    my %defs = (
        inferno => [
            [ 0.00,   4,   3,  16 ],
            [ 0.18,  45,  17,  95 ],
            [ 0.38, 120,  28, 109 ],
            [ 0.58, 187,  55,  84 ],
            [ 0.76, 243, 119,  26 ],
            [ 0.90, 252, 206,  37 ],
            [ 1.00, 252, 255, 164 ],
        ],
        viridis => [
            [ 0.00,  68,   1,  84 ],
            [ 0.25,  59,  82, 139 ],
            [ 0.50,  33, 145, 140 ],
            [ 0.75,  94, 201,  98 ],
            [ 1.00, 253, 231,  37 ],
        ],
        plasma => [
            [ 0.00,  13,   8, 135 ],
            [ 0.25, 126,   3, 168 ],
            [ 0.50, 204,  71, 120 ],
            [ 0.75, 248, 149,  64 ],
            [ 1.00, 240, 249,  33 ],
        ],
        ocean => [
            [ 0.00,   4,  10,  28 ],
            [ 0.25,  12,  52, 110 ],
            [ 0.50,  14, 128, 178 ],
            [ 0.75,  56, 210, 224 ],
            [ 1.00, 232, 252, 255 ],
        ],
    );
    my $stops = $defs{$name} || $defs{inferno};
    $PALETTE_CACHE{$name} = _lerp_stops($stops);
    return $PALETTE_CACHE{$name};
}

# Compute percentile from an arrayref of numbers (p in 0..100)
sub percentile {
    my ($vals, $p) = @_;
    return 0.0 unless $vals && @$vals;
    my @sorted = sort { $a <=> $b } @$vals;
    my $n = scalar @sorted;
    return $sorted[0] if $n == 1;
    my $idx = ($p / 100.0) * ($n - 1);
    my $lo  = int($idx);
    my $hi  = $lo + 1;
    $hi = $n - 1 if $hi >= $n;
    my $frac = $idx - $lo;
    return $sorted[$lo] + ($sorted[$hi] - $sorted[$lo]) * $frac;
}

sub mean {
    my ($vals) = @_;
    return 0.0 unless $vals && @$vals;
    my $sum = 0.0;
    $sum += $_ for @$vals;
    return $sum / scalar(@$vals);
}

# Count pixels in an RGBA8888 byte buffer that differ from the background pixel
sub count_nonblank_pixels {
    my ($rgba_bytes, $bg_hex) = @_;
    return 0 unless defined $rgba_bytes && length($rgba_bytes) >= 4;

    my $bg_u32 = 0xFF000000;
    if (defined $bg_hex && $HAS_MT_GFX) {
        $bg_u32 = Tcl::Tk::MT::Gfx::parse_color($bg_hex);
    }
    my $bg_rgb = $bg_u32 & 0x00FFFFFF;

    my $nonblank = 0;
    my @px = unpack('L<*', $rgba_bytes);
    for my $p (@px) {
        my $rgb = $p & 0x00FFFFFF;
        if ($rgb != $bg_rgb && $rgb != 0) {
            $nonblank++;
        }
    }
    return $nonblank;
}

# Write binary PPM (P6) from an RGBA8888 byte buffer
sub write_ppm {
    my ($path, $rgba_bytes, $w, $h) = @_;
    return 0 unless defined $path && defined $rgba_bytes && $w > 0 && $h > 0;

    # Ensure parent directory exists
    if ($path =~ m{\A(.+)/[^/]+\z}) {
        my $dir = $1;
        unless (-d $dir) {
            require File::Path;
            File::Path::make_path($dir);
        }
    }

    open my $fh, '>', $path or die "Cannot write PPM '$path': $!\n";
    binmode $fh;
    print {$fh} "P6\n$w $h\n255\n";

    # Strip alpha channel per row (RGBA8888 -> RGB888)
    my $stride = $w * 4;
    for my $y (0 .. $h - 1) {
        my $row = substr($rgba_bytes, $y * $stride, $stride);
        my $rgb_row = pack('(a3)*', unpack('(a3x)*', $row));
        print {$fh} $rgb_row;
    }
    close $fh or die "Cannot close PPM '$path': $!\n";
    return 1;
}

# Encode Perl data structure to JSON (uses core JSON::PP)
sub encode_json_pretty {
    my ($data) = @_;
    require JSON::PP;
    my $json = JSON::PP->new->utf8(0)->canonical(1)->pretty(1);
    return $json->encode($data);
}

sub json_bool {
    my ($v) = @_;
    require JSON::PP;
    return $v ? JSON::PP::true() : JSON::PP::false();
}

1;

__END__

=head1 NAME

TkMark::Engine - Shared runtime helpers for TkMark Studio

=head1 DESCRIPTION

Provides capability detection (C<perl5-mt>, packed arrays, GPU backends,
C<MT::Pool>), stack and backend resolution, color palettes, frame-timing
statistics, PPM snapshot export, and JSON encoding for C<tkmark.pl> and the
TkMark scene modules.

=head1 LICENSE

This module is available under the same terms as Perl 5 itself.

=cut
