use strict;
use warnings;
use Config;
use ExtUtils::MakeMaker;

my $is_darwin = ($^O eq 'darwin');
my $is_linux  = ($^O eq 'linux');
my $is_win32  = ($^O eq 'MSWin32');

my $CFG_CC         = $Config{cc}         || 'cc';
my $CFG_LD         = $Config{ld}         || $CFG_CC;
my $is_msvc        = ($is_win32 && $CFG_CC =~ /(?:^|[\\\/])cl(?:\.exe)?$/i) ? 1 : 0;
my $DLEXT          = $Config{dlext}      || ($is_win32 ? 'dll' : 'so');
my $OBJ            = $Config{obj_ext}    || ($is_msvc ? '.obj' : '.o');
my $CFG_CCFLAGS    = $Config{ccflags}    // '';
my $CFG_OPTIMIZE   = $Config{optimize}   // ($is_msvc ? '/O2' : '-O2');
my $CFG_CCCDLFLAGS = $Config{cccdlflags} // ($is_linux ? '-fPIC' : '');
my $CFG_LDDLFLAGS  = $Config{lddlflags}  // ($is_darwin ? '-bundle -undefined dynamic_lookup' : ($is_msvc ? '/DLL' : '-shared'));

my @sys_libs;
if ($is_darwin || $is_linux) {
    push @sys_libs, '-lpthread', '-lm';
} elsif ($is_win32) {
    push @sys_libs, '-lm' unless $is_msvc;
} else {
    push @sys_libs, '-lpthread', '-lm';
}

my $WIN32_PERL_LIB = $is_win32 ? '$(PERL_ARCHIVE)' : '';
my $COMPUTE_LIBS   = join(' ', grep { length } ($WIN32_PERL_LIB, @sys_libs));

# Locate xsubpp & default typemap from active @INC (works for both installed and uninstalled perl5-mt)
my ($XSUBPP_BIN, $TYPEMAP_FILE);
for my $dir (@INC) {
    next if ref $dir;
    if (!$XSUBPP_BIN && -f "$dir/ExtUtils/xsubpp") {
        $XSUBPP_BIN = "$dir/ExtUtils/xsubpp";
    }
    if (!$TYPEMAP_FILE && -f "$dir/ExtUtils/typemap") {
        $TYPEMAP_FILE = "$dir/ExtUtils/typemap";
    }
}
die "Could not locate ExtUtils/xsubpp in \@INC\n" unless $XSUBPP_BIN;
my $TYPEMAP_ARG = $TYPEMAP_FILE ? "-typemap \"$TYPEMAP_FILE\"" : '';

my $COMPUTE_BUNDLE = "blib/arch/auto/TkMark/Compute/Compute.$DLEXT";
my @COMPUTE_OBJS   = ("Compute$OBJ", "c/compute$OBJ");

WriteMakefile(
    NAME             => 'TkMark::Compute',
    VERSION_FROM     => 'lib/TkMark/Compute.pm',
    ABSTRACT         => 'Benchmark testbed and C11 SIMD/MT compute kernels for Tcl::Tk::MT',
    AUTHOR           => 'stratum42',
    LICENSE          => 'perl_5',
    MIN_PERL_VERSION => '5.016',
    XS               => {},
    C                => [],
    OBJECT           => '',
    EXE_FILES        => ['tkmark.pl'],
    clean            => {
        FILES => join(' ', 'Compute.c', @COMPUTE_OBJS, $COMPUTE_BUNDLE),
    },
);

package MY;

sub dynamic {
    my $self = shift;
    my $base = $self->SUPER::dynamic(@_);
    return $base . "\n"
         . "dynamic :: $COMPUTE_BUNDLE\n"
         . "\t\$(NOECHO) \$(NOOP)\n";
}

sub postamble {
    my $c11_std   = $is_msvc ? '/std:c11 /experimental:c11atomics /D_CRT_SECURE_NO_WARNINGS' : '-std=c11';
    my $cc_c_flag = $is_msvc ? '/c' : '-c';
    my $obj_out   = $is_msvc ? '/Fo$@' : '-o $@';
    my $ld_out    = $is_msvc ? '/OUT:$@' : '-o $@';
    my $objs_str  = join(' ', @COMPUTE_OBJS);

    return <<"EOF";

TKMARK_INC      = -I. -Ic
TKMARK_C11      = $c11_std
TKMARK_CC       = $CFG_CC
TKMARK_LD       = $CFG_LD
TKMARK_CCFLAGS  = $CFG_CCFLAGS
TKMARK_OPTIMIZE = $CFG_OPTIMIZE
TKMARK_CCCDL    = $CFG_CCCDLFLAGS
TKMARK_LDDL     = $CFG_LDDLFLAGS
TKMARK_XSUBPP   = \$(ABSPERLRUN) "$XSUBPP_BIN" $TYPEMAP_ARG
TKMARK_CC_C11   = \$(TKMARK_CC) $cc_c_flag \$(TKMARK_INC) \$(TKMARK_CCFLAGS) \$(TKMARK_OPTIMIZE) \$(TKMARK_CCCDL) \$(TKMARK_C11)
TKMARK_CC_XS    = \$(TKMARK_CC) $cc_c_flag \$(TKMARK_INC) "-I\$(PERL_INC)" \$(TKMARK_CCFLAGS) \$(TKMARK_OPTIMIZE) \$(TKMARK_CCCDL) \$(TKMARK_C11) -DVERSION=\\"\$(VERSION)\\" -DXS_VERSION=\\"\$(XS_VERSION)\\"

Compute.c : Compute.xs c/mt_compat.h c/compute.h
\t\$(TKMARK_XSUBPP) Compute.xs > Compute.xsc && \$(MV) Compute.xsc Compute.c

Compute$OBJ : Compute.c
\t\$(TKMARK_CC_XS) $obj_out Compute.c

c/compute$OBJ : c/compute.c c/compute.h c/tkmt_thread.h
\t\$(TKMARK_CC_C11) $obj_out c/compute.c

$COMPUTE_BUNDLE : $objs_str
\t\$(MKPATH) blib/arch/auto/TkMark/Compute
\t\$(TKMARK_LD) \$(TKMARK_LDDL) $objs_str $ld_out $COMPUTE_LIBS
\t\$(CHMOD) 755 \$\@
EOF
}
