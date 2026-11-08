# Building spotifyd for ARMv6 (Raspberry Pi Zero / Zero W)

Upstream spotifyd ships prebuilt ARMv6 binaries **only up to v0.3.5** (see `cd.yml`
history: the `linux-armv6` build target was dropped afterwards). This document
describes how to build current spotifyd (v0.4.2 here) for ARMv6 hard-float Linux
(ARM1176JZF-S, e.g. Raspberry Pi Zero W, Raspbian/Raspberry Pi OS 11 "bullseye",
glibc 2.31) by cross-compiling from a modern x86_64 Linux host.

Validated end-to-end on 2026-11-07: binary runs on a Pi Zero W (Raspbian 11,
kernel 6.1.21+, glibc 2.31), plays via ALSA S32 @ 320 kbit/s.

---

## 1. Source changes required

### 1.1 Remove the `aws-lc-rs` target dependency (only change to the tree)

`Cargo.toml` contains:

```toml
[target.'cfg(not(any(target_arch = "aarch64", target_arch = "x86_64")))'.dependencies]
aws-lc-rs = { version = "1.12.6", features = ["bindgen"] }
```

`aws-lc-sys` refuses to build for any 32-bit ARM Rust target
(`panicked ... "Platform not supported: arm-unknown-linux-gnueabihf"`).
This dependency is **dead weight** for the ALSA-only build: the TLS stack used by
`librespot-core` in v0.4.2 is `native-tls` → OpenSSL (`hyper-tls`,
`tokio-tungstenite`), and neither `Cargo.lock`'s rustls graph nor `src/`
references aws-lc. Delete the whole `[target.'cfg(not(...))']` section and
re-lock:

```bash
# edit Cargo.toml: delete the 2-line target section above
cargo update -p spotifyd --offline 2>/dev/null || cargo metadata >/dev/null  # regenerates Cargo.lock without aws-lc*
```

Resulting diff: `Cargo.toml` (-2 lines) and `Cargo.lock` (aws-lc-fips-sys,
aws-lc-rs, aws-lc-sys entries removed). No Rust source changes are needed.

### 1.2 Build without the default features

The default feature set (`pulseaudio_backend`, `dbus_mpris`) pulls in PulseAudio
and dbus; the Pi Zero service runs ALSA-only (mirroring the old upstream
`linux-armv6-slim` asset, which was `--no-default-features --features alsa_backend`).

---

## 2. Host toolchain (x86_64 Ubuntu/Debian)

```bash
# Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
~/.cargo/bin/rustup target add arm-unknown-linux-gnueabihf

# Cross C toolchain + pkg-config
sudo apt-get install gcc-arm-linux-gnueabihf pkg-config
```

> **Host glibc must not be newer than the target's.** Ubuntu 26.04 (glibc 2.43)
> building for Bullseye (glibc 2.31) works, but **only** after the two
> workarounds in §4.1 and §4.2 — by default the host toolchain's own modern
> glibc leaks into the link and produces binaries that SIGSEGV / report
> `version GLIBC_2.34 not found` on the device.

## 3. Target sysroot

The final link must use the *device's* libc/headers, not the host's. On the Pi
install the dev files once:

```bash
sudo apt-get install libasound2-dev libssl-dev libc6-dev gcc
```

Then copy them to the host (`rsync` is often absent on small Pi images; `tar`
always works):

```bash
ssh pi@<pi> 'tar cf - /usr/include /usr/lib/arm-linux-gnueabihf \
    /usr/lib/pkgconfig /usr/lib/ssl /lib/arm-linux-gnueabihf /usr/share/alsa \
    /usr/lib/gcc/arm-linux-gnueabihf | gzip -1' > sysroot.tgz   # ~90 MB
mkdir -p ~/pi-sysroot && tar xzf sysroot.tgz -C ~/pi-sysroot
```

Two sysroot fixups are **mandatory**:

1. **Rewrite absolute symlinks.** Debian's dev symlinks point at absolute
   device paths (`libpthread.so -> /lib/arm-linux-gnueabihf/libpthread.so.0`).
   Dangling inside the host sysroot, the linker silently falls back to static
   libs → `undefined reference to _dl_pagesize`. Rewrite them relative:

   ```bash
   python3 - <<'EOF'
   import os
   SYS = os.path.expanduser('~/pi-sysroot')
   for root in ('usr/lib/arm-linux-gnueabihf', 'lib/arm-linux-gnueabihf'):
       d = os.path.join(SYS, root)
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
   ```

2. **Provide the loader at `/lib` inside the sysroot** (Rust's std refers to
   the dynamic linker by its canonical path):

   ```bash
   ln -sfn ../usr/lib/arm-linux-gnueabihf/ld-linux-armhf.so.3 ~/pi-sysroot/lib/ld-linux-armhf.so.3
   ```

## 4. Cross-build

### 4.1 Hide the host toolchain's bundled glibc

Ubuntu's `gcc-arm-linux-gnueabihf` ships a complete modern armhf glibc at
`/usr/arm-linux-gnueabihf/{,usr/}lib`. It wins the linker's library search even
when `--sysroot` is given, and the resulting binary demands
`GLIBC_2.32/2.33/2.34` → broken on Bullseye. Move it aside:

```bash
sudo mv /usr/arm-linux-gnueabihf/lib     /usr/arm-linux-gnueabihf/lib.hide_me
sudo mv /usr/arm-linux-gnueabihf/usr/lib /usr/arm-linux-gnueabihf/usr/lib.hide_me
```

### 4.2 Use the *device's* gcc crt objects

`crtbegin.o`/`crtend(S).o` from the host gcc (compiled against a new glibc)
re-introduce the same versioned-symbol leak. Extract the device's own:

```bash
sshpass -e scp 'pi@<pi>:/usr/lib/gcc/arm-linux-gnueabihf/10/crtbegin*.o' \
               'pi@<pi>:/usr/lib/gcc/arm-linux-gnueabihf/10/crtend*.o' ~/pi-crt/
```

Pass them with `-B` — **never** `-B` at the full gcc directory: that would also
shadow `collect2` (ARM binary on x86 host → `Exec format error`).

### 4.3 The build itself

A ready-made script is in [`contrib/build_armv6_cross.sh`](contrib/build_armv6_cross.sh).
Equivalent manual invocation:

```bash
SYS=~/pi-sysroot
export CC_arm_unknown_linux_gnueabihf=arm-linux-gnueabihf-gcc
export CFLAGS_arm_unknown_linux_gnueabihf="-march=armv6 -mfpu=vfp -mfloat-abi=hard --sysroot=$SYS"
export RUSTFLAGS="-C linker=arm-linux-gnueabihf-gcc -C link-arg=--sysroot=$SYS -C link-arg=-B$HOME/pi-crt -C link-arg=-Wl,-rpath-link=$SYS/usr/lib/arm-linux-gnueabihf"
export PKG_CONFIG_ALLOW_CROSS=1 PKG_CONFIG_SYSROOT_DIR=$SYS
export PKG_CONFIG_LIBDIR=$SYS/usr/lib/arm-linux-gnueabihf/pkgconfig:$SYS/usr/lib/pkgconfig
export OPENSSL_INCLUDE_DIR=$SYS/usr/include
export OPENSSL_LIB_DIR=$SYS/usr/lib/arm-linux-gnueabihf

cargo build --release --target arm-unknown-linux-gnueabihf \
    --no-default-features --features alsa_backend
# → target/arm-unknown-linux-gnueabihf/release/spotifyd
```

Notes:

* The Rust target `arm-unknown-linux-gnueabihf` **is already ARMv6-baseline**
  (`features: +strict-align,+v6,+vfp2`; its metadata literally says "Armv6
  Linux, hardfloat"). There is no `armv6-unknown-linux-gnueabihf` target and no
  need for nightly/`-Zbuild-std` or a custom target JSON.
* `-C target-cpu=arm1176jzf-s` is accepted but does not downgrade the triple's
  baseline features — don't rely on it either way; the baseline is correct.

## 5. Validate before deploying

```bash
B=target/arm-unknown-linux-gnueabihf/release/spotifyd
# glibc requirement must be <= the device's (Bullseye = 2.31)
arm-linux-gnueabihf-readelf -V $B | grep -oE 'GLIBC_2\.[0-9]+' | sort -uV | tail -2
# must print 0 (true ARMv7-only instructions; vldmia/vstmia {d0-d15} are VFPv2-legal!)
arm-linux-gnueabihf-objdump -d $B | grep -cE '\b(sdiv|udiv|bfi|ldrexd|strexd)\b'
# smoke test on the device
scp $B pi@<pi>:/tmp/ && ssh pi@<pi> '/tmp/spotifyd --version'
```

Iterate quickly with a one-line `hello.rs` built via `rustc --target ...` with
the same flags (note: plain `rustc` does **not** read `RUSTFLAGS`; pass flags as
arguments) — 30 s feedback instead of 5 min.

## 6. Packaging & installation on a device

Pack exactly like the old upstream `linux-armv6-slim` asset (binary named
`spotifyd`, single file in tarball):

```bash
cd target/arm-unknown-linux-gnueabihf/release
tar czvf spotifyd-linux-armv6-slim.tar.gz spotifyd
sha512sum spotifyd-linux-armv6-slim.tar.gz > spotifyd-linux-armv6-slim.sha512
```

Install (system service, ALSA):

```bash
sudo systemctl stop spotifyd
sudo cp spotifyd /home/pi/spotifyd        # or your ExecStart path
sudo systemctl start spotifyd
```

Example unit: [`contrib/spotifyd-armv6.service`](contrib/spotifyd-armv6.service)
(hardened restart limits; the daemon may exit after transient connection errors,
so a plain `Restart=always` with a generous burst is important on flaky networks).

## 7. Why v0.4.x at all (if v0.3.5 "works")

On a Pi Zero W, v0.3.5 (librespot 0.4) reproduced `subscription terminated` /
`Connection reset by peer` stream drops several times per day, after which
playback silently died. v0.4.2 bundles librespot 0.8, which includes the audio
CDN URL fallback ("Fall back to other URLs in case of a failure when
downloading from CDN", librespot#1589-era) and substantially reworked
connect/dealer session handling — the same symptom class the upstream issue
tracker accumulated for 0.3.x.

## 8. Known caveats

* Discovery (zeroconf) mode works; with credentials, v0.4.x prefers OAuth
  (`--login`) — the legacy username/password path still works with
  `spotifyd.conf` `username`/`password` as before.
* `dbus_mpris` is not buildable for 32-bit ARM with the era-matched toolchain
  (same reason upstream excluded `default`/`full` armv6 artifacts in their CI);
  ALSA-only "slim" is the supported shape.
* The host workaround (`/usr/arm-linux-gnueabihf/...lib.hide_me`) is global to
  the host. Restore the names when building armv7+ or native-armhf packages
  with the same host toolchain.
