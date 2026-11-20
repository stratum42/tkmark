package TkMark::Compute;

use strict;
use warnings;
use Exporter 'import';
use XSLoader;

our $VERSION = '0.01';

our @EXPORT_OK = qw(
    step_particles_2d
    render_fractal_rgba8
    is_perl5_mt
    have_packed_av
    av_packed_type
    force_scalar
    default_workers
);

XSLoader::load('TkMark::Compute', $VERSION);

1;

__END__

=head1 NAME

TkMark::Compute - C11 SIMD and multi-threaded compute kernels for TkMark Studio

=head1 SYNOPSIS

    use TkMark::Compute qw(step_particles_2d render_fractal_rgba8);

=head1 DESCRIPTION

C<TkMark::Compute> is a standalone C11 XS module (marked C<PERL_XS_THREADSAFE>)
that implements the CPU compute kernels used by TkMark Studio's C<mt_gpu> stack:
a 2D particle integrator and a Mandelbrot/Julia RGBA8888 renderer.

Under C<perl5-mt>, it operates directly on C<SVf_PACKED_AV> backing stores
(C<AV_PACKED_NV> and C<AV_PACKED_U8>) without copying or boxing elements.
Under stock Perl 5, it falls back to standard Perl arrays. Setting
C<PERL_FORCE_SCALAR=1> selects a single-threaded scalar implementation that
produces bit-identical results to the NEON/SSE2 and worker-thread path.

=head1 FUNCTIONS

=over 4

=item C<step_particles_2d($px, $py, $vx, $vy, $inst, $palette_lut, $n, $w, $h, $ax, $ay, $grav, $dt, $damp, $trails, $trail_step, $workers)>

Advances C<$n> 2D particles in place under a softened inverse-square attractor,
writes stride-4 C<[x, y, rgba_u32, size]> instance records into C<$inst>, and
optionally emits stride-4 C<[x0, y0, x1, y1]> trail segments into C<$trails>.
Returns the number of trail segments written.

=item C<render_fractal_rgba8($rgba_out, $palette_lut, $w, $h, $cx, $cy, $scale, $max_iter, $is_julia, $jr, $ji, $workers)>

Renders a C<$w x $h> RGBA8888 Mandelbrot (C<$is_julia == 0>) or Julia
(C<$is_julia == 1>) image into a packed C<U8> arrayref or writable byte string.
Returns C<0> on success.

=item C<is_perl5_mt()>, C<have_packed_av()>, C<av_packed_type($aref)>, C<force_scalar()>, C<default_workers()>

Runtime capability and configuration queries.

=back

=head1 AUTHOR

stratum42

=head1 LICENSE

This module is available under the same terms as Perl 5 itself.

=cut
