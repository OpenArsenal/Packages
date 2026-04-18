case ":$PATH:" in
  *:/opt/cuda/integration/nsight-systems:*) ;;
  *) PATH="$PATH:/opt/cuda/integration/nsight-systems" ;;
esac

export PATH
