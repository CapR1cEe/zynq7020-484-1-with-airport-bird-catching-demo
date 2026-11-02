"""Run on Xillinux in the unpacked runtime directory; verify every graph step."""
import argparse
import errno
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import time

from board_input_contract import check_input_files, require

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--check-inputs', action='store_true',
                    help='Check float32 files and quantized hashes without opening the PL device')
args = parser.parse_args()
root = Path(__file__).resolve().parent
os.chdir(str(root))
expected = json.loads((root/'expected.json').read_text())
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
input_check = check_input_files(expected, lambda name: (root/name).read_bytes())
if args.check_inputs:
    print(json.dumps(input_check, indent=2))
    raise SystemExit(0)
import fcntl
require(not (root/'smoke.json').exists() and not list(root.glob('*.metrics.json')) and
        not list(root.glob('*.step[0-9][0-9].bin')),
        'Use a fresh unpacked validation directory; previous board output exists')
fd = os.open('/dev/tinyyolo0', os.O_RDWR)
try:
    info = bytearray(32)
    fcntl.ioctl(fd, 0x80205928, info, True)
    abi, build, pl, fclk, dma, faulted, ocm_bytes, ocm_flags = struct.unpack('<8I', info)
    require(abi == 2 and build == int(expected['hardware']['build_id'],16) and
            pl == expected['hardware']['pl_MHz']*1000000, 'Device ABI/build/PL clock mismatch')
    require(abs(fclk-100000000) <= 10000 and dma == 33554432 and faulted == 0,
            'Device FCLK/DMA/fault check failed')
    try:
        second = os.open('/dev/tinyyolo0', os.O_RDWR)
    except OSError as e:
        require(e.errno == errno.EBUSY, 'Concurrent open returned unexpected errno')
    else:
        os.close(second)
        raise AssertionError('Concurrent opens must be rejected')
    try:
        fcntl.ioctl(fd, 0xC1145929, bytearray(276), True)
    except OSError as e:
        require(e.errno == errno.EINVAL, 'Empty descriptor returned unexpected errno')
    else:
        raise AssertionError('Empty descriptor must be rejected')
finally:
    os.close(fd)
smoke = {'status': 'PASS_LINUX_DRIVER_SMOKE', 'abi': abi, 'build_id': hex(build),
         'pl_hz': pl, 'fclk_hz': fclk, 'dma_bytes': dma,
         'exclusive_open': 'PASS_EBUSY', 'invalid_descriptor': 'PASS_EINVAL', 'faulted': faulted, 'ocm_bytes': ocm_bytes, 'ocm_flags': ocm_flags}
(root/'smoke.json').write_text(json.dumps(smoke, indent=2)+'\n')
print('PASS_LINUX_DRIVER_SMOKE', flush=True)
frames = {}
for name in ('bird', 'random', 'bird_repeat'):
    env = os.environ.copy()
    env['TINYYOLO_TRACE_PREFIX'] = str(root/name)
    input_name = 'bird.bin' if name == 'bird_repeat' else name+'.bin'
    started = time.monotonic()
    print('TRACE_START '+name, flush=True)
    subprocess.check_call(['./tinyyolo_linux', '/dev/tinyyolo0', 'parameters.bin',
                           input_name, str(root/name), '1'], env=env)
    checks = []
    for step, item in enumerate(expected['frames'][name]['steps']):
        actual = root/('%s.0001.step%02d.bin' % (name, step))
        digest = sha(actual)
        require(actual.stat().st_size == item['bytes'], '%s step %d: wrong size' % (name, step))
        require(digest == item['sha256'], '%s step %d: SHA256 mismatch' % (name, step))
        checks.append(dict(item, status='PASS_SHA256_EQUAL'))
    final = root/(name+'.0001.final.bin')
    require(sha(final) == expected['frames'][name]['final_sha256'], name+' final: SHA256 mismatch')
    metrics = json.loads((root/(name+'.0001.metrics.json')).read_text())
    require(metrics['pl_calls'] == 24 and len(metrics['layers']) == 24, name+': missing PL layer')
    require(all(x['hp_idle'] == 1 and x['cycles'] > 0 for x in metrics['layers']),
            name+': invalid HP0/cycle metrics')
    require(metrics['trace_enabled'] is True, name+': trace was disabled')
    frames[name] = {'status': 'PASS_50_STEPS_24_CONVOLUTIONS', 'steps': checks,
                    'metrics': metrics, 'final_sha256': sha(final),
                    'wall_seconds': time.monotonic()-started}
    print('TRACE_PASS '+name+' steps=50 convolution_layers=24', flush=True)
    # Retain exact output digests in the receipt; release bounded snapshots
    # from tmpfs before production runs. Model and raw inputs stay intact.
    for step in range(50):
        (root/('%s.0001.step%02d.bin' % (name, step))).unlink()
print('PRODUCTION_START frames=8', flush=True)
env = os.environ.copy()
env.pop('TINYYOLO_TRACE_PREFIX', None)
subprocess.check_call(['./tinyyolo_linux', '/dev/tinyyolo0', 'parameters.bin',
                       'bird.bin', str(root/'production'), '8'], env=env)
production = []
for i in range(1, 9):
    prefix = 'production.%04d' % i
    metrics = json.loads((root/(prefix+'.metrics.json')).read_text())
    require(metrics['trace_enabled'] is False and metrics['pl_calls'] == 24 and
            len(metrics['layers']) == 24, prefix+': wrong production mode/layer count')
    require(all(x['hp_idle'] == 1 and x['cycles'] > 0 for x in metrics['layers']),
            prefix+': invalid HP0/cycle metrics')
    require(sha(root/(prefix+'.final.bin')) == expected['frames']['bird']['final_sha256'],
            prefix+': final SHA256 mismatch')
    production.append(metrics)
warm = [x['elapsed_ms'] for x in production[1:]]
result = {'status': 'PASS_LINUX_24_LAYER_AND_PRODUCTION', 'hardware': expected['hardware'],
          'input_check': input_check,
          'smoke': smoke, 'trace_frames': frames, 'production': production,
          'warm_frame_ms': {'samples': len(warm), 'min': min(warm), 'max': max(warm),
                            'mean': sum(warm)/len(warm)},
          'step_hash_comparisons': 150, 'convolution_hash_comparisons': 72,
          'model_parameters_changed': False, 'camera_tested_in_this_run': False}
(root/'result.json').write_text(json.dumps(result, indent=2)+'\n')
print('LINUX_BOARD_VALIDATION_PASS warm_mean_ms=%.3f' % result['warm_frame_ms']['mean'], flush=True)
