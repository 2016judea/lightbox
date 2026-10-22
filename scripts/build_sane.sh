#!/bin/bash
# Builds the GL128 SANE backend (cschalle/OpticFilm8200i-sane, LGPL-2.1) and
# scanimage into vendor/sane. The OpticFilm 8200i with USB id 07b3:1825 is a
# GL128 unit; Homebrew's sane-backends 1.4.0 does not recognise it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN=bcaa717cda4dab46e432a6cb04a51afc67469cdf
SRC="$ROOT/vendor/OpticFilm8200i-sane"
# Outside ~/Desktop: macOS blocks an app from loading binaries there until the user consents.
PREFIX="${LIGHTBOX_SANE:-$HOME/Library/Lightbox/sane}"
brew list autoconf automake libtool libusb pkgconf gettext autoconf-archive >/dev/null 2>&1 \
  || brew install autoconf automake libtool libusb pkgconf gettext autoconf-archive
[ -d "$SRC" ] || git clone https://github.com/cschalle/OpticFilm8200i-sane.git "$SRC"
git -C "$SRC" checkout -q "$PIN"
cd "$SRC/backends"
export PATH="/opt/homebrew/opt/gettext/bin:$PATH"
echo 1.4.0 > .tarball-version   # otherwise V_MINOR is empty and the backend won't compile
./autogen.sh >/dev/null
BACKENDS="plustek8200i genesys" ./configure --prefix="$PREFIX" --disable-static \
  --disable-preload --with-usb=yes --without-avahi --without-libcurl \
  --without-poppler-glib --without-snmp --disable-locking \
  CPPFLAGS="-I/opt/homebrew/include" LDFLAGS="-L/opt/homebrew/lib" >/dev/null
make clean >/dev/null 2>&1 || true
# the doc/ subdir fails on a missing umax html; the libraries and frontend do not need it
make -j8 -k >/dev/null 2>&1 || true
[ -x frontend/scanimage ] || { echo "scanimage did not build"; exit 1; }
make -C backend install >/dev/null; make -C frontend install >/dev/null; make -C include install >/dev/null || true
mkdir -p "$PREFIX/etc/sane.d"
cp backend/plustek8200i.conf "$PREFIX/etc/sane.d/"
echo plustek8200i > "$PREFIX/etc/sane.d/dll.conf"
SANE_CONFIG_DIR="$PREFIX/etc/sane.d" "$PREFIX/bin/scanimage" -L
