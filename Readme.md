# GNU Radio + UHD Android Toolchain (arm64-v8a)

A Docker-based cross-compile toolchain that builds GNU Radio 3.10 and UHD 4.10
(plus their dependency stack) as Android `arm64-v8a` shared libraries, for
driving USB SDRs — in particular the Ettus B2xx series — from Android apps.

This is a fork of [bastibl/gnuradio-android](https://github.com/bastibl/gnuradio-android)
(which targets GNU Radio 3.8). This branch modernizes the chain — NDK r26,
JDK 17 / SDK 35-era tooling, current component pins — built by
`build_aarch64_modern.sh` inside the `docker/Dockerfile.modern` image.

## What gets built

| Component | Version | Source |
|---|---|---|
| GNU Radio | 3.10.12.0 | `gnuradio` submodule — `michaelnaw/gnuradio` fork (Android shared-memory circular buffer, spdlog logcat sink) |
| UHD | 4.10 | `uhd` submodule — `michaelnaw/uhd` fork (file-descriptor USB init, `UHD_IMAGES_DIR` handling) |
| libusb | 1.0.29 | `libusb` submodule — upstream `libusb/libusb` tag |
| VOLK | 3.3.0 | `volk` submodule — upstream `gnuradio/volk` tag |
| Boost | 1.74.0 | built via the `Boost-for-Android` submodule — patched `michaelnaw/Boost-for-Android` fork |
| spdlog | v1.12.0 | `gabime/spdlog`, cloned at build time and pinned to an immutable commit SHA |
| FFTW3 | single-precision, NEON, static | `fftw3` submodule (`michaelnaw/fftw-dist`) |
| GMP | — | `libgmp` submodule (`michaelnaw/libgmp`) |

Scope is deliberately minimal: `gnuradio-runtime`, `pmt`, `blocks`, `fft`,
`filter`, `analog`, and `gr-uhd`, plus `libuhd` — the dependency set of a UHD
streaming app. ControlPort/Thrift, Python bindings, and the upstream OOT
modules (osmosdr, grand, sched, ieee802-*) are intentionally out of scope;
their submodules remain in `.gitmodules` but are unused by the modern build.

The pins interlock: UHD 4.10 requires Boost >= 1.71, which requires NDK r26
(`std::filesystem`), which requires the Boost 1.74 x clang-17 libc++ compat
handling baked into the build script. Treat them as load-bearing.

## Cloning

`git clone --recursive` is **mandatory** — nested submodules such as
`volk/cpu_features` must be populated. The build script preflights
`Boost-for-Android`, `uhd`, `gnuradio`, `volk`, `volk/cpu_features`, `libusb`,
`fftw3`, and `libgmp`, and aborts early with a fix hint if any are empty. For
an existing clone: `git submodule update --init --recursive`.

## Building

The image (`docker/Dockerfile.modern`, Ubuntu 26.04 base) provides only the
build environment: NDK r26d (`26.3.11579264`), Android SDK cmake 3.22.1,
JDK 17, platform `android-35` + build-tools 35.0.0. Sources are bind-mounted
at run time, not baked into the image. The supported layout mounts the
**parent workspace directory** — the directory that contains this repository
as a subdirectory — at `/home/android/src`, the image's working directory
(the container user is UID/GID 1000, so bind-mount ownership matches a
default host user):

```shell
docker build -f docker/Dockerfile.modern -t gnuradio-android:modern-r26 docker
docker run -it --rm -v /path/to/your/workspace:/home/android/src \
    gnuradio-android:modern-r26
# inside the container (workdir /home/android/src):
./gnuradio-android/build_aarch64_modern.sh
```

Native code targets Android API level 29. Artifacts install into
`toolchain/arm64-v8a-modern/`, and `toolchain/jni-modern/` is staged as a
`jniLibs.srcDirs`-compatible layout (including `libc++_shared.so`) for
Android Studio projects.

## Legacy scripts

`build.sh`, `build_aarch64.sh`, and `docker/Dockerfile` are the upstream
GNU Radio 3.8-era toolchain, kept for reference; they are not maintained on
this branch.

## Credits

Forked from [bastibl/gnuradio-android](https://github.com/bastibl/gnuradio-android)
by Bastian Bloessl, which in turn builds on Tom Rondeau's earlier Android
port. See the upstream README and its accompanying WiNTECH'20 paper for
background on the original toolchain.
