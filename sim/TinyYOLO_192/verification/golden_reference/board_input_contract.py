"""Shared, dependency-free checks for the Linux float32 frame input ABI."""
import hashlib
import math
import struct


INPUT_VALUES = 3 * 416 * 416
INPUT_BYTES = INPUT_VALUES * 4
INPUT_SCALE = struct.unpack('<f', struct.pack('<f', 1.0 / 255.0))[0]
INPUT_ZERO_POINT = -128
INPUT_CONTRACT = dict(dtype='float32_le', layout='CHW', shape=[3, 416, 416],
                      elements=INPUT_VALUES, bytes_per_element=4,
                      normalized_range=[0.0, 1.0],
                      quantization=dict(dtype='int8', scale=INPUT_SCALE,
                                        zero_point=INPUT_ZERO_POINT, rounding='nearest_even'))


def make_input_contract(size):
    require(type(size) is int and size in (96,128,160,192,256,320,416), 'Invalid network size')
    contract = dict(INPUT_CONTRACT)
    contract.update(shape=[3,size,size], elements=3*size*size)
    return contract


def require(condition, message):
    # These checks must also run under python -O on the target board.
    if not condition:
        raise ValueError(message)


def sha_bytes(data):
    return hashlib.sha256(data).hexdigest()


def check_frame(data, quantized_sha256, label, contract=None):
    contract = INPUT_CONTRACT if contract is None else contract
    elements = contract['elements']
    require(len(data) == elements*4,
            '%s: runtime requires %d float32 bytes, got %d' % (label, elements*4, len(data)))
    quantized = bytearray(elements)
    for i, (value,) in enumerate(struct.iter_unpack('<f', data)):
        require(math.isfinite(value) and 0.0 <= value <= 1.0,
                '%s: invalid normalized float32 value at element %d' % (label, i))
        # Match the FP32 division and nearest-even conversion in quant_input().
        scaled = struct.unpack('<f', struct.pack('<f', value / INPUT_SCALE))[0]
        q = round(scaled) + INPUT_ZERO_POINT
        quantized[i] = max(-128, min(127, q)) & 255
    actual = sha_bytes(quantized)
    require(actual == quantized_sha256, label+': quantized input differs from host step 0')
    return dict(bytes=len(data), sha256=sha_bytes(data), quantized_bytes=len(quantized),
                quantized_sha256=actual)


def check_input_files(expected, read):
    contract = expected.get('input_contract', {})
    shape = contract.get('shape', [])
    require(len(shape)==3 and shape[0]==3 and shape[1]==shape[2], 'Wrong Linux input shape')
    require(contract == make_input_contract(shape[1]), 'Wrong Linux input ABI metadata')
    require(set(expected['inputs']) == {'parameters.bin', 'bird.bin', 'random.bin'},
            'Wrong board input inventory')
    require(set(expected['frames']) == {'bird', 'random', 'bird_repeat'}, 'Missing expected frame')
    checks = {}
    for name, record in expected['inputs'].items():
        data = read(name)
        require(len(data) == record['bytes'], name+': input byte count differs')
        require(sha_bytes(data) == record['sha256'], name+': input SHA256 differs')
        if name != 'parameters.bin':
            case = name[:-4]
            step = expected['frames'][case]['steps'][0]
            require(step['step'] == 0 and step['kind'] == 1 and step['bytes'] == contract['elements'],
                    case+': wrong quantization step metadata')
            checks[case] = check_frame(data, step['sha256'], name, contract)
    require(expected['frames']['bird_repeat']['steps'][0] == expected['frames']['bird']['steps'][0],
            'Repeated bird input differs')
    return dict(status='PASS_FLOAT32_INPUT_CONTRACT_ONLY', board_tested=False,
                input_contract=contract, frames=checks)
