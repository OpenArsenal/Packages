# Maintainer: Torsten Keßler <tpkessler@archlinux.org>
# Contributor: Gustavo Alvarez <sl1pkn07@gmail.com>
# Contributor: Chih-Hsuan Yen <yan12125@gmail.com>

pkgbase=onnxruntime
pkgname=(
  "${pkgbase}-cpu"
  "${pkgbase}-cuda"
  "${pkgbase}-opt-cuda"
  "${pkgbase}-rocm"
  "${pkgbase}-opt-rocm"
  "python-${pkgbase}-cpu"
  "python-${pkgbase}-cuda"
  "python-${pkgbase}-opt-cuda"
  "python-${pkgbase}-rocm"
  "python-${pkgbase}-opt-rocm"
)
pkgver=1.23.2
_pkgdesc='Cross-platform, high performance scoring engine for ML models'
pkgrel=4
arch=('x86_64')
url='https://github.com/microsoft/onnxruntime'
license=('MIT')
depends=('abseil-cpp' 'boost-libs')
# https://github.com/microsoft/onnxruntime/blob/main/onnxruntime/python/tools/transformers/requirements.txt
_pydepends=('python-numpy' 'python-coloredlogs' 'python-psutil'
            'python-py-cpuinfo' 'python-sympy' 'python-scipy' 'python-pillow'
            'python-flatbuffers' 'python-protobuf' 'python-packaging')
makedepends=('git' 'cmake' 'ninja' 'boost' 'pybind11' 'nlohmann-json' 'chrono-date' 'cxxopts'
             'python-setuptools' 'python-installer' 'python-wheel' 'python-build' 'onednn'
             'cuda' 'cudnn' 'nccl' 'rocm-toolchain' 'rocm-hip-sdk' 'hipify-clang' 'rocm-smi-lib' 'roctracer' 'migraphx')
makedepends+=("${_pydepends[@]}")
#TODO: Add tensorrt for CUDA.
source=("git+https://github.com/microsoft/onnxruntime#tag=v${pkgver}"
        "${pkgbase}-install-orttraining-files.patch"
        "${pkgbase}-system-dnnl.patch"
        "${pkgbase}-system-flatbuffers.patch"
        fix-gcc-15.patch
        deps-cutlass-4.2.0.patch
        fix-thrust-api.patch)
b2sums=('ba28fe6c0ee88f151c0df386c42155b5a70bf0593691c8584b7f8314de148f10b22d509a7b201a684233b7a3a01e5f07752121e40678fb8021e99270f769b6dd'
        'af5a5524dd9b5fe0052d2d0da232de7f219d4abffb37a7a321145b428d06fcb2901ab4e76b6754440146c223fc761bcbdfeee230167d33aa4434b82a1ebad5c0'
        '57c79382537f5bd25a891de3a99415a6dd8f490676df213016e897040c88e28fb5f5a5c3a8a98057e3f6630edb3ddcaeae36dcc47d5354abaafafc36e579f731'
        '207f020f310a7b447b4dc2fac74819f80099f088fdad6e42d67d0f01aa35bb5b9475bd006d9bec318127ae2db3d7ae3df33382fa16339d936c1dfb3832010837'
        'eda81fc2c2a9e9a241a1147cc470a90f437b559fac6c6c2da3d8d70b5e3492fcc98617aa3dbaec6d9548c7a370b3e825297f4ec98e2c067085dd5ef403340ee2'
        '33809e4c3e99c22e5f066c8cbaebcb9f9a6165104c86be5dba65148e9bc7af01ace6580c7607eb73767f1c5e1b159805726cfb8f7f67b763033e24c00c31770f'
        'b0b58e2eb42a38956ef9e86b853d413c2fd002737d37721962dd9e1fc5c39c1ef4594325c6f6081f2b4cdce39a14907dbebc156645fa25ff3f2bbbce6417cd14')

_valid_sm() {
  # Check PKGBUILDs of python-pytorch and tensorflow for CUDA architectures built by official packages
  echo "75-real;80-real;86-real;87-real;88-real;89-real;90-real;100-real;103-real;110-real;120-real;121-real;121-virtual"
}

_valid_gfx() {
  # gfx950 is not supported by rocPRIM
  echo "$(rocm-supported-gfx -e gfx950)"
}

prepare() {
  cd "${pkgbase}"

  patch -Np1 -i "${srcdir}/${pkgbase}-system-dnnl.patch"

  # Find system nlohmann-json
  sed 's|3.10 ||g' \
    -i cmake/external/onnxruntime_external_deps.cmake

  # Find system chrono-date
  sed -e 's|${DEP_SHA1_date}|&\n \ \ \ \ \ \FIND_PACKAGE_ARGS NAMES date|g' \
      -e 's|date_interface|date::date-tz|g' \
      -i cmake/external/onnxruntime_external_deps.cmake \
      -i cmake/onnxruntime_common.cmake \
      -i cmake/onnxruntime_unittests.cmake

  # Find system abseil-cpp
  sed 's|ABSL_PATCH_COMMAND}|&\n\ \ \ \ \FIND_PACKAGE_ARGS NAMES absl|g' \
    -i cmake/external/abseil-cpp.cmake

  # Find system cxxopts
  sed 's|${DEP_SHA1_cxxopts}|&\n\ \ \ \ \FIND_PACKAGE_ARGS NAMES cxxopts|g' \
    -i cmake/external/onnxruntime_external_deps.cmake

  patch -Np1 -i "${srcdir}/${pkgbase}-install-orttraining-files.patch"
  patch -Np1 -i "${srcdir}/${pkgbase}-system-flatbuffers.patch"

  # Fix build with abseil 20250814; see https://github.com/microsoft/onnxruntime/issues/25815
  sed -i '/^absl::low_level_hash$/d' cmake/external/abseil-cpp.cmake

  # Fix build with GCC 15
  patch -p1 -i "${srcdir}/fix-gcc-15.patch"
  # https://github.com/microsoft/onnxruntime/pull/25658
  git cherry-pick -n d6e712c5b7b6260a61e54d1fe40107cf5366ee77

  # Update deprecated CCCL API (#25246)
  git cherry-pick -n a2bd54bc8c59562428f6b09d3f64f9e735599cd4
  # [CUDA] Upgrade cutlass to 3.9.2 (#24794)
  git cherry-pick -n 8983424d9a8d0a39d065b0e353d6fd3f2b2a638c

  # Bump cutlass to v4.2 which supports CUDA 13 https://github.com/NVIDIA/cutlass/pull/2587
  patch -p1 -i "${srcdir}/deps-cutlass-4.2.0.patch"

  # Fix thrust and cub API usage
  patch -p1 -i "${srcdir}/fix-thrust-api.patch"

  cd "${srcdir}"
  cp -r "${pkgbase}" "${pkgbase}-cpu"
  cp -r "${pkgbase}" "${pkgbase}-cuda"
  cp -r "${pkgbase}" "${pkgbase}-opt-cuda"
  cp -r "${pkgbase}" "${pkgbase}-rocm"
  cp -r "${pkgbase}" "${pkgbase}-opt-rocm"
}

build() {
  # Use -Donnxruntime_ENABLE_LAZY_TENSOR=OFF as it requires patched python-pytorch
  # See: https://github.com/microsoft/onnxruntime/pull/10460 https://github.com/pytorch/pytorch/pulls/wschin
  local _cmake_args=(
    --compile-no-warning-as-error
    -S cmake
    -B build
    -Wno-dev
    -G Ninja
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    -DCMAKE_BUILD_TYPE=None
    -DCMAKE_INSTALL_PREFIX=/usr
    -Donnxruntime_ENABLE_PYTHON=ON
    -Donnxruntime_BUILD_SHARED_LIB=ON
    -Donnxruntime_BUILD_UNIT_TESTS=OFF
    -DBUILD_TESTING=OFF
    -Donnxruntime_ENABLE_TRAINING=ON
    -Donnxruntime_ENABLE_LAZY_TENSOR=OFF
    # Stable release of eigen is too old for onnxruntime.
    -Donnxruntime_USE_PREINSTALLED_EIGEN=OFF
    -DCMAKE_CXX_STANDARD=17)

  # Use protobuf-lite instead of full protobuf to workaround symbol conflicts
  # with onnx; see https://github.com/onnx/onnx/issues/1277 for details.
  _cmake_args+=(
    -Donnxruntime_USE_FULL_PROTOBUF=OFF)

  CXXFLAGS+=" -I/opt/cuda/targets/x86_64-linux/include"
  local _cmake_cuda_args=("${_cmake_args[@]}"
    -DCMAKE_CUDA_ARCHITECTURES="$(_valid_sm)"
    -DCMAKE_CUDA_STANDARD_REQUIRED=ON
    -DCMAKE_CXX_STANDARD_REQUIRED=ON
    # WARNING: too many threads will eat all your RAM
    -Donnxruntime_NVCC_THREADS=2
    -Donnxruntime_USE_DNNL=ON
    -Donnxruntime_USE_CUDA=ON
    -Donnxruntime_USE_NCCL=ON
    -Donnxruntime_CUDA_HOME=/opt/cuda
    -Donnxruntime_CUDNN_HOME=/usr)

  # Disable composable kernel support as onnxruntime doesn't work with tagged
  # upstream release.
  #
  # With USE_ROCM=ON NCCL is mapped on RCCL.
  local _cmake_rocm_args=("${_cmake_args[@]}"
    -DCMAKE_HIP_ARCHITECTURES="$(_valid_gfx)"
    -DCMAKE_HIP_FLAGS="-DHIPBLAS_USE_HIP_HALF=1 -DROCM_USE_FLOAT16=1"
    -Donnxruntime_USE_DNNL=ON
    -Donnxruntime_USE_MIGRAPHX=ON
    -Donnxruntime_USE_NCCL=ON
    -Donnxruntime_BUILD_KERNEL_EXPLORER=OFF
    -Donnxruntime_USE_COMPOSABLE_KERNEL=OFF
    -Donnxruntime_NCCL_HOME=/opt/rocm
    -Donnxruntime_ROCM_HOME=/opt/rocm)

  # For LTO everything needs to be compiled with the gcc version of CUDA
  export CXX="$NVCC_CCBIN"
  export CC="${NVCC_CCBIN/g++/gcc}"


  ##### onnxruntime-cpu
  echo "Build onnxruntime without GPU support"
  cd "${srcdir}/${pkgbase}-cpu"
  cmake "${_cmake_args[@]}"
  cmake --build build

  # Manually fix https://github.com/microsoft/onnxruntime/issues/24570
  mkdir onnxruntime/capi
  python setup.py --help # We have to call it like this once to generate the file we need.
  cp -r build/onnxruntime/* onnxruntime
  python -m build --wheel --no-isolation

  ##### onnxruntime-cuda

  echo "Build onnxruntime with CUDA without optimization"
  cd "${srcdir}/${pkgbase}-cuda"
  cmake "${_cmake_cuda_args[@]}"
  cmake --build build

  # Manually fix https://github.com/microsoft/onnxruntime/issues/24570
  mkdir onnxruntime/capi
  python setup.py --help # We have to call it like this once to generate the file we need.
  cp -r build/onnxruntime/* onnxruntime
  python -m build --wheel --no-isolation


  ##### onnxruntime-opt-cuda

  echo "Build onnxruntime with CUDA with AVX optimizations"
  cd "${srcdir}/${pkgbase}-opt-cuda"
  echo 'string(APPEND CMAKE_C_FLAGS " -march=haswell")' \
    >> cmake/adjust_global_compile_flags.cmake
  echo 'string(APPEND CMAKE_CXX_FLAGS " -march=haswell")' \
    >> cmake/adjust_global_compile_flags.cmake
  cmake "${_cmake_cuda_args[@]}"
  cmake --build build

  # Manually fix https://github.com/microsoft/onnxruntime/issues/24570
  mkdir onnxruntime/capi
  python setup.py --help # We have to call it like this once to generate the file we need.
  cp -r build/onnxruntime/* onnxruntime
  python -m build --wheel --no-isolation


  ##### onnxruntime-rocm

  echo "Build onnxruntime with ROCm without optimization"
  cd "${srcdir}/${pkgbase}-rocm"
  cmake "${_cmake_rocm_args[@]}"
  cmake --build build

  # Manually fix https://github.com/microsoft/onnxruntime/issues/24570
  mkdir onnxruntime/capi
  python setup.py --help # We have to call it like this once to generate the file we need.
  cp -r build/onnxruntime/* onnxruntime
  python -m build --wheel --no-isolation


  ##### onnxruntime-opt-rocm

  echo "Build onnxruntime with ROCm with AVX optimizations"
  cd "${srcdir}/${pkgbase}-opt-rocm"
  echo 'string(APPEND CMAKE_C_FLAGS " -march=haswell")' \
    >> cmake/adjust_global_compile_flags.cmake
  echo 'string(APPEND CMAKE_CXX_FLAGS " -march=haswell")' \
    >> cmake/adjust_global_compile_flags.cmake
  cmake "${_cmake_rocm_args[@]}"
  cmake --build build

  # Manually fix https://github.com/microsoft/onnxruntime/issues/24570
  mkdir onnxruntime/capi
  python setup.py --help # We have to call it like this once to generate the file we need.
  cp -r build/onnxruntime/* onnxruntime
  python -m build --wheel --no-isolation
}

package_onnxruntime-cpu() {
  pkgdesc="$_pkgdesc (CPU only)"
  provides=("${pkgbase}=${pkgver}")
  conflicts=("${pkgbase}")

  cd "${pkgbase}-cpu"
  DESTDIR="${pkgdir}" cmake --install build

  install -Dm644 LICENSE "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE"
  install -Dm644 ThirdPartyNotices.txt "${pkgdir}/usr/share/licenses/${pkgname}/ThirdPartyNotices.txt"
}

package_onnxruntime-cuda() {
  pkgdesc="$_pkgdesc (with CUDA)"
  depends+=('cuda' 'cudnn' 'nccl' 'onednn')
  provides=("${pkgbase}=${pkgver}")
  conflicts=("${pkgbase}")
  replaces=("${pkgbase}")

  cd "${pkgbase}-cuda"
  DESTDIR="${pkgdir}" cmake --install build

  install -Dm644 LICENSE "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE"
  install -Dm644 ThirdPartyNotices.txt "${pkgdir}/usr/share/licenses/${pkgname}/ThirdPartyNotices.txt"
}

package_onnxruntime-opt-cuda() {
  pkgdesc="$_pkgdesc (with CUDA and AVX2 CPU optimizations)"
  depends+=('cuda' 'cudnn' 'nccl' 'onednn')
  provides=("${pkgbase}=${pkgver}")
  conflicts=("${pkgbase}")
  replaces=("${pkgbase}-opt")

  cd "${pkgbase}-opt-cuda"
  DESTDIR="${pkgdir}" cmake --install build

  install -Dm644 LICENSE "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE"
  install -Dm644 ThirdPartyNotices.txt "${pkgdir}/usr/share/licenses/${pkgname}/ThirdPartyNotices.txt"
}

package_onnxruntime-rocm() {
  pkgdesc="$_pkgdesc (with ROCm)"
  depends+=('rocm-hip-sdk' 'roctracer' 'rccl' 'migraphx')
  provides=("${pkgbase}=${pkgver}")
  conflicts=("${pkgbase}")

  cd "${pkgbase}-rocm"
  DESTDIR="${pkgdir}" cmake --install build
  install -Dm644 LICENSE "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE"
  install -Dm644 ThirdPartyNotices.txt "${pkgdir}/usr/share/licenses/${pkgname}/ThirdPartyNotices.txt"
}

package_onnxruntime-opt-rocm() {
  pkgdesc="$_pkgdesc (with ROCm and AVX2 CPU optimizations)"
  depends+=('rocm-hip-sdk' 'roctracer' 'rccl' 'migraphx')
  provides=("${pkgbase}=${pkgver}")
  conflicts=("${pkgbase}")

  cd "${pkgbase}-opt-rocm"
  DESTDIR="${pkgdir}" cmake --install build
  install -Dm644 LICENSE "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE"
  install -Dm644 ThirdPartyNotices.txt "${pkgdir}/usr/share/licenses/${pkgname}/ThirdPartyNotices.txt"
}

package_python-onnxruntime-cpu() {
  pkgdesc="$_pkgdesc (CPU only)"
  depends+=("${pkgbase}-cpu" "${_pydepends[@]}")
  provides=("python-${pkgbase}=${pkgver}")
  conflicts=("python-${pkgbase}")

  cd "${pkgbase}-cpu"
  python -m installer --destdir="${pkgdir}" dist/*.whl
  install -Dm644 LICENSE "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE"
  install -Dm644 ThirdPartyNotices.txt "${pkgdir}/usr/share/licenses/${pkgname}/ThirdPartyNotices.txt"
}

package_python-onnxruntime-cuda() {
  pkgdesc="$_pkgdesc (with CUDA)"
  depends+=("${pkgbase}-cuda" "${_pydepends[@]}")
  provides=("python-${pkgbase}=${pkgver}")
  conflicts=("python-${pkgbase}")
  replaces=("python-${pkgbase}")

  cd "${pkgbase}-cuda"
  python -m installer --destdir="${pkgdir}" dist/*.whl
  install -Dm644 LICENSE "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE"
  install -Dm644 ThirdPartyNotices.txt "${pkgdir}/usr/share/licenses/${pkgname}/ThirdPartyNotices.txt"
}

package_python-onnxruntime-opt-cuda() {
  pkgdesc="$_pkgdesc (with CUDA and AVX2 CPU optimizations)"
  depends+=("${pkgbase}-opt-cuda" "${_pydepends[@]}")
  provides=("python-${pkgbase}=${pkgver}")
  conflicts=("python-${pkgbase}")
  replaces=("python-${pkgbase}-opt")

  cd "${pkgbase}-opt-cuda"
  python -m installer --destdir="${pkgdir}" dist/*.whl
  install -Dm644 LICENSE "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE"
  install -Dm644 ThirdPartyNotices.txt "${pkgdir}/usr/share/licenses/${pkgname}/ThirdPartyNotices.txt"
}

package_python-onnxruntime-rocm() {
  pkgdesc="$_pkgdesc (with ROCm)"
  depends+=("${pkgbase}-rocm" "${_pydepends[@]}")
  provides=("python-${pkgbase}=${pkgver}")
  conflicts=("python-${pkgbase}")

  cd "${pkgbase}-rocm"
  python -m installer --destdir="${pkgdir}" dist/*.whl
  install -Dm644 LICENSE "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE"
  install -Dm644 ThirdPartyNotices.txt "${pkgdir}/usr/share/licenses/${pkgname}/ThirdPartyNotices.txt"
}

package_python-onnxruntime-opt-rocm() {
  pkgdesc="$_pkgdesc (with ROCm and AVX2 CPU optimizations)"
  depends+=("${pkgbase}-opt-rocm" "${_pydepends[@]}")
  provides=("python-${pkgbase}=${pkgver}")
  conflicts=("python-${pkgbase}")

  cd "${pkgbase}-opt-rocm"
  python -m installer --destdir="${pkgdir}" dist/*.whl
  install -Dm644 LICENSE "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE"
  install -Dm644 ThirdPartyNotices.txt "${pkgdir}/usr/share/licenses/${pkgname}/ThirdPartyNotices.txt"
}
