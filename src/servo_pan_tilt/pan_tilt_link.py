#!/usr/bin/env python3
import glob
import json
import os
import sys
import time

GPIO_ROOT = "/sys/class/gpio"
PINS = range(54, 70)
OUTPUT_PINS = [54, 55] + list(range(58, 70))
STATUS_BUSY = 56
STATUS_DONE = 57
HOME = (1560, 2200)
# Larger 30-second target path. Horizontal endpoints stay inside the previously
# measured range, while tilt remains close to zero. Each point is held 5 seconds.
TRACK_PATH = ((1360, 2120), (1360, 2280), (1560, 2280),
              (1760, 2280), (1760, 2120), (1560, 2120))
HOLD_REPEATS = 5
TRACKING_SECONDS = len(TRACK_PATH) * HOLD_REPEATS
RUN_MODE = sys.argv[2] if len(sys.argv) > 2 else "track"
GROUP_COUNT = 20
INTER_GROUP_REST_SECONDS = 60
BOUNDARY_START = (1200, 1900)
BOUNDARY_END = (1870, 2300)
BOUNDARY_APPROACH_STEPS = 10
BOUNDARY_SWEEP_STEPS = 30
STREAM_START_WIDTH = 4095
STREAM_STOP_WIDTH = 4094
SMOOTH_APPROACH_STEPS = 30
SMOOTH_SWEEP_STEPS = 120
if RUN_MODE not in ("track", "home-only", "batch20", "boundary-sweep", "smooth-boundary"):
    raise ValueError("Unsupported run mode: {}".format(RUN_MODE))


def write(path, value):
    with open(path, "w", encoding="ascii") as stream:
        stream.write(str(value))


def read_pin(pin):
    path = "{}/gpio{}/value".format(GPIO_ROOT, pin)
    with open(path, "r", encoding="ascii") as stream:
        return stream.read().strip() == "1"


def wait_for(predicate, timeout, description):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return time.monotonic()
        time.sleep(0.001)
    raise RuntimeError("Timed out waiting for {}".format(description))


def set_width(width):
    if not 1000 <= width <= 2300:
        raise ValueError("Pulse width outside bounded test range: {}".format(width))
    for pin in range(58, 70):
        write("{}/gpio{}/value".format(GPIO_ROOT, pin), (width >> (pin - 58)) & 1)


def set_raw_width(width):
    if not 0 <= width <= 4095:
        raise ValueError("Raw pulse-width bus value outside 12-bit range: {}".format(width))
    for pin in range(58, 70):
        write("{}/gpio{}/value".format(GPIO_ROOT, pin), (width >> (pin - 58)) & 1)


def request(mode, width=None):
    write("{}/gpio54/value".format(GPIO_ROOT), 0)
    write("{}/gpio55/value".format(GPIO_ROOT), 0)
    time.sleep(0.05)
    if width is not None:
        set_width(width)
        time.sleep(0.05)
    if read_pin(STATUS_BUSY) or read_pin(STATUS_DONE):
        raise RuntimeError("Stale FPGA status before request")

    requested_at = time.monotonic()
    write("{}/gpio54/value".format(GPIO_ROOT), mode & 1)
    write("{}/gpio55/value".format(GPIO_ROOT), (mode >> 1) & 1)
    if mode == 1 or mode == 2:
        done_at = wait_for(lambda: read_pin(STATUS_DONE) and not read_pin(STATUS_BUSY),
                           0.5, "axis width setup acknowledgement")
        result = {"setup_ack_after_s": round(done_at - requested_at, 6)}
    elif mode == 3:
        busy_at = wait_for(lambda: read_pin(STATUS_BUSY), 0.25, "paired move start")
        done_at = wait_for(lambda: read_pin(STATUS_DONE) and not read_pin(STATUS_BUSY),
                           1.5, "50-frame paired move completion")
        elapsed = round(done_at - requested_at, 6)
        if not 0.98 <= elapsed <= 1.2:
            raise RuntimeError("Unexpected paired move duration: {}s".format(elapsed))
        result = {"busy_asserted_after_s": round(busy_at - requested_at, 6),
                  "completed_after_s": elapsed}
    else:
        raise ValueError("Unsupported GPIO command mode")

    time.sleep(0.02)
    write("{}/gpio54/value".format(GPIO_ROOT), 0)
    write("{}/gpio55/value".format(GPIO_ROOT), 0)
    wait_for(lambda: not read_pin(STATUS_BUSY) and not read_pin(STATUS_DONE),
             0.25, "idle after request")
    return result


def prepare_and_move(pan_width, tilt_width):
    pan_setup = request(1, pan_width)
    tilt_setup = request(2, tilt_width)
    run = request(3)
    return {"pan_us": pan_width, "tilt_us": tilt_width,
            "pan_setup": pan_setup, "tilt_setup": tilt_setup, "run": run,
            "frames": 50}


def prepare_and_hold(pan_width, tilt_width):
    if abs(pan_width - HOME[0]) > 200 or abs(tilt_width - HOME[1]) > 80:
        raise ValueError("Target path exceeds the bounded tracking window")
    pan_setup = request(1, pan_width)
    tilt_setup = request(2, tilt_width)
    runs = [request(3) for _ in range(HOLD_REPEATS)]
    return {"pan_us": pan_width, "tilt_us": tilt_width,
            "pan_setup": pan_setup, "tilt_setup": tilt_setup,
            "runs": runs, "hold_frames": 50 * HOLD_REPEATS,
            "hold_s": HOLD_REPEATS}


def stream_command(mode):
    write("{}/gpio54/value".format(GPIO_ROOT), mode & 1)
    write("{}/gpio55/value".format(GPIO_ROOT), (mode >> 1) & 1)


def stream_clear():
    stream_command(0)
    time.sleep(0.025)


def stream_update_axis(mode, width):
    stream_clear()
    set_width(width)
    time.sleep(0.003)
    stream_command(mode)
    time.sleep(0.025)
    stream_clear()


def stream_begin(pan_width, tilt_width):
    request(1, pan_width)
    request(2, tilt_width)
    stream_clear()
    set_raw_width(STREAM_START_WIDTH)
    stream_command(1)
    wait_for(lambda: read_pin(STATUS_DONE) and not read_pin(STATUS_BUSY),
             0.5, "smooth stream start acknowledgement")
    stream_clear()
    stream_command(3)
    wait_for(lambda: read_pin(STATUS_BUSY), 0.5, "smooth stream start")


def stream_stop():
    stream_clear()
    set_raw_width(STREAM_STOP_WIDTH)
    stream_command(3)
    wait_for(lambda: read_pin(STATUS_DONE) and not read_pin(STATUS_BUSY),
             0.5, "smooth stream stop")
    stream_clear()
    wait_for(lambda: not read_pin(STATUS_BUSY) and not read_pin(STATUS_DONE),
             0.5, "smooth stream idle")


def stream_sweep(start, end, steps, phase):
    result = []
    for index in range(steps):
        pan_width, tilt_width = interpolate_pair(start, end, steps, index)
        stream_update_axis(1, pan_width)
        stream_update_axis(2, tilt_width)
        result.append(dict(phase=phase, boundary_step=index + 1,
                           pan_us=pan_width, tilt_us=tilt_width,
                           stream=True))
    return result


def interpolate_pair(start, end, steps, index):
    if steps < 2:
        return tuple(end)
    fraction = index / float(steps - 1)
    return tuple(round(start[axis] + (end[axis] - start[axis]) * fraction)
                 for axis in (0, 1))


def capture_camera_frame(base_path):
    log_path = base_path + ".log"
    command = ("timeout 4 guvcview --device=/dev/video0 --render=none --gui=none "
               "--audio=none --resolution=640x480 --image={} --photo_total=1 "
               "--photo_timer=0.2 >{} 2>&1".format(base_path, log_path))
    os.system(command)
    files = glob.glob(base_path[:-4] + "-*.jpg")
    if not files:
        return None
    files.sort()
    return files[-1]


def camera_ready():
    name_path = "/sys/class/video4linux/video0/name"
    try:
        with open(name_path, "r", encoding="utf-8") as stream:
            return os.path.exists("/dev/video0") and stream.read().strip() == "USB Camera"
    except OSError:
        return False


created = []
transitions = []
camera_frame = None
camera_connected = camera_ready()
run_id = os.path.basename(sys.argv[1]) if len(sys.argv) > 1 else "servo_track"
capture_base = "/tmp/{}_view.jpg".format(run_id)

try:
    for pin in PINS:
        path = "{}/gpio{}".format(GPIO_ROOT, pin)
        if os.path.exists(path):
            raise RuntimeError("GPIO {} was already exported".format(pin))
        write("{}/export".format(GPIO_ROOT), pin)
        created.append(pin)
    time.sleep(0.05)

    for pin in OUTPUT_PINS:
        write("{}/gpio{}/direction".format(GPIO_ROOT, pin), "out")
        write("{}/gpio{}/value".format(GPIO_ROOT, pin), 0)
    for pin in (STATUS_BUSY, STATUS_DONE):
        write("{}/gpio{}/direction".format(GPIO_ROOT, pin), "in")

    if RUN_MODE == "home-only":
        transitions.append(dict(phase="home_correction",
                                **prepare_and_move(HOME[0], HOME[1])))
    elif RUN_MODE == "batch20":
        for group in range(1, GROUP_COUNT + 1):
            group_start = len(transitions)
            for step, (pan_width, tilt_width) in enumerate(TRACK_PATH, start=1):
                transitions.append(dict(phase="track_target", group=group,
                                        target_step=step,
                                        **prepare_and_hold(pan_width, tilt_width)))
            transitions.append(dict(phase="return_zero", group=group,
                                    **prepare_and_move(HOME[0], HOME[1])))
            if group < GROUP_COUNT:
                time.sleep(INTER_GROUP_REST_SECONDS)
    elif RUN_MODE == "boundary-sweep":
        for index in range(BOUNDARY_APPROACH_STEPS):
            pan_width, tilt_width = interpolate_pair(HOME, BOUNDARY_START,
                                                      BOUNDARY_APPROACH_STEPS,
                                                      index)
            transitions.append(dict(phase="approach_boundary", boundary_step=index + 1,
                                    **prepare_and_move(pan_width, tilt_width)))
        for index in range(BOUNDARY_SWEEP_STEPS):
            pan_width, tilt_width = interpolate_pair(BOUNDARY_START, BOUNDARY_END,
                                                      BOUNDARY_SWEEP_STEPS,
                                                      index)
            transitions.append(dict(phase="boundary_sweep", boundary_step=index + 1,
                                    **prepare_and_move(pan_width, tilt_width)))
        transitions.append(dict(phase="return_zero",
                                **prepare_and_move(HOME[0], HOME[1])))
    elif RUN_MODE == "smooth-boundary":
        stream_begin(HOME[0], HOME[1])
        transitions.extend(stream_sweep(HOME, BOUNDARY_START,
                                        SMOOTH_APPROACH_STEPS,
                                        "smooth_approach_boundary"))
        transitions.extend(stream_sweep(BOUNDARY_START, BOUNDARY_END,
                                        SMOOTH_SWEEP_STEPS,
                                        "smooth_boundary_sweep"))
        stream_stop()
        transitions.append(dict(phase="return_zero", stream=False,
                                **prepare_and_move(HOME[0], HOME[1])))
    else:
        for step, (pan_width, tilt_width) in enumerate(TRACK_PATH, start=1):
            transitions.append(dict(phase="track_target", target_step=step,
                                    **prepare_and_hold(pan_width, tilt_width)))
        transitions.append(dict(phase="return_zero", **prepare_and_move(HOME[0], HOME[1])))

    print(json.dumps({"axis": "pan+tilt", "pan_ball": "H20", "tilt_ball": "H19",
                      "run_mode": RUN_MODE,
                      "tracking_path_us": [list(point) for point in TRACK_PATH] if RUN_MODE == "track" else [],
                      "home_us": list(HOME),
                      "tracking_duration_s": TRACKING_SECONDS if RUN_MODE in ("track", "batch20") else 0,
                      "repeats_per_target": HOLD_REPEATS if RUN_MODE in ("track", "batch20") else 0,
                      "group_count": GROUP_COUNT if RUN_MODE == "batch20" else (1 if RUN_MODE == "track" else 0),
                      "inter_group_rest_s": INTER_GROUP_REST_SECONDS if RUN_MODE == "batch20" else 0,
                      "boundary_start_us": list(BOUNDARY_START) if RUN_MODE in ("boundary-sweep", "smooth-boundary") else [],
                      "boundary_end_us": list(BOUNDARY_END) if RUN_MODE in ("boundary-sweep", "smooth-boundary") else [],
                      "boundary_approach_steps": BOUNDARY_APPROACH_STEPS if RUN_MODE == "boundary-sweep" else 0,
                      "boundary_sweep_steps": BOUNDARY_SWEEP_STEPS if RUN_MODE == "boundary-sweep" else 0,
                      "smooth_approach_steps": SMOOTH_APPROACH_STEPS if RUN_MODE == "smooth-boundary" else 0,
                      "smooth_sweep_steps": SMOOTH_SWEEP_STEPS if RUN_MODE == "smooth-boundary" else 0,
                      "frames_per_move": 50, "camera_connected": camera_connected,
                      "camera_frame": camera_frame,
                      "transitions": transitions}, sort_keys=True), flush=True)
    if RUN_MODE == "home-only":
        print("PAN_TILT_HOME_CORRECTION_PASS home=1560,2200", flush=True)
    elif RUN_MODE == "batch20":
        print("PAN_TILT_BATCH20_PASS groups=20 tracking_s=30 rest_s=60 home=1560,2200",
              flush=True)
    elif RUN_MODE == "boundary-sweep":
        print("PAN_TILT_BOUNDARY_SWEEP_PASS steps=30 approach=10 start=1200,1900 end=1870,2300 home=1560,2200",
              flush=True)
    elif RUN_MODE == "smooth-boundary":
        print("PAN_TILT_SMOOTH_BOUNDARY_PASS approach=30 sweep=120 start=1200,1900 end=1870,2300 home=1560,2200",
              flush=True)
    else:
        print("PAN_TILT_TRACK_SIM_PASS steps=6 duration_s=30 home=1560,2200",
              flush=True)
finally:
    for pin in (54, 55):
        try:
            if os.path.exists("{}/gpio{}/value".format(GPIO_ROOT, pin)):
                write("{}/gpio{}/value".format(GPIO_ROOT, pin), 0)
        except OSError:
            pass
    for pin in reversed(created):
        try:
            write("{}/unexport".format(GPIO_ROOT), pin)
        except OSError:
            pass
