set -eu
test -s /tmp/servo_microtest_retest_boot_id
test "$(cat /proc/sys/kernel/random/boot_id)" = "$(cat /tmp/servo_microtest_retest_boot_id)"
modprobe tinyyolo_dma
test -c /dev/tinyyolo0
python3 - <<'PY'
import os, fcntl, struct, json
fd = os.open('/dev/tinyyolo0', os.O_RDWR)
try:
    info = bytearray(32)
    fcntl.ioctl(fd, 0x80205928, info, True)
    values = struct.unpack('<8I', info)
    if values[:3] != (2, 0x47325502, 240000000) or abs(values[3]-100000000) > 10000 or values[5] != 0:
        raise ValueError('Unexpected accelerator identity, clocks or fault state')
    print(json.dumps(dict(zip(('abi','build_id','pl_hz','fclk_hz','dma_bytes','faulted','ocm_bytes','ocm_flags'), values)), sort_keys=True))
finally:
    os.close(fd)
PY
printf 'boot_id='; cat /proc/sys/kernel/random/boot_id
printf 'SERVO_ORIGINAL_INFERENCE_RESTORED\n'
