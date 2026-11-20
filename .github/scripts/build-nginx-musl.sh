#!/usr/bin/env bash
#
# Copyright (C) Nginx, Inc.
#
# Build a statically linked nginx package for a cross target.
#
# libc, libm and the kernel are the only dynamic dependencies left, so the
# artifact runs on any Linux of the same CPU architecture.
#
# Required environment:
#   ARCH                 artifact architecture name (x86_64, aarch64, ...)
#   MACHINE              target "uname -m" value
#   CROSS                toolchain prefix, e.g. aarch64-unknown-linux-musl-
#
# Optional environment:
#   NGINX_VERSION        taken from src/core/nginx.h when unset
#   TRIPLE               autoconf host triple (default: ${CROSS} without "-")
#   LIBC                 libc name used in the artifact name (default: musl)
#   WITH_OPENSSL         1 (default) or 0
#   OPENSSL_TARGET       OpenSSL Configure target, required with WITH_OPENSSL=1
#   OPENSSL_VERSION      default 3.5.9
#   PCRE2_VERSION        default 10.49
#   ZLIB_VERSION         default 1.3.2
#   EXTRA_OPENSSL_OPT    extra ./Configure options for OpenSSL
#   EXTRA_CONF_OPT       extra ./configure options for nginx
#   RUNNABLE             1 (default) when target binaries can be executed on
#                        this host (qemu-user binfmt); 0 otherwise
#   PATCH_RUN_TESTS      1 to turn nginx autoconf "run" tests into link-only
#                        tests and to supply the target ABI sizes; required
#                        when RUNNABLE=0
#   FORCE_ENDIAN         little|big, required when PATCH_RUN_TESTS=1
#   SIZEOF_*             overrides for the ABI, only used with
#                        PATCH_RUN_TESTS=1 (defaults are LP64)
#   STRIP                strip(1) command (default: ${CROSS}strip)
#   SRC_DIR              nginx source tree (default: current directory)
#   WORK_DIR             build scratch directory
#   OUT_DIR              artifact output directory (default: $SRC_DIR/dist)
#

set -euo pipefail

# logs go to stderr, stdout is used to return values from the helpers below
log() { printf '\n==> %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# make CI logs point at the failing command
trap 'printf "\nerror: %s failed (line %s)\n" "$BASH_COMMAND" "$LINENO" >&2' ERR

: "${ARCH:?ARCH is required}"
: "${MACHINE:?MACHINE is required}"
# CROSS may be empty: that is a native build on the target machine
CROSS="${CROSS:-}"

LIBC="${LIBC:-musl}"
NGINX_VERSION="${NGINX_VERSION:-}"
TRIPLE="${TRIPLE:-${CROSS%-}}"
RUNNABLE="${RUNNABLE:-1}"
PATCH_RUN_TESTS="${PATCH_RUN_TESTS:-0}"
FORCE_ENDIAN="${FORCE_ENDIAN:-}"
WITH_OPENSSL="${WITH_OPENSSL:-1}"
OPENSSL_TARGET="${OPENSSL_TARGET:-}"
OPENSSL_VERSION="${OPENSSL_VERSION:-3.5.9}"
PCRE2_VERSION="${PCRE2_VERSION:-10.49}"
ZLIB_VERSION="${ZLIB_VERSION:-1.3.2}"
EXTRA_OPENSSL_OPT="${EXTRA_OPENSSL_OPT:-}"
EXTRA_CONF_OPT="${EXTRA_CONF_OPT:-}"
STRIP="${STRIP:-${CROSS}strip}"

CC="${CROSS}gcc"
AR="${CROSS}ar"
RANLIB="${CROSS}ranlib"
READELF="${CROSS}readelf"

# an external toolchain may be supplied without a prefix ("install this tarball
# and use its gcc"), so fall back to what the compiler reports about itself
if [ -z "$TRIPLE" ]; then
    TRIPLE="$("$CC" -dumpmachine 2>/dev/null || true)"
fi
[ -n "$TRIPLE" ] || die "TRIPLE is required (set TRIPLE or use a CROSS prefix)"

if ! command -v "$STRIP" >/dev/null 2>&1; then
    STRIP="$("$CC" -print-prog-name=strip 2>/dev/null || echo "$STRIP")"
fi

SRC_DIR="$(cd "${SRC_DIR:-$PWD}" && pwd)"
WORK_DIR="${WORK_DIR:-${RUNNER_TEMP:-/tmp}/nginx-musl}"
DL_DIR="$WORK_DIR/dl"
DEPS_DIR="$WORK_DIR/deps"
SYSROOT="$WORK_DIR/sysroot-$ARCH"
OUT_DIR="${OUT_DIR:-$SRC_DIR/dist}"
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"

mkdir -p "$DL_DIR" "$DEPS_DIR" "$SYSROOT/include" "$SYSROOT/lib" "$OUT_DIR"

if [ -z "$NGINX_VERSION" ]; then
    NGINX_VERSION="$(sed -n 's/^#define NGINX_VERSION  *"\(.*\)"/\1/p' \
                     "$SRC_DIR/src/core/nginx.h")"
fi
[ -n "$NGINX_VERSION" ] || die "cannot determine the nginx version"

command -v "$CC" >/dev/null 2>&1 || die "$CC is not in PATH"
log "toolchain: $("$CC" --version | head -n 1)"
log "target: $MACHINE ($LIBC), nginx $NGINX_VERSION"


fetch() {
    # fetch <url> <file name>, prints the local path
    local url="$1" file="$2"

    if [ ! -s "$DL_DIR/$file" ]; then
        log "downloading $file"
        curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 \
             -o "$DL_DIR/$file.part" "$url"
        mv "$DL_DIR/$file.part" "$DL_DIR/$file"
    fi

    printf '%s\n' "$DL_DIR/$file"
}


unpack() {
    # unpack <tarball>, prints the extracted directory
    local tarball="$1" base dir

    base="$(basename "$tarball")"
    base="${base%.tar.gz}"
    base="${base%.tar.xz}"
    base="${base%.tgz}"
    dir="$DEPS_DIR/$base"

    if [ ! -d "$dir" ]; then
        log "extracting $base"
        tar -xf "$tarball" -C "$DEPS_DIR"
    fi

    printf '%s\n' "$dir"
}


#
# The bundled libraries are cross compiled into a private sysroot and picked
# up by nginx through -I/-L.  Letting nginx build them itself is not an
# option: its rules pass CC but no --host, so the autoconf based PCRE2 build
# would try to run target test programs, and OpenSSL needs an explicit
# --cross-compile-prefix.
#

PCRE2_SRC="$(unpack "$(fetch \
    "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$PCRE2_VERSION/pcre2-$PCRE2_VERSION.tar.gz" \
    "pcre2-$PCRE2_VERSION.tar.gz")")"

ZLIB_SRC="$(unpack "$(fetch \
    "https://github.com/madler/zlib/releases/download/v$ZLIB_VERSION/zlib-$ZLIB_VERSION.tar.gz" \
    "zlib-$ZLIB_VERSION.tar.gz")")"

[ -d "$PCRE2_SRC/src" ] || die "unexpected PCRE2 layout: $PCRE2_SRC"
[ -f "$ZLIB_SRC/zlib.h" ] || die "unexpected zlib layout: $ZLIB_SRC"


if [ ! -f "$SYSROOT/lib/libpcre2-8.a" ]; then
    log "building PCRE2 $PCRE2_VERSION"

    (
        cd "$PCRE2_SRC"

        if [ -f Makefile ]; then
            make distclean >/dev/null 2>&1 || true
        fi

        ./configure \
            --host="$TRIPLE" \
            --prefix="$SYSROOT" \
            --disable-shared --enable-static

        # pcre2.h is generated by configure (or is the shipped generic copy)
        [ -f src/pcre2.h ] || cp src/pcre2.h.generic src/pcre2.h

        make -j"$JOBS" libpcre2-8.la
        install -D -m 644 src/pcre2.h "$SYSROOT/include/pcre2.h"
        install -D -m 644 .libs/libpcre2-8.a "$SYSROOT/lib/libpcre2-8.a"
    )
fi


if [ ! -f "$SYSROOT/lib/libz.a" ]; then
    log "building zlib $ZLIB_VERSION"

    (
        cd "$ZLIB_SRC"

        if [ -f Makefile ]; then
            make distclean >/dev/null 2>&1 || true
        fi

        CC="$CC" AR="$AR" RANLIB="$RANLIB" CFLAGS="-O2" \
            ./configure --static --prefix="$SYSROOT"

        make -j"$JOBS" libz.a
        make install
    )
fi


if [ "$WITH_OPENSSL" = "1" ]; then
    [ -n "$OPENSSL_TARGET" ] || die "OPENSSL_TARGET is required with WITH_OPENSSL=1"

    OPENSSL_SRC="$(unpack "$(fetch \
        "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" \
        "openssl-$OPENSSL_VERSION.tar.gz")")"

    if [ ! -f "$SYSROOT/lib/libssl.a" ]; then
        log "building OpenSSL $OPENSSL_VERSION for $OPENSSL_TARGET"

        (
            cd "$OPENSSL_SRC"

            if [ -f Makefile ]; then
                make clean >/dev/null 2>&1 || true
            fi

            # only meaningful for a cross build, OpenSSL rejects an empty one
            ssl_prefix=
            if [ -n "$CROSS" ]; then
                ssl_prefix="--cross-compile-prefix=$CROSS"
            fi

            ./Configure "$OPENSSL_TARGET" \
                --prefix="$SYSROOT" \
                --openssldir="$SYSROOT/ssl" \
                --libdir=lib \
                $ssl_prefix \
                no-shared no-tests no-docs no-comp no-async \
                $EXTRA_OPENSSL_OPT

            make -j"$JOBS" build_sw
            make install_sw
        )
    fi

    [ -f "$SYSROOT/lib/libssl.a" ] || die "OpenSSL was not installed into $SYSROOT"

    SSL_MODULES="--with-http_ssl_module --with-http_v2_module \
                 --with-stream_ssl_module --with-stream_ssl_preread_module"
fi


#
# Cross builds without an emulator cannot run the configure test programs.
# Turn "does the program run" tests into "does it link" tests, pin the byte
# order and use the target ABI sizes instead of executing a test binary.
#

cd "$SRC_DIR"

if [ "$PATCH_RUN_TESTS" = "1" ]; then
    case "$FORCE_ENDIAN" in
        little|big) ;;
        *) die "PATCH_RUN_TESTS=1 requires FORCE_ENDIAN=little or FORCE_ENDIAN=big" ;;
    esac

    log "patching nginx autoconf run tests (FORCE_ENDIAN=$FORCE_ENDIAN)"

    for f in auto/cc/name auto/cc/conf auto/os/linux auto/unix; do
        sed -i 's/^\([[:space:]]*\)ngx_feature_run=yes$/\1ngx_feature_run=no/' "$f"
    done

    if [ "$FORCE_ENDIAN" = "little" ]; then
        sed -i 's|if \$NGX_AUTOTEST >/dev/null 2>&1; then|if true; then|' \
            auto/endianness
    else
        sed -i 's|if \$NGX_AUTOTEST >/dev/null 2>&1; then|if false; then|' \
            auto/endianness
    fi

    # sizeof() cannot be measured without running the test program either.
    # Replace the check with values taken from the target ABI.
    cat > auto/types/sizeof <<'SIZEOF_EOF'

echo $ngx_n "checking for $ngx_type size ...$ngx_c"

case "$ngx_type" in
    int)          ngx_size=${SIZEOF_INT:-4} ;;
    long)         ngx_size=${SIZEOF_LONG:-8} ;;
    "long long")  ngx_size=${SIZEOF_LONG_LONG:-8} ;;
    "void *")     ngx_size=${SIZEOF_POINTER:-8} ;;
    sig_atomic_t) ngx_size=${SIZEOF_SIG_ATOMIC_T:-4} ;;
    size_t)       ngx_size=${SIZEOF_SIZE_T:-8} ;;
    off_t)        ngx_size=${SIZEOF_OFF_T:-8} ;;
    time_t)       ngx_size=${SIZEOF_TIME_T:-8} ;;
    *)            ngx_size= ;;
esac

echo " $ngx_size bytes"

case $ngx_size in
    4)
        ngx_max_value=2147483647
        ngx_max_len='(sizeof("-2147483648") - 1)'
    ;;

    8)
        ngx_max_value=9223372036854775807LL
        ngx_max_len='(sizeof("-9223372036854775808") - 1)'
    ;;

    *)
        echo
        echo "$0: error: can not guess $ngx_type size"
        exit 1
    ;;
esac
SIZEOF_EOF
fi


#
# nginx's own --crossbuild only parses the machine name: it then hardcodes
# NGX_MACHINE=i386, which enables the x86 unaligned access optimization on
# every target, uses a 32 byte cache line, and hides that this is Linux (no
# O_DIRECT alignment).  Feed configure a fake uname(1) instead, so the
# machine dependent defines are derived from the real target CPU.
#

FAKE_BIN="$WORK_DIR/fakebin-$ARCH"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/uname" <<EOF
#!/bin/sh
case "\$1" in
    -r) echo "5.10.0" ;;
    -m) echo "$MACHINE" ;;
    *)  echo "Linux" ;;
esac
EOF
chmod +x "$FAKE_BIN/uname"


#
# auto/cc/name links its test program before NGX_TEST_LD_OPT is set, so a
# plain musl cross gcc would produce a dynamically linked binary with no musl
# loader on the build host, and nginx would report that the compiler does not
# work.  The final binary is static anyway, so force it for every link.
#

CC_WRAPPER="$WORK_DIR/cc-$ARCH"
printf '#!/bin/sh\nexec "%s" -static "$@"\n' "$CC" > "$CC_WRAPPER"
chmod +x "$CC_WRAPPER"


log "configuring nginx"

set -- \
    --prefix=/usr/local/nginx \
    --with-cc="$CC_WRAPPER" \
    --with-threads \
    --with-http_realip_module \
    --with-http_stub_status_module \
    --with-http_gzip_static_module \
    --with-http_sub_module \
    --with-http_addition_module \
    --with-http_auth_request_module \
    --with-http_slice_module \
    --with-http_dav_module \
    --with-stream \
    --with-stream_realip_module \
    --with-cc-opt="-O2 -I$SYSROOT/include" \
    --with-ld-opt="-static -L$SYSROOT/lib"

# word splitting is intended here
set -- "$@" $SSL_MODULES $EXTRA_CONF_OPT

PATH="$FAKE_BIN:$PATH" ./auto/configure "$@"


if [ "$PATCH_RUN_TESTS" = "1" ]; then
    grep -q '^#define NGX_HAVE_EPOLL ' objs/ngx_auto_config.h \
        || die "epoll was not detected, the build would use select()"
fi


log "building"
make -j"$JOBS"


BIN="$SRC_DIR/objs/nginx"
[ -f "$BIN" ] || die "objs/nginx was not created"

if [ "$("$READELF" -l "$BIN" | grep -c 'INTERP' || true)" != "0" ]; then
    die "$BIN is dynamically linked (INTERP segment found)"
fi

if [ "$("$READELF" -d "$BIN" | grep -c 'NEEDED' || true)" != "0" ]; then
    die "$BIN is dynamically linked (DT_NEEDED entries found)"
fi

if [ "$RUNNABLE" = "1" ]; then
    log "checking that the binary runs"
    "$BIN" -V >/dev/null 2>&1 || die "$BIN does not run on this host"
fi


log "packaging"

PKG_NAME="nginx-$NGINX_VERSION-$MACHINE-linux-$LIBC-static"
STAGE="$WORK_DIR/stage-$ARCH"
PKG_ROOT="$WORK_DIR/pkg"

rm -rf "$STAGE"
install -d "$STAGE"
make install DESTDIR="$STAGE" >/dev/null

PREFIX_DIR="$STAGE/usr/local/nginx"
[ -x "$PREFIX_DIR/sbin/nginx" ] || die "make install did not install sbin/nginx"

# nginx does not create these on startup
for d in logs client_body_temp proxy_temp fastcgi_temp uwsgi_temp scgi_temp; do
    install -d "$PREFIX_DIR/$d"
done

"$STRIP" -s "$PREFIX_DIR/sbin/nginx"

CONF_ARGS="$(sed -n 's/^#define NGX_CONFIGURE "\(.*\)"/\1/p' objs/ngx_auto_config.h)"

{
    echo "nginx:      $NGINX_VERSION"
    echo "target:     $MACHINE / linux / $LIBC / statically linked"
    echo "toolchain:  $("$CC" --version | head -n 1)"
    echo "pcre2:      $PCRE2_VERSION (static)"
    echo "zlib:       $ZLIB_VERSION (static)"
    if [ "$WITH_OPENSSL" = "1" ]; then
        echo "openssl:    $OPENSSL_VERSION (static, $OPENSSL_TARGET)"
    else
        echo "openssl:    disabled"
    fi
    echo "configure:  $CONF_ARGS"
    echo
    echo "run with:   ./sbin/nginx -p \"\$PWD\" -c conf/nginx.conf -g 'daemon off;'"
    echo
    if [ "$RUNNABLE" = "1" ]; then
        echo "nginx -V:"
        "$BIN" -V 2>&1
    fi
} > "$PREFIX_DIR/BUILD-INFO.txt"

cp "$SRC_DIR/LICENSE" "$PREFIX_DIR/LICENSE"

rm -rf "$PKG_ROOT/$PKG_NAME"
install -d "$PKG_ROOT"
mv "$PREFIX_DIR" "$PKG_ROOT/$PKG_NAME"
rm -rf "$STAGE"

(
    cd "$PKG_ROOT"
    tar -czf "$OUT_DIR/$PKG_NAME.tar.gz" "$PKG_NAME"
)

(
    cd "$OUT_DIR"
    sha256sum "$PKG_NAME.tar.gz" > "$PKG_NAME.tar.gz.sha256"
)

file "$PKG_ROOT/$PKG_NAME/sbin/nginx" || true

log "artifact: $OUT_DIR/$PKG_NAME.tar.gz"
ls -l "$OUT_DIR"
