SUBDIRS=src tools tests po m4 docs bindings 

# build documentation when doing a distcheck.
DISTCHECK_CONFIGURE_FLAGS = 				\
	--enable-gtk-doc --with-mono 			\
	--with-python --without-hal			\
	--enable-udev --with-udev-dir=`pwd`/udev

ACLOCAL_AMFLAGS = -I m4

pkgconfigdir = $(libdir)/pkgconfig
pkgconfig_DATA = libgpod-1.0.pc

EXTRA_DIST =                    \
        TROUBLESHOOTING         \
        README.SysInfo          \
        README.overview         \
        README.sqlite           \
        intltool-merge.in       \
        intltool-update.in      \
        intltool-extract.in     \
        libgpod-1.0.pc.in


DISTCLEANFILES =                \
        intltool-extract        \
        intltool-merge          \
        intltool-update

