case ":$PATH:" in
  *:/opt/cuda/integration/nsight-compute:*) ;;
  *) PATH="$PATH:/opt/cuda/integration/nsight-compute" ;;
esac

export PATH
