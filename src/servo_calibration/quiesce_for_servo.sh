set -eu
printf '\nCALIBRATION_QUIESCE_BEGIN\n'
boot_id=$(cat /proc/sys/kernel/random/boot_id)
test "$(cat /sys/class/gpio/gpiochip0/label)" = 'zynq_gpio'
test "$(cat /sys/class/gpio/gpiochip0/ngpio)" = 118
for pin in $(seq 54 69); do
    if test -d "/sys/class/gpio/gpio$pin"; then
        printf 'GPIO %s is already exported\n' "$pin"
        exit 1
    fi
done
command -v fuser >/dev/null
if test -e /dev/tinyyolo0 && fuser /dev/tinyyolo0; then
    printf 'Inference device is in use\n'
    exit 1
fi
if lsmod | awk '{print $1}' | grep -qx tinyyolo_dma; then
    rmmod tinyyolo_dma
fi
test ! -e /dev/tinyyolo0
test "$(cat /proc/sys/kernel/random/boot_id)" = "$boot_id"
printf '%s' "$boot_id" > /tmp/servo_microtest_retest_boot_id
printf 'CALIBRATION_DRIVER_QUIESCED\n'
