"""One resident runtime per camera sequence; frame ownership is synchronous.

DMA mode maps the same coherent allocation in producer and runtime. Image
conversion still runs on the CPU. Only the small F command uses the pipe.
"""
import json
import mmap
import os
from pathlib import Path
import re
import subprocess

MODEL_CONFIG = json.loads((Path(__file__).parent/'model_config.json').read_text())
INPUT_SIZE = MODEL_CONFIG['input_size']
POSITIONS = MODEL_CONFIG['positions']
if type(INPUT_SIZE) is not int or INPUT_SIZE not in (96,128,160,192,256,320,416) or POSITIONS != (INPUT_SIZE//16)**2+(INPUT_SIZE//32)**2:
    raise ValueError('Invalid deployed model configuration')
INPUT_BYTES = INPUT_SIZE * INPUT_SIZE * 3 * 4
INT8_INPUT_BYTES = INPUT_SIZE * INPUT_SIZE * 3
DMA_BYTES = 32 * 1024 * 1024
TY_IOC_INPUT_PUBLISH = (ord('Y') << 8) | 0x2a


def write_all(stream, data):
    view = memoryview(data)
    while view:
        written = stream.write(view)
        if written is None or written <= 0:
            raise IOError('Runtime input pipe stopped accepting data')
        view = view[written:]
    stream.flush()


class RuntimeSession:
    def __init__(self, runtime, parameters, prefix, frames, mode='dma',
                 device='/dev/tinyyolo0'):
        if mode not in ('dma-int8', 'dma', 'pipe') or not 1 <= frames <= 10000:
            raise ValueError('Invalid input mode or frame count')
        self.prefix, self.frames, self.mode = Path(prefix), frames, mode
        self.input_bytes = INT8_INPUT_BYTES if mode == 'dma-int8' else INPUT_BYTES
        self.index, self.fd, self.mapping, self.process = 0, None, None, None
        self._prepared = False
        self.log = Path(str(self.prefix)+'.runtime.log').open('xb')
        try:
            descriptor = device
            options = {}
            if mode != 'pipe':
                if os.name != 'posix':
                    raise RuntimeError('Shared DMA input requires the Linux driver')
                self.fd = os.open(device, os.O_RDWR | os.O_CLOEXEC)
                descriptor = 'fd:%d' % self.fd
                options['pass_fds'] = (self.fd,)
                options['env'] = dict(os.environ, TINYYOLO_NO_FRAME_FILES='1')
            self.process = subprocess.Popen(
                [str(runtime), descriptor, str(parameters),
                 '@dma-int8' if mode == 'dma-int8' else ('@dma' if mode == 'dma' else '-'),
                 str(self.prefix), str(frames)], stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=self.log, bufsize=0, **options)
            line = self._line()
            if not line.startswith('READY_TINYYOLO_INPUT '):
                raise RuntimeError('Runtime did not publish an input mapping')
            self.info = json.loads(line.split(' ', 1)[1])
            if self.info.get('input_size') != INPUT_SIZE or self.info.get('positions') != POSITIONS or self.info.get('build_id') != 0x47325502:
                raise RuntimeError('Runtime/model configuration or build differs')
            offset, size = self.info.get('input_offset'), self.info.get('input_bytes')
            if (self.info.get('mode') != mode or self.info.get('dma_bytes') != DMA_BYTES or
                    type(offset) is not int or type(size) is not int or size != self.input_bytes or
                    offset < 0 or offset % 64 or offset > DMA_BYTES-size):
                raise RuntimeError('Invalid runtime input mapping')
            if mode == 'dma-int8' and (self.info.get('input_dtype') != 'int8' or self.info.get('pixel_xor') != 128):
                raise RuntimeError('Runtime does not support exact pixel-to-INT8 input')
            if mode != 'pipe':
                out, size = self.info.get('output_offset'), self.info.get('output_bytes')
                if type(out) is not int or out<0 or out%64 or size!=POSITIONS*5*4 or out>DMA_BYTES-size:
                    raise RuntimeError('Invalid shared DMA output mapping')
                if out<offset+self.input_bytes and offset<out+size:
                    raise RuntimeError('Shared DMA input and output overlap')
                self.mapping = mmap.mmap(self.fd, DMA_BYTES, flags=mmap.MAP_SHARED,
                                         prot=mmap.PROT_READ | mmap.PROT_WRITE)
        except BaseException:
            self.close(check=False)
            raise

    def _line(self):
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError('Runtime exited before completing the frame; inspect '+str(self.prefix)+'.runtime.log')
        self.log.write(line)
        self.log.flush()
        return line.decode('ascii').strip()

    def infer(self, data):
        if self.index >= self.frames:
            raise ValueError('Runtime session is exhausted')
        if self.mode != 'pipe':
            import fcntl
            if data is None:
                if not self._prepared:
                    raise ValueError('DMA input was not filled')
            else:
                if len(data) != self.input_bytes:
                    raise ValueError('Wrong input length')
                view = memoryview(data)
                try:
                    offset = self.info['input_offset']
                    self.mapping[offset:offset+self.input_bytes] = view
                finally:
                    view.release()
            # Match the runtime's acquire barrier, including across A9 cores.
            fcntl.ioctl(self.fd, TY_IOC_INPUT_PUBLISH)
            write_all(self.process.stdin, b'F\n')
        else:
            if data is None or len(data) != INPUT_BYTES:
                raise ValueError('Wrong pipe input length')
            write_all(self.process.stdin, data)
        expected = self.index+1
        line = self._line()
        matched = re.fullmatch(r'PASS_LINUX_PL_FRAME frame=(\d+) elapsed_ms=\d+ PL_convolutions=24 HP_idle=1', line)
        if matched is None or int(matched.group(1)) != expected:
            raise RuntimeError('Runtime frame acknowledgement differs: '+line)
        self.index = expected
        self._prepared = False
        self.last_network_ms = int(re.search(r'elapsed_ms=(\d+)',line).group(1))
        if self.mode != 'pipe':
            start = self.info['output_offset']
            result = self.mapping[start:start+self.info['output_bytes']]
        else:
            result = Path(str(self.prefix)+'.%04d.final.bin' % expected).read_bytes()
        if len(result) != POSITIONS*5*4:
            raise RuntimeError('Incomplete runtime output')
        return result

    def input_view(self):
        if self.mode == 'pipe' or self.mapping is None or self._prepared or self.index >= self.frames:
            raise RuntimeError('DMA input view is not available')
        self._prepared = True
        offset = self.info['input_offset']
        return memoryview(self.mapping)[offset:offset+self.input_bytes]

    def close(self, check=True, allow_partial=False):
        code = None
        if self.process is not None:
            if self.process.stdin and not self.process.stdin.closed:
                try:
                    if allow_partial and self.mode!='pipe' and self.index<self.frames:
                        write_all(self.process.stdin,b'Q\n')
                    self.process.stdin.close()
                except BrokenPipeError:
                    pass
            # Closing the command pipe makes a waiting runtime leave before
            # another frame starts. An in-flight ioctl is allowed to drain.
            code = self.process.wait()
            self.process.stdout.close()
            self.process = None
        if self.mapping is not None:
            self.mapping.close()
            self.mapping = None
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None
        if not self.log.closed:self.log.close()
        if check and (code != 0 or (not allow_partial and self.index != self.frames)):
            raise RuntimeError('Runtime sequence did not finish successfully')

    def __enter__(self):
        return self

    def __exit__(self, kind, value, traceback):
        self.close(check=kind is None)
