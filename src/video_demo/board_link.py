"""Exclusive USB UART connection with acknowledged shell commands and uploads."""
import argparse
import base64
import hashlib
from pathlib import Path
import re
import shlex
import sys
import time
import uuid

sys.path.insert(0, str(Path(__file__).parent / 'serial_packages'))
import serial


class BoardLink:
    def __init__(self, port='COM5'):
        self.serial = serial.Serial()
        self.serial.port = port
        self.serial.baudrate = 115200
        self.serial.timeout = .1
        self.serial.write_timeout = 4
        self.serial.dtr = False
        self.serial.rts = False
        self.serial.open()
        self.serial.write(b'\r')
        end = time.monotonic() + 4
        data = b''
        while time.monotonic() < end:
            data += self.serial.read(self.serial.in_waiting or 1)
            if re.search(rb'root@[^\r\n]*#\s*$', data):
                break
        else:
            self.serial.close()
            raise RuntimeError('Board shell is busy or unavailable; no interrupt sent')
        self.command('stty -echo -ixon -ixoff')

    def command(self, command, timeout=12, check=True):
        marker = 'CX' + uuid.uuid4().hex[:12]
        text = command + "; printf '\\n" + marker + ":%s\\n' $?\r"
        if len(text.encode('utf-8')) > 950:
            raise ValueError('Upload long shell scripts as files')
        self.serial.write(text.encode('utf-8'))
        data = b''
        end = time.monotonic() + timeout
        pattern = re.compile(rb'\r?\n' + marker.encode() + rb':(\d+)\r?\n')
        while time.monotonic() < end:
            data += self.serial.read(self.serial.in_waiting or 1)
            match = pattern.search(data)
            if match:
                output = data[:match.start()].decode('utf-8', 'replace').strip()
                if check and int(match.group(1)):
                    raise RuntimeError('Board command failed: ' + output)
                return output
        raise TimeoutError('Board command timed out: ' + data[-1200:].decode('utf-8', 'replace'))

    def upload(self, source, destination):
        data = Path(source).read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        temporary = destination + '.upload'
        quoted = shlex.quote(temporary)
        self.command(': > ' + quoted + '.b64')
        encoded = base64.b64encode(data).decode('ascii')
        for offset in range(0, len(encoded), 640):
            self.command("printf '%s' '" + encoded[offset:offset+640] + "' >> " + quoted + '.b64')
        output = self.command('base64 -d ' + quoted + '.b64 > ' + quoted + '; sha256sum ' + quoted)
        if digest not in output:
            raise RuntimeError('Uploaded file checksum differs')
        self.command('command mv -f ' + quoted + ' ' + shlex.quote(destination) +
                     '; command rm -f ' + quoted + '.b64')
        return digest

    def close(self):
        if self.serial.is_open:
            try:
                self.command('stty echo', timeout=2)
            except Exception:
                pass
            self.serial.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', default='COM5')
    parser.add_argument('--command')
    parser.add_argument('--upload', type=Path)
    parser.add_argument('--destination')
    parser.add_argument('--timeout', type=float, default=12)
    args = parser.parse_args()
    link = BoardLink(args.port)
    try:
        if args.upload:
            print('UPLOAD_SHA256=' + link.upload(args.upload, args.destination))
        if args.command:
            print(link.command(args.command, args.timeout), flush=True)
    finally:
        link.close()
