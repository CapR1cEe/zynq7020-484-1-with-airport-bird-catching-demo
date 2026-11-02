/* Stream one fresh V4L2 frame. Native Xillinux build: gcc -O2 -Wall -Wextra -Werror
 * -D_POSIX_C_SOURCE=200809L camera_capture.c -o camera_capture
 * Pass "-" as output to stream PPM or JPEG bytes over stdout without a temp file. */
#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

static int xio(int fd, unsigned long request, void *arg)
{ int r; do { r=ioctl(fd,request,arg); } while(r<0 && errno==EINTR); return r; }
static unsigned char clip(int v) {return (unsigned char)(v<0?0:v>255?255:v);}
static void yuv(unsigned char *dst,int yy,int u,int v,int full,int bt709)
{
    int c=full?yy:yy-16,d=u-128,e=v-128;
    int gain=full?256:298;
    int rv=bt709?(full?403:459):(full?359:409);
    int gu=bt709?(full?48:55):(full?88:100);
    int gv=bt709?(full?120:136):(full?183:208);
    int bu=bt709?(full?475:541):(full?454:516);
    dst[0]=clip((gain*c+rv*e+128)>>8);
    dst[1]=clip((gain*c-gu*d-gv*e+128)>>8);
    dst[2]=clip((gain*c+bu*d+128)>>8);
}
int main(int argc,char **argv)
{
    int fd=-1,rc=1,streaming=0;unsigned i,seen=0,nmap=0,w=640,h=480;
    unsigned chosen=0,flags;FILE *out=NULL;unsigned char *rgb_row=NULL;
    struct v4l2_capability cap;struct v4l2_format fmt;
    struct v4l2_requestbuffers req;struct v4l2_buffer buf;
    void *maps[4]={0};size_t lengths[4]={0};
    enum v4l2_buf_type type=V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if(argc!=3 && argc!=5){fprintf(stderr,"Usage: %s /dev/videoN capture.image|- [width height]\n",argv[0]);return 64;}
    if(argc==5){char *end;w=(unsigned)strtoul(argv[3],&end,10);if(*end)return 64;
        h=(unsigned)strtoul(argv[4],&end,10);if(*end || !w || !h || w>4096 || h>4096)return 64;}
    fd=open(argv[1],O_RDWR|O_NONBLOCK|O_CLOEXEC);if(fd<0){perror(argv[1]);goto done;}
    memset(&cap,0,sizeof(cap));if(xio(fd,VIDIOC_QUERYCAP,&cap)){perror("QUERYCAP");goto done;}
    flags=(cap.capabilities&V4L2_CAP_DEVICE_CAPS)?cap.device_caps:cap.capabilities;
    if(!(flags&V4L2_CAP_VIDEO_CAPTURE) || !(flags&V4L2_CAP_STREAMING)){
        fprintf(stderr,"Single-plane streaming V4L2 capture is required\n");goto done;}
    for(i=0;;i++){
        struct v4l2_fmtdesc d;memset(&d,0,sizeof(d));d.index=i;d.type=type;
        if(xio(fd,VIDIOC_ENUM_FMT,&d)){if(errno==EINVAL)break;perror("ENUM_FMT");goto done;}
        if(d.pixelformat==V4L2_PIX_FMT_YUYV)chosen=d.pixelformat;
        else if(!chosen && (d.pixelformat==V4L2_PIX_FMT_MJPEG || d.pixelformat==V4L2_PIX_FMT_RGB24))chosen=d.pixelformat;
    }
    if(!chosen){fprintf(stderr,"Camera needs YUYV, MJPEG or RGB24 output; inspect its UVC format settings\n");goto done;}
    memset(&fmt,0,sizeof(fmt));fmt.type=type;fmt.fmt.pix.width=w;fmt.fmt.pix.height=h;
    fmt.fmt.pix.pixelformat=chosen;fmt.fmt.pix.field=V4L2_FIELD_ANY;
    if(xio(fd,VIDIOC_S_FMT,&fmt)){perror("S_FMT");goto done;}
    w=fmt.fmt.pix.width;h=fmt.fmt.pix.height;chosen=fmt.fmt.pix.pixelformat;
    if(!w || !h || w>4096 || h>4096 ||
       (chosen!=V4L2_PIX_FMT_YUYV && chosen!=V4L2_PIX_FMT_MJPEG && chosen!=V4L2_PIX_FMT_RGB24) ||
       (chosen==V4L2_PIX_FMT_YUYV && (w&1U))){fprintf(stderr,"Unsupported negotiated format\n");goto done;}
    memset(&req,0,sizeof(req));req.type=type;req.memory=V4L2_MEMORY_MMAP;req.count=4;
    if(xio(fd,VIDIOC_REQBUFS,&req) || req.count<2){perror("REQBUFS");goto done;}
    for(i=0;i<req.count && i<4;i++){
        memset(&buf,0,sizeof(buf));buf.type=type;buf.memory=req.memory;buf.index=i;
        if(xio(fd,VIDIOC_QUERYBUF,&buf)){perror("QUERYBUF");goto done;}
        maps[i]=mmap(NULL,buf.length,PROT_READ|PROT_WRITE,MAP_SHARED,fd,buf.m.offset);
        if(maps[i]==MAP_FAILED){maps[i]=NULL;perror("mmap");goto done;}
        lengths[i]=buf.length;nmap++;
        if(xio(fd,VIDIOC_QBUF,&buf)){perror("QBUF");goto done;}
    }
    if(xio(fd,VIDIOC_STREAMON,&type)){perror("STREAMON");goto done;}streaming=1;
    while(seen<3){
        struct pollfd event={fd,POLLIN,0};int ready;
        do{ready=poll(&event,1,5000);}while(ready<0 && errno==EINTR);
        if(ready<=0 || (event.revents&(POLLERR|POLLHUP|POLLNVAL))){fprintf(stderr,"Camera timeout or disconnect\n");goto done;}
        memset(&buf,0,sizeof(buf));buf.type=type;buf.memory=req.memory;
        if(xio(fd,VIDIOC_DQBUF,&buf)){if(errno==EAGAIN)continue;perror("DQBUF");goto done;}
        if(buf.index>=nmap || buf.bytesused>lengths[buf.index] || (buf.flags&V4L2_BUF_FLAG_ERROR)){
            fprintf(stderr,"Invalid V4L2 frame\n");goto done;}
        if(++seen<3){if(xio(fd,VIDIOC_QBUF,&buf)){perror("QBUF");goto done;}}
    }
    if(strcmp(argv[2],"-")==0){
        out=stdout;
        if(setvbuf(out,NULL,_IOFBF,1U<<20)!=0){fprintf(stderr,"Cannot buffer capture stream\n");goto done;}
    }else{
        int output=open(argv[2],O_WRONLY|O_CREAT|O_EXCL,0644);
        if(output<0){perror(argv[2]);goto done;}out=fdopen(output,"wb");if(!out){close(output);goto done;}
    }
    if(chosen==V4L2_PIX_FMT_MJPEG){
        if(buf.bytesused<4 || fwrite(maps[buf.index],1,buf.bytesused,out)!=buf.bytesused)goto done;
    }else{
        unsigned stride=fmt.fmt.pix.bytesperline,min_stride=w*(chosen==V4L2_PIX_FMT_YUYV?2U:3U),y,x;
        size_t row_bytes=(size_t)w*3U;
        int full=fmt.fmt.pix.quantization==V4L2_QUANTIZATION_FULL_RANGE ||
            (fmt.fmt.pix.quantization==V4L2_QUANTIZATION_DEFAULT && fmt.fmt.pix.colorspace==V4L2_COLORSPACE_JPEG);
        unsigned enc=fmt.fmt.pix.ycbcr_enc;
        int bt709=enc==V4L2_YCBCR_ENC_709 || (enc==V4L2_YCBCR_ENC_DEFAULT && fmt.fmt.pix.colorspace==V4L2_COLORSPACE_REC709);
        if(chosen==V4L2_PIX_FMT_YUYV && enc!=V4L2_YCBCR_ENC_DEFAULT && enc!=V4L2_YCBCR_ENC_601 && enc!=V4L2_YCBCR_ENC_709){fprintf(stderr,"Unsupported YCbCr matrix\n");goto done;}
        if(stride<min_stride || (uint64_t)(h-1U)*stride+min_stride>buf.bytesused){fprintf(stderr,"Truncated frame\n");goto done;}
        rgb_row=(unsigned char*)malloc(row_bytes);
        if(!rgb_row){perror("malloc RGB row");goto done;}
        if(fprintf(out,"P6\n%u %u\n255\n",w,h)<0)goto done;
        for(y=0;y<h;y++){
            const unsigned char *row=(const unsigned char*)maps[buf.index]+y*stride;
            if(chosen==V4L2_PIX_FMT_RGB24)memcpy(rgb_row,row,row_bytes);
            else for(x=0;x<w;x+=2){
                yuv(rgb_row+3U*x,row[2U*x],row[2U*x+1U],row[2U*x+3U],full,bt709);
                yuv(rgb_row+3U*(x+1U),row[2U*x+2U],row[2U*x+1U],row[2U*x+3U],full,bt709);
            }
            if(fwrite(rgb_row,1,row_bytes,out)!=row_bytes)goto done;
        }
    }
    if(out==stdout){if(fflush(out)){out=NULL;perror("flush capture stream");goto done;}out=NULL;}
    else if(fclose(out)){out=NULL;perror("close output");goto done;}else out=NULL;
    fprintf(stderr,"CAPTURE_PASS width=%u height=%u fourcc=%c%c%c%c sequence=%u\n",w,h,
           chosen&255,(chosen>>8)&255,(chosen>>16)&255,(chosen>>24)&255,buf.sequence);rc=0;
done:
    if(out && out!=stdout)fclose(out);
    free(rgb_row);
    if(streaming)xio(fd,VIDIOC_STREAMOFF,&type);
    for(i=0;i<nmap;i++)munmap(maps[i],lengths[i]);
    if(fd>=0)close(fd);
    return rc;
}
