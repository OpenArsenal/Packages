export CUDA_PATH=/opt/cuda

case ":$PATH:" in
  *:/opt/cuda/bin:*) ;;
  *) PATH="$PATH:/opt/cuda/bin" ;;
esac

export PATH
export NVCC_CCBIN=/usr/bin/g++-14

# Silence nvcc warnings for deprecated GPU targets by default.
# Preserve any user-supplied flags and add ours only once.
case " ${NVCC_PREPEND_FLAGS-} " in
  *" -Wno-deprecated-gpu-targets "*) ;;
  *) export NVCC_PREPEND_FLAGS="${NVCC_PREPEND_FLAGS:+$NVCC_PREPEND_FLAGS }-Wno-deprecated-gpu-targets" ;;
esac
