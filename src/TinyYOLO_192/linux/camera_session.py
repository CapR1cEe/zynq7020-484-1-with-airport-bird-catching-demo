"""Persistent, bounded V4L2 image stream with explicit frame ownership."""
import io
from pathlib import Path
import struct
import subprocess
from PIL import Image


def exact(stream,count):
    chunks=[]
    while count:
        part=stream.read(count)
        if not part:raise RuntimeError('Camera stream ended mid-frame')
        chunks.append(part);count-=len(part)
    return b''.join(chunks)


class CameraSession:
    def __init__(self,executable,device,width=320,height=240):
        self.process=subprocess.Popen([str(Path(executable)),device,str(width),str(height)],
                                      stdin=subprocess.PIPE,stdout=subprocess.PIPE,bufsize=0)
        self.sequence=None

    def capture(self):
        self.process.stdin.write(b'F\n');self.process.stdin.flush()
        magic,size,sequence,w,h,fourcc,stamp=struct.unpack('<4sIIIIIQ',exact(self.process.stdout,32))
        if magic!=b'TYF1' or not 0<size<=64*1024*1024 or not 0<w<=4096 or not 0<h<=4096:
            raise RuntimeError('Invalid camera stream header')
        if self.sequence is not None and sequence==self.sequence:raise RuntimeError('Repeated camera sequence')
        self.sequence=sequence
        with Image.open(io.BytesIO(exact(self.process.stdout,size))) as source:
            if source.size!=(w,h):raise RuntimeError('Camera frame dimensions differ')
            image=source.convert('RGB')
        return image,dict(sequence=sequence,width=w,height=h,fourcc=fourcc,host_dequeue_us=stamp)

    def close(self):
        if self.process is None:return
        process=self.process
        try:
            try:process.stdin.close()
            except BrokenPipeError:pass
            try:status=process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill();process.wait()
                status=-1
        finally:
            process.stdout.close();self.process=None
        if status:raise RuntimeError('Camera stream failed: '+str(status))

    def __enter__(self):return self
    def __exit__(self,kind,value,tb):
        try:self.close()
        except Exception:
            if kind is None:raise
