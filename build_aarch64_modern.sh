#!/bin/bash
# build_aarch64_modern.sh — cross-compile the modern GR + UHD toolchain for
# arm64-v8a into toolchain/arm64-v8a-modern/. Run inside a container of
# gnuradio-android:modern-r26 (Dockerfile.modern) with the repo root mounted.
# Builds the pinned submodules: UHD 4.10, libusb 1.0.29, GNU Radio 3.10.12.0
# (the uhd/gnuradio forks carry the fd-based USB init / UHD_IMAGES_DIR plus the
# android_shm vmcircbuf + spdlog logcat-sink patches).
#
# Scope = the android-iqrec recorder dependency set only: CMakeLists.txt links
# libgnuradio-{runtime,pmt,blocks,uhd} + libuhd. gr-ctrlport/thrift and the OOT
# modules (osmosdr/grand/sched/ieee802) are intentionally OUT of scope — not in
# the recorder's dependency set.
#
# Toolchain cascade: UHD 4.10 => Boost >= 1.71 => NDK r26 (std::filesystem) =>
# Boost 1.74 x clang-17 libc++ compat macros + patched Boost-for-Android +
# empty libpthread/librt stubs (Bionic folds pthread into libc).

set -xeo pipefail

#############################################################
### CONFIG
#############################################################
export BUILD_ROOT=$(dirname $(readlink -f "$0"))
export TOOLCHAIN_ROOT=${ANDROID_NDK_ROOT:?Dockerfile.modern must export ANDROID_NDK_ROOT}
export HOST_ARCH=linux-x86_64
export API_LEVEL=29                 # toolchain native API (SDK/app API set in Dockerfile.modern)
export ANDROID_ABI=arm64-v8a
export NCORES=$(getconf _NPROCESSORS_ONLN)

# SDK cmake 3.22.1 from Dockerfile.modern (NOT the distro cmake 4.x, which
# rejects cmake_minimum_required < 3.5 used by UHD/Boost sub-projects).
CMAKE_BIN="${ANDROID_SDK_CMAKE:?Dockerfile.modern must export ANDROID_SDK_CMAKE}/cmake"

#############################################################
### DERIVED CONFIG (NDK r26d clang toolchain)
#############################################################
export TOOLCHAIN_BIN=${TOOLCHAIN_ROOT}/toolchains/llvm/prebuilt/${HOST_ARCH}/bin
export SYS_ROOT=${TOOLCHAIN_ROOT}/toolchains/llvm/prebuilt/${HOST_ARCH}/sysroot
export CC="${TOOLCHAIN_BIN}/aarch64-linux-android${API_LEVEL}-clang"
export CXX="${TOOLCHAIN_BIN}/aarch64-linux-android${API_LEVEL}-clang++"
export AR=${TOOLCHAIN_BIN}/llvm-ar
export RANLIB=${TOOLCHAIN_BIN}/llvm-ranlib
export STRIP=${TOOLCHAIN_BIN}/llvm-strip
export LD=${TOOLCHAIN_BIN}/ld
export PATH=${TOOLCHAIN_BIN}:${ANDROID_SDK_CMAKE}:${PATH}

export PREFIX=${BUILD_ROOT}/toolchain/${ANDROID_ABI}-modern
export PKG_CONFIG_PATH=${PREFIX}/lib/pkgconfig
mkdir -p ${PREFIX}/lib ${PREFIX}/include

#############################################################
### S0 GUARDRAIL — refuse to ever write the green arm64-v8a/ tree
#############################################################
GREEN_TREE=${BUILD_ROOT}/toolchain/${ANDROID_ABI}
case "${PREFIX}" in
  *-modern) : ;;
  *) echo "S0 ABORT: PREFIX must be *-modern, got ${PREFIX}"; exit 99 ;;
esac
# Fingerprint the green tree (file list) so we can prove it was untouched.
s0_snapshot() { find "${GREEN_TREE}" -mindepth 1 2>/dev/null | sort; }
S0_BEFORE=$(s0_snapshot)
s0_assert_green_untouched() {
  { set +x; } 2>/dev/null    # silence set -x noise (snapshot is huge)
  local now; now=$(s0_snapshot)
  if [ "${now}" != "${S0_BEFORE}" ]; then
    echo "S0 ABORT: green tree ${GREEN_TREE} changed during build:"
    diff <(printf '%s\n' "${S0_BEFORE}") <(printf '%s\n' "${now}") | head
    exit 98
  fi
  set -x
}

#############################################################
### S0.5 PREFLIGHT — nested submodules must be populated
#############################################################
# A non-recursive clone leaves these dirs empty; without this guard the build
# dies deep in the Boost step with a cryptic "pathspec did not match" (the
# git checkout at line ~110 runs against an empty Boost-for-Android tree).
# Fail early and actionably instead. See docs/LESSONS.md "clone --recursive".
REQUIRED_SUBMODULES=(Boost-for-Android uhd gnuradio volk volk/cpu_features libusb fftw3 libgmp)
PREFLIGHT_MISSING=()
for sm in "${REQUIRED_SUBMODULES[@]}"; do
  # an uninitialized submodule dir has no checked-out tree (empty)
  if [ -z "$(ls -A "${BUILD_ROOT}/${sm}" 2>/dev/null)" ]; then
    PREFLIGHT_MISSING+=("${sm}")
  fi
done
if [ ${#PREFLIGHT_MISSING[@]} -ne 0 ]; then
  { set +x; } 2>/dev/null
  echo "PREFLIGHT ABORT: nested submodule(s) not populated: ${PREFLIGHT_MISSING[*]}"
  echo "  Fix: from the meta-repo root, run"
  echo "    git submodule update --init --recursive"
  echo "  (or re-clone with 'git clone --recursive ...'). See docs/LESSONS.md."
  exit 97
fi

# Boost-1.74 x clang-17 libc++ removed-feature compat macros — applied to
# every C++ component that includes Boost headers.
export LIBCXX_COMPAT="-D_LIBCPP_ENABLE_CXX17_REMOVED_FEATURES \
-D_LIBCPP_ENABLE_CXX20_REMOVED_FEATURES \
-D_LIBCPP_ENABLE_CXX17_REMOVED_UNARY_BINARY_FUNCTION \
-Wno-enum-constexpr-conversion -Wno-deprecated-declarations \
-Wno-deprecated-builtins"

CM_COMMON=(
  -G "Unix Makefiles"
  -DCMAKE_TOOLCHAIN_FILE=${TOOLCHAIN_ROOT}/build/cmake/android.toolchain.cmake
  -DANDROID_ABI=${ANDROID_ABI}
  -DANDROID_ARM_NEON=ON
  -DANDROID_PLATFORM=android-${API_LEVEL}
  -DANDROID_STL=c++_shared
  -DCMAKE_INSTALL_PREFIX=${PREFIX}
  -DCMAKE_FIND_ROOT_PATH=${PREFIX}
  -DCMAKE_PREFIX_PATH=${PREFIX}
)

#############################################################
### Bionic stubs: empty libpthread.a / librt.a (pthread is in libc)
#############################################################
for stub in libpthread.a librt.a; do
  if [ ! -f "${SYS_ROOT}/usr/lib/aarch64-linux-android/${stub}" ]; then
    "${AR}" rcs "${SYS_ROOT}/usr/lib/aarch64-linux-android/${stub}" 2>/dev/null || \
    "${AR}" rcs "${PREFIX}/lib/${stub}"
  fi
done

#############################################################
### BOOST 1.74 (Boost-for-Android fork @ b2xx-android: the download-URL,
### NDK-26 whitelist, llvm-ar/ranlib and clang-17 jam patches are commits
### in the submodule now, not build-time edits)
#############################################################
cd ${BUILD_ROOT}/Boost-for-Android
git clean -xdf

# Fail fast if this checkout is an unpatched pin (pre-b2xx-android master,
# or a bad bump): the patched markers must already be present.
grep -q 'archives.boost.io' build-android.sh || {
  echo "FATAL: Boost-for-Android lacks the b2xx-android patches (build-android.sh — wrong pin?)" >&2
  exit 1
}
grep -q 'llvm-ranlib' configs/user-config-ndk19-1_74_0-common.jam || {
  echo "FATAL: Boost-for-Android lacks the b2xx-android patches (common.jam — wrong pin?)" >&2
  exit 1
}

# Boost 1.74.0 source tarball pin — sha256 of boost_1_74_0.tar.bz2 as
# published at archives.boost.io/release/1.74.0/source/ (the URL
# build-android.sh fetches). Asserted below before extraction, on both the
# cache-hit and fresh-download paths.
BOOST_SHA256=83bfc1507731a0906e387fc28b7ef5417d591429e51e788417fe9ff025e116b1

# Offline-safe: if a pre-staged known-good tarball is mounted at
# BOOST_TARBALL_CACHE, drop it in place so build-android.sh's
# `[ ! -f $BOOST_TAR ]` skips the network entirely.
BOOST_TARBALL_CACHE=${BOOST_TARBALL_CACHE:-/opt/boost-cache/boost_1_74_0.tar.bz2}
if [ -s "${BOOST_TARBALL_CACHE}" ]; then
  cp -f "${BOOST_TARBALL_CACHE}" boost_1_74_0.tar.bz2
  echo "boost tarball: using cache ${BOOST_TARBALL_CACHE}"
fi

# Boost-for-Android installs to <--prefix>/<--arch>. <--arch> MUST be a
# recognised ABI (arm64-v8a) — it cannot be "arm64-v8a-modern" — so
# pointing --prefix at toolchain/ would write the GREEN tree
# (toolchain/arm64-v8a/). Instead stage into a dir OUTSIDE toolchain/,
# then relocate the boost-1_74 include + libboost_* into PREFIX. Resumable:
# skip the whole ~15-min Boost build if it is already in PREFIX.
BOOST_STAGE=${BUILD_ROOT}/_boost_stage_modern   # NOT under toolchain/
if [ ! -d "${PREFIX}/include/boost-1_74" ]; then
  rm -rf "${BOOST_STAGE}"
  mkdir -p "${BOOST_STAGE}"
  # Integrity gate (same fail-fast pattern as the spdlog SHA assert below):
  # make sure the exact tarball build-android.sh will extract is already
  # present here — the cache copy above, else fetch the same URL the script
  # would — then assert its sha256 against the pin BEFORE any extraction
  # (`[ ! -f $BOOST_TAR ]` then skips build-android.sh's own download).
  if [ ! -s boost_1_74_0.tar.bz2 ]; then
    curl -fL --retry 3 -o boost_1_74_0.tar.bz2 \
      "https://archives.boost.io/release/1.74.0/source/boost_1_74_0.tar.bz2"
  fi
  got_boost_sha=$(sha256sum boost_1_74_0.tar.bz2 | awk '{print $1}')
  if [ "${got_boost_sha}" != "${BOOST_SHA256}" ]; then
    echo "FATAL: boost_1_74_0.tar.bz2 sha256 ${got_boost_sha} != pinned ${BOOST_SHA256} (corrupt/tampered download or cache?)" >&2
    exit 1
  fi
  # bootstrap builds the b2 engine with the HOST compiler and derives the
  # NDK CXXPATH itself; our exported cross CC/CXX/AR/... must NOT leak in
  # (else b2 is cross-built for aarch64 -> "Exec format error").
  env -u CC -u CXX -u AR -u RANLIB -u STRIP -u LD -u CPPFLAGS -u LDFLAGS \
    ./build-android.sh --boost=1.74.0 --toolchain=llvm \
    --prefix="${BOOST_STAGE}" --arch=${ANDROID_ABI} \
    --target-version=${API_LEVEL} ${TOOLCHAIN_ROOT}
  cp -a "${BOOST_STAGE}/${ANDROID_ABI}/include/boost-1_74" "${PREFIX}/include/"
  cp -a "${BOOST_STAGE}/${ANDROID_ABI}/lib/." "${PREFIX}/lib/"
  rm -rf "${BOOST_STAGE}"
else
  echo "boost: ${PREFIX}/include/boost-1_74 present — skipping rebuild"
fi
s0_assert_green_untouched
export BOOST_ROOT=${PREFIX}
export BOOST_INCLUDEDIR=${PREFIX}/include/boost-1_74

BOOST_CM=(
  -DBOOST_ROOT=${PREFIX}
  -DBoost_INCLUDE_DIR=${PREFIX}/include/boost-1_74
  -DBoost_DEBUG=OFF -DBoost_COMPILER=-clang
  -DBoost_USE_STATIC_LIBS=ON -DBoost_USE_DEBUG_LIBS=OFF
  -DBoost_ARCHITECTURE=-a64
)

#############################################################
### FFTW3  (single/float/neon, static) — gr-fft / gr-blocks
#############################################################
if [ ! -f "${PREFIX}/lib/libfftw3f.a" ]; then
  cd ${BUILD_ROOT}/fftw3
  git clean -xdf
  # --with-pic so libfftw3f.a relocates into libgnuradio-fft.so on
  # aarch64 (else: R_AARCH64_ADR_PREL_PG_HI21 cannot be used against
  # symbol 'fftwf_dimcmp'; recompile with -fPIC).
  ./configure --enable-single --enable-static --enable-threads \
    --enable-float --enable-neon --disable-doc --with-pic \
    --host=aarch64-linux-android --prefix=${PREFIX} \
    CC="${CC}" AR="${AR}" RANLIB="${RANLIB}"
  make -j ${NCORES}
  make install
else echo "fftw3: present — skipping"; fi
s0_assert_green_untouched

#############################################################
### spdlog (+ bundled fmt) — gr-runtime find_package(spdlog CONFIG)
#############################################################
if [ ! -f "${PREFIX}/lib/libspdlog.a" ]; then
  # spdlog is pinned by the IMMUTABLE commit SHA, not the (movable) tag. The tag
  # is only the fetch handle for a fast shallow clone; we then assert HEAD is the
  # exact pinned commit and fail loudly if v1.12.0 was ever moved/retagged.
  # SHA == tag v1.12.0.
  SPDLOG_TAG=v1.12.0
  SPDLOG_SHA=7e635fca68d014934b4af8a1cf874f63989352b7
  cd ${BUILD_ROOT}
  [ -d spdlog ] || git clone --depth 1 --branch ${SPDLOG_TAG} https://github.com/gabime/spdlog.git
  cd spdlog
  got_sha=$(git rev-parse HEAD)
  if [ "${got_sha}" != "${SPDLOG_SHA}" ]; then
    echo "FATAL: spdlog HEAD ${got_sha} != pinned ${SPDLOG_SHA} (tag ${SPDLOG_TAG} moved/retagged?)" >&2
    exit 1
  fi
  git clean -xdf
  mkdir -p build && cd build
  "${CMAKE_BIN}" "${CM_COMMON[@]}" \
    -DCMAKE_CXX_FLAGS="${LIBCXX_COMPAT}" \
    -DSPDLOG_BUILD_SHARED=OFF -DSPDLOG_FMT_EXTERNAL=OFF \
    -DSPDLOG_BUILD_EXAMPLE=OFF -DSPDLOG_BUILD_TESTS=OFF \
    ../
  make -j ${NCORES}
  make install
else echo "spdlog: present — skipping"; fi
s0_assert_green_untouched

#############################################################
### libusb 1.0.29  (pinned submodule; autotools cross-build)
#############################################################
if [ ! -f "${PREFIX}/lib/libusb-1.0.so" ]; then
  cd ${BUILD_ROOT}/libusb
  git clean -xdf
  ./bootstrap.sh
  mkdir -p build-modern && cd build-modern
  ../configure --host=aarch64-linux-android --prefix=${PREFIX} \
    --enable-shared --disable-udev \
    CC="${CC}" AR="${AR}" RANLIB="${RANLIB}"
  make -j ${NCORES}
  make install
else echo "libusb: present — skipping"; fi
s0_assert_green_untouched

#############################################################
### GMP — gnuradio-runtime MPLIB dep (GR_MPLIB_FOUND, hard for GR 3.10)
#############################################################
if [ ! -f "${PREFIX}/lib/libgmp.so" ] && [ ! -f "${PREFIX}/lib/libgmp.a" ]; then
  cd ${BUILD_ROOT}/libgmp
  git clean -xdf
  ./.bootstrap
  ./configure --enable-maintainer-mode --prefix=${PREFIX} \
              --host=aarch64-linux-android --enable-cxx \
              CC="${CC}" CXX="${CXX}" AR="${AR}" RANLIB="${RANLIB}"
  make -j ${NCORES}
  make install
else echo "gmp: present — skipping"; fi
s0_assert_green_untouched

#############################################################
### VOLK
#############################################################
if [ ! -e "${PREFIX}/include/volk/volk.h" ]; then
  cd ${BUILD_ROOT}/volk
  git clean -xdf
  # GRAFT (toolchain, like the Boost-for-Android patches): old VOLK's
  # build-time self-check `sys.version.split()[0] >= '3.4'` is a
  # LEXICOGRAPHIC string compare — fails on Python >=3.10 (container is
  # 3.14: '3.14.4' >= '3.4' is False). Repair to a numeric tuple compare.
  # Idempotent: restore tracked source first.
  git checkout -- CMakeLists.txt
  python3 - CMakeLists.txt <<'PYVOLK'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("sys.version.split()[0] >= '3.4'",
              "sys.version_info[:2] >= (3,4)")
open(p, "w").write(s)
print("volk python-check patched OK")
PYVOLK
  # Sanity echo only — VOLK >=2.5 already ships a correct version_info
  # check (form varies: `sys.version_info[:2] >= (3,4)` vs
  # `sys.version_info >= (3, 4)`); either is fine. Don't trip set -e.
  grep -nE "sys\.version_info" CMakeLists.txt | head -1 || true
  mkdir -p build && cd build
  "${CMAKE_BIN}" "${CM_COMMON[@]}" "${BOOST_CM[@]}" \
    -DCMAKE_CXX_FLAGS="${LIBCXX_COMPAT}" \
    -DPYTHON_EXECUTABLE=/usr/bin/python3 \
    -DENABLE_STATIC_LIBS=ON -DENABLE_MODTOOL=OFF -DENABLE_TESTING=OFF \
    ../
  make -j ${NCORES}
  make install
else echo "volk: present — skipping"; fi
s0_assert_green_untouched

#############################################################
### UHD 4.10  (fd-based USB init fork; recorder dependency)
#############################################################
if [ ! -f "${PREFIX}/lib/libuhd.so" ]; then
  cd ${BUILD_ROOT}/uhd/host
  git clean -xdf
  mkdir -p build && cd build
  # The UHD fork's log.cpp calls __android_log_print but its CMake doesn't add
  # the liblog link dep — bridge with -llog here (NDK liblog is always present).
  "${CMAKE_BIN}" "${CM_COMMON[@]}" "${BOOST_CM[@]}" \
    -DCMAKE_SHARED_LINKER_FLAGS=-llog -DCMAKE_EXE_LINKER_FLAGS=-llog \
    -DCMAKE_CXX_FLAGS="${LIBCXX_COMPAT}" \
    -DLIBUSB_INCLUDE_DIRS=${PREFIX}/include/libusb-1.0 \
    -DLIBUSB_LIBRARIES=${PREFIX}/lib/libusb-1.0.so \
    -DENABLE_STATIC_LIBS=OFF -DENABLE_EXAMPLES=OFF -DENABLE_TESTS=OFF \
    -DENABLE_UTILS=OFF -DENABLE_PYTHON_API=OFF -DENABLE_MANUAL=OFF \
    -DENABLE_DOXYGEN=OFF -DENABLE_MAN_PAGES=OFF -DENABLE_OCTOCLOCK=OFF \
    -DENABLE_E300=OFF -DENABLE_E320=OFF -DENABLE_N300=OFF -DENABLE_N320=OFF \
    -DENABLE_X300=OFF -DENABLE_USRP2=OFF -DENABLE_N230=OFF -DENABLE_MPMD=OFF \
    -DENABLE_B100=OFF -DENABLE_USRP1=OFF -DENABLE_X400=OFF \
    ../
  make -j ${NCORES}
  make install
else echo "uhd: present — skipping"; fi
s0_assert_green_untouched

#############################################################
### GNU Radio 3.10.12.0  (android_shm vmcircbuf + spdlog android_sink fork)
###   recorder set only: runtime/pmt/blocks/fft/uhd/analog
#############################################################
if [ ! -f "${PREFIX}/lib/libgnuradio-runtime.so" ]; then
  cd ${BUILD_ROOT}/gnuradio
  git clean -xdf
  mkdir -p build && cd build
  # The gnuradio fork adds a spdlog android_sink -> logcat; same -llog bridge
  # as UHD above.
  # GR 3.10's common-precompiled-headers target links only spdlog (not
  # Boost::headers) but logger.h #includes <boost/format.hpp> -> PCH
  # compile fails. Inject Boost includes globally via -isystem so the
  # PCH (and every TU) sees them regardless of per-target wiring.
  # The fork's vmcircbuf_android_shm.cc calls ASharedMemory_create from
  # libandroid (NDK API 26+) -> add -landroid to the link alongside -llog.
  "${CMAKE_BIN}" "${CM_COMMON[@]}" "${BOOST_CM[@]}" \
    -DCMAKE_SHARED_LINKER_FLAGS="-llog -landroid" \
    -DCMAKE_EXE_LINKER_FLAGS="-llog -landroid" \
    -DCMAKE_CXX_FLAGS="${LIBCXX_COMPAT} -isystem ${PREFIX}/include/boost-1_74" \
    -DPYTHON_EXECUTABLE=/usr/bin/python3 \
    -DENABLE_INTERNAL_VOLK=OFF \
    -Dspdlog_DIR=${PREFIX}/lib/cmake/spdlog \
    -DENABLE_DOXYGEN=OFF -DENABLE_SPHINX=OFF -DENABLE_PYTHON=OFF \
    -DENABLE_TESTING=OFF -DENABLE_GR_CTRLPORT=OFF \
    -DENABLE_GNURADIO_RUNTIME=ON -DENABLE_GR_BLOCKS=ON -DENABLE_GR_FFT=ON \
    -DENABLE_GR_UHD=ON -DENABLE_GR_ANALOG=ON -DENABLE_GR_FILTER=ON \
    -DENABLE_GR_FEC=OFF -DENABLE_GR_AUDIO=OFF -DENABLE_GR_DTV=OFF \
    -DENABLE_GR_CHANNELS=OFF -DENABLE_GR_VOCODER=OFF -DENABLE_GR_TRELLIS=OFF \
    -DENABLE_GR_WAVELET=OFF -DENABLE_GR_DIGITAL=OFF -DENABLE_GR_NETWORK=OFF \
    -DENABLE_GR_QTGUI=OFF -DENABLE_GR_ZEROMQ=OFF -DENABLE_GR_VIDEO_SDL=OFF \
    -DENABLE_GR_PDU=OFF -DENABLE_GR_SOAPY=OFF \
    ../
  make -j ${NCORES}
  make install
else echo "gnuradio: present — skipping"; fi
s0_assert_green_untouched

#############################################################
### jniLibs staging — PARALLEL jni-modern (NEVER touch the old jni/ which
### symlinks into arm64-v8a/lib; that would break A/B + S0). The recorder's
### `iqrecModern` build points jniLibs.srcDirs at toolchain/jni-modern.
#############################################################
# r26 ships libc++_shared.so in the NDK sysroot (no cxx-stl tree) — stage
# it into the modern lib dir so a single jni-modern srcDir is sufficient.
cp -f ${SYS_ROOT}/usr/lib/aarch64-linux-android/libc++_shared.so \
      ${PREFIX}/lib/ 2>/dev/null || true
mkdir -p ${BUILD_ROOT}/toolchain/jni-modern
ln -sfn ../${ANDROID_ABI}-modern/lib \
        ${BUILD_ROOT}/toolchain/jni-modern/${ANDROID_ABI}

s0_assert_green_untouched
echo "=== build_aarch64_modern.sh COMPLETE — toolchain/${ANDROID_ABI}-modern/ populated ==="
ls -la ${PREFIX}/lib/libgnuradio-runtime.so ${PREFIX}/lib/libuhd.so \
       ${PREFIX}/lib/libgnuradio-uhd.so 2>/dev/null || true
