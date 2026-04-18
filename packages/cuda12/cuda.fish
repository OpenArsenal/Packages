set -gx CUDA_PATH /opt/cuda
fish_add_path /opt/cuda/bin
set -gx NVCC_CCBIN /usr/bin/g++-14

# Silence nvcc warnings for deprecated GPU targets by default.
# Preserve any user-supplied flags and add ours only once.
if set -q NVCC_PREPEND_FLAGS
    if not contains -- -Wno-deprecated-gpu-targets $NVCC_PREPEND_FLAGS
        set -gx NVCC_PREPEND_FLAGS $NVCC_PREPEND_FLAGS -Wno-deprecated-gpu-targets
    end
else
    set -gx NVCC_PREPEND_FLAGS -Wno-deprecated-gpu-targets
end
