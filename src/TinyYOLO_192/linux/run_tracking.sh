#!/bin/sh
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export TINYYOLO_CPU_CACHE=ram
export TINYYOLO_ZERO_SKIP=1
exec python3 "$base/camera_infer.py" --track --video /dev/video0 \
    --frames 10000 --control-fps 15 --input-mode dma-int8 "$@"
