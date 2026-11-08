#!/usr/bin/env bash
#
# Cross-compile spotifyd for ARMv6 hard-float Linux (Raspberry Pi Zero / Zero W).
# Run from the spotifyd source root on an x86_64 Debian/Ubuntu host.
#
# Prerequisites (see BUILD_ARMV6.md for the full rationale):
#   - rustup stable + `rustup target add arm-unknown-linux-gnueabihf`
#   - apt-get install gcc-arm-linux-gnueabihf pkg-config sshpass
#   - Cargo.toml: delete the [target.'cfg(not(any(aarch64, x86_64)))'] aws-lc-rs section
#   - On the device: apt-get install libasound2-dev libssl-dev libc6-dev gcc
#   - Host: hide the cross-toolchain's bundled modern glibc (see step [0] below)
#
# Usage: PI_HOST=192.168.1.10 PI_USER=pi [PI_PASS=...] ./contrib/build_armv6_cross.sh
set -euo pipefail

PI_HOST=${PI_HOST:?set PI_HOST to the Raspberry Pi's address}
PI_USER=${PI_USER:-pi}
SRC_ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-$HOME/armv6-build}
SYS=$WORK/pi-sysroot
CRT=$WORK/pi-crt
TARGET=arm-unknown-linux-gnueabihf

ssh_run() { if [ -n "${PI_PASS:-}" ]; then sshpass -e ssh -o StrictHostKeyChecking=accept-new "$PI_USER@$PI_HOST" "$@"; else ssh -o StrictHostKeyChecking=accept-new "$PI_USER@$PI_HOST" "$@"; fi; }
ssh_cp()  { if [ -n "${PI_PASS:-}" ]; then sshpass -e scp -o StrictHostKeyChecking=accept-new "$@"; else scp -o StrictHostKeyChecking=accept-new "$@"; fi; }

echo "== [0] host glibc isolation =========================================="
echo "Ensure the host cross-toolchain's bundled armhf glibc is hidden, or the"
echo "binary will demand GLIBC_2.32+ (fails on Bullseye-class devices):"
echo "  sudo mv /usr/arm-linux-gnueabihf/lib     /usr/arm-linux-gnueabihf/lib.hide_me"
echo "  sudo mv /usr/arm-linux-gnueabihf/usr/lib /usr/arm-linux-gnueabihf/usr/lib.hide_me"
if [ -e /usr/arm-linux-gnueabihf/lib/libc.so.6 ]; then
    echo "ERROR: /usr/arm-linux-gnueabihf/lib/libc.so.6 is still active. Do steps above, then rerun." >&2
    exit 1
fi

echo "== [1] device sysroot ================================================"
if [ ! -d "$SYS/usr/include" ]; then
    mkdir -p "$SYS"
    ssh_run 'tar cf - /usr/include /usr/lib/arm-linux-gnueabihf \
        /usr/lib/pkgconfig /usr/lib/ssl /lib/arm-linux-gnueabihf \
        /usr/share/alsa /usr/lib/gcc/arm-linux-gnueabihf 2>/dev/null | gzip -1' \
        | tar xz -C "$SYS"
fi

echo "== [2] sysroot fixups ================================================="
# rewrite absolute symlinks so the linker finds shared libs inside the sysroot
python3 - "$SYS" <<'EOF'
import os, sys
SYS = sys.argv[1]
for root in ('usr/lib/arm-linux-gnueabihf', 'lib/arm-linux-gnueabihf'):
    d = os.path.join(SYS, root)
    if not os.path.isdir(d):
        continue
    for f in os.listdir(d):
        p = os.path.join(d, f)
        if os.path.islink(p):
            tgt = os.readlink(p)
            if tgt.startswith('/'):
                mapped = os.path.join(SYS, tgt.lstrip('/'))
                if os.path.exists(mapped) or os.path.islink(mapped):
                    os.unlink(p)
                    os.symlink(os.path.relpath(mapped, d), p)
EOF
# Rust's std refers to the loader by canonical path
mkdir -p "$SYS/lib"
ln -sfn ../usr/lib/arm-linux-gnueabihf/ld-linux-armhf.so.3 "$SYS/lib/ld-linux-armhf.so.3"

echo "== [3] device crt objects ============================================="
mkdir -p "$CRT"
GCC_VER=$(ssh_run 'ls /usr/lib/gcc/arm-linux-gnueabihf | grep -E "^[0-9]+$" | sort -n | tail -1')
ssh_cp "$PI_USER@$PI_HOST:/usr/lib/gcc/arm-linux-gnueabihf/$GCC_VER/crtbegin*.o" \
       "$PI_USER@$PI_HOST:/usr/lib/gcc/arm-linux-gnueabihf/$GCC_VER/crtend*.o" "$CRT/"

echo "== [4] build ==========================================================="
if grep -q "aws-lc-rs" Cargo.toml; then
    echo "ERROR: Cargo.toml still has the aws-lc-rs target dependency (unsupported on 32-bit ARM)." >&2
    echo "       Delete the [target.'cfg(not(any(target_arch = \"aarch64\", target_arch = \"x86_64\")))']" >&2
    echo "       section, then rerun without --locked so Cargo.lock regenerates." >&2
    exit 1
fi
export PATH=$HOME/.cargo/bin:$PATH
export CC_arm_unknown_linux_gnueabihf=arm-linux-gnueabihf-gcc
export CXX_arm_unknown_linux_gnueabihf=arm-linux-gnueabihf-g++
export AR_arm_unknown_linux_gnueabihf=arm-linux-gnueabihf-ar
export CFLAGS_arm_unknown_linux_gnueabihf="-march=armv6 -mfpu=vfp -mfloat-abi=hard --sysroot=$SYS"
export RUSTFLAGS="-C linker=arm-linux-gnueabihf-gcc -C link-arg=--sysroot=$SYS -C link-arg=-B$CRT -C link-arg=-Wl,-rpath-link=$SYS/usr/lib/arm-linux-gnueabihf"
export PKG_CONFIG_ALLOW_CROSS=1
export PKG_CONFIG_SYSROOT_DIR=$SYS
export PKG_CONFIG_LIBDIR=$SYS/usr/lib/arm-linux-gnueabihf/pkgconfig:$SYS/usr/lib/pkgconfig
export OPENSSL_INCLUDE_DIR=$SYS/usr/include
export OPENSSL_LIB_DIR=$SYS/usr/lib/arm-linux-gnueabihf

cargo build --release --target "$TARGET" --no-default-features --features alsa_backend

BIN=target/$TARGET/release/spotifyd

echo "== [5] validate ========================================================"
echo "glibc versions required:"
arm-linux-gnueabihf-readelf -V "$BIN" | grep -oE 'GLIBC_2\.[0-9]+' | sort -uV | tail -3
N=$(arm-linux-gnueabihf-objdump -d "$BIN" | grep -cE '\b(sdiv|udiv|bfi|ldrexd|strexd)\b')
echo "ARMv7-only instruction count: $N (must be 0)"
[ "$N" -eq 0 ] || { echo "ERROR: binary would SIGILL on ARM1176 (Pi Zero)." >&2; exit 1; }

echo "== [6] package ========================================================="
cd target/$TARGET/release
tar czvf spotifyd-linux-armv6-slim.tar.gz spotifyd
sha512sum spotifyd-linux-armv6-slim.tar.gz > spotifyd-linux-armv6-slim.sha512
cd "$SRC_ROOT"
echo "Done: $SRC_ROOT/target/$TARGET/release/spotifyd-linux-armv6-slim.tar.gz"

echo "== [7] smoke test on device (optional) ================================="
ssh_cp "$SRC_ROOT/$BIN" "$PI_USER@$PI_HOST:/tmp/spotifyd-armv6-test"
ssh_run 'chmod +x /tmp/spotifyd-armv6-test && /tmp/spotifyd-armv6-test --version'
