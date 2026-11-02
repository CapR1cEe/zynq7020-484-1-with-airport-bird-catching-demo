"""One bounded H19 calibration request; H20 is disabled in hardware."""
import json
import os
import re
import sys
import time

width = int(sys.argv[1])
token = sys.argv[2]
if not 2000 <= width <= 2500 or not re.fullmatch(r'[A-Za-z0-9_]+', token):
    raise ValueError('Invalid pulse width or test token')
gpio_root = '/sys/class/gpio'
created = []
outputs = (54, 55) + tuple(range(58, 70))

def write(path, value):
    with open(path, 'w') as stream:
        stream.write(str(value))

def read_value(number):
    with open('%s/gpio%d/value' % (gpio_root, number)) as stream:
        return int(stream.read().strip())

def set_value(number, value):
    write('%s/gpio%d/value' % (gpio_root, number), value)

def state():
    for unused in range(5):
        before = read_value(57)
        busy = read_value(56)
        after = read_value(57)
        if before == after:
            return busy, after
    raise RuntimeError('Unstable status snapshot')

def stop():
    for number in (54, 55):
        if number in created:
            set_value(number, 0)

try:
    for number in range(54, 70):
        if os.path.exists('%s/gpio%d' % (gpio_root, number)):
            raise RuntimeError('GPIO %d already owned' % number)
    for number in range(54, 70):
        write(gpio_root + '/export', number)
        created.append(number)
        write('%s/gpio%d/direction' % (gpio_root, number), 'low' if number in outputs else 'in')
    for bit in range(12):
        set_value(58 + bit, (width >> bit) & 1)
    time.sleep(0.05)
    if state() != (0, 0):
        raise RuntimeError('FPGA is not idle')
    print('CALIBRATION_START width_us=%d pulses=150 frame_us=20000 total_ms=3000' % width, flush=True)
    marker = os.open('/tmp/' + token + '_fired', os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(marker)
    start = time.monotonic()
    set_value(55, 1)
    transitions = []
    previous = None
    saw_busy = False
    done = False
    while time.monotonic() - start < 4.0:
        current = state()
        elapsed = time.monotonic() - start
        if current != previous:
            transitions.append(dict(elapsed_s=round(elapsed, 6), busy=current[0], completed=current[1]))
            previous = current
        if current == (1, 0):
            saw_busy = True
        elif current == (0, 1):
            done = True
            break
        elif current == (1, 1):
            raise RuntimeError('Invalid FPGA status')
        time.sleep(0.001)
    if not done or not saw_busy or elapsed < 2.9:
        raise RuntimeError('Three-second completion not confirmed; no automatic retry')
    stop()
    time.sleep(0.02)
    if state() != (0, 0):
        raise RuntimeError('FPGA did not return to idle')
    print(json.dumps(dict(axis='tilt', ball='H19', width_us=width, commanded_pulses=150,
                          expected_frame_ms=20, expected_total_ms=3000,
                          busy_observed=saw_busy, request_completion_observed=done,
                          completion_sample_elapsed_s=round(elapsed, 6),
                          physical_pin_waveform_measured=False, physical_motion_confirmed=None,
                          transitions=transitions), sort_keys=True))
    print('CALIBRATION_SEQUENCE_PASS width_us=%d pulses=150 duration_ms=3000' % width)
finally:
    try:
        stop()
        time.sleep(0.01)
    finally:
        for number in reversed(created):
            write(gpio_root + '/unexport', number)
