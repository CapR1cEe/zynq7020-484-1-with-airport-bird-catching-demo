/* Persistent V4L2 capture. One F\n command returns one length-delimited image.
 * Reuses MMAP buffers and drains queued stale frames before each response. */
#define main tinyyolo_oneshot_capture_main
#include "camera_capture.c"
#undef main
#include <time.h>

static void little32(unsigned char *out,uint32_t value)
{unsigned i;for(i=0;i<4;i++)out[i]=(unsigned char)(value>>(i*8));}

int main(int argc,char **argv)
{
    int fd=-1,rc=1,streaming=0;unsigned i,nmap=0,w=640,h=480,chosen=0,flags;
    struct v4l2_capability cap;struct v4l2_format fmt;
    struct v4l2_requestbuffers req;struct v4l2_buffer buf;
    void *maps[4]={0};size_t lengths[4]={0};unsigned char *payload=NULL;
    enum v4l2_buf_type type=V4L2_BUF_TYPE_VIDEO_CAPTURE;
    char command[4];unsigned warmup=2;
    if(argc!=2 && argc!=4){fprintf(stderr,"Usage: %s /dev/videoN [width height]\n",argv[0]);return 64;}
    if(argc==4){char *end;w=(unsigned)strtoul(argv[2],&end,10);if(*end)return 64;
        h=(unsigned)strtoul(argv[3],&end,10);if(*end||!w||!h||w>4096||h>4096)return 64;}
    fd=open(argv[1],O_RDWR|O_NONBLOCK|O_CLOEXEC);if(fd<0){perror(argv[1]);goto done;}
    memset(&cap,0,sizeof(cap));if(xio(fd,VIDIOC_QUERYCAP,&cap)){perror("QUERYCAP");goto done;}
    flags=(cap.capabilities&V4L2_CAP_DEVICE_CAPS)?cap.device_caps:cap.capabilities;
    if(!(flags&V4L2_CAP_VIDEO_CAPTURE)||!(flags&V4L2_CAP_STREAMING))goto done;
    for(i=0;;i++){
        struct v4l2_fmtdesc d;memset(&d,0,sizeof(d));d.index=i;d.type=type;
        if(xio(fd,VIDIOC_ENUM_FMT,&d)){if(errno==EINVAL)break;perror("ENUM_FMT");goto done;}
        if(d.pixelformat==V4L2_PIX_FMT_YUYV)chosen=d.pixelformat;
        else if(!chosen&&(d.pixelformat==V4L2_PIX_FMT_MJPEG||d.pixelformat==V4L2_PIX_FMT_RGB24))chosen=d.pixelformat;
    }
    if(!chosen){fprintf(stderr,"No supported UVC pixel format\n");goto done;}
    memset(&fmt,0,sizeof(fmt));fmt.type=type;fmt.fmt.pix.width=w;fmt.fmt.pix.height=h;
    fmt.fmt.pix.pixelformat=chosen;fmt.fmt.pix.field=V4L2_FIELD_ANY;
    if(xio(fd,VIDIOC_S_FMT,&fmt)){perror("S_FMT");goto done;}
    w=fmt.fmt.pix.width;h=fmt.fmt.pix.height;chosen=fmt.fmt.pix.pixelformat;
    if(!w||!h||w>4096||h>4096||(chosen!=V4L2_PIX_FMT_YUYV&&chosen!=V4L2_PIX_FMT_MJPEG&&chosen!=V4L2_PIX_FMT_RGB24)||
       (chosen==V4L2_PIX_FMT_YUYV&&(w&1U)))goto done;
    payload=malloc((size_t)w*h*3U+128U);if(!payload)goto done;
    memset(&req,0,sizeof(req));req.type=type;req.memory=V4L2_MEMORY_MMAP;req.count=4;
    if(xio(fd,VIDIOC_REQBUFS,&req)||req.count<2||req.count>4){perror("REQBUFS");goto done;}
    for(i=0;i<req.count;i++){
        memset(&buf,0,sizeof(buf));buf.type=type;buf.memory=req.memory;buf.index=i;
        if(xio(fd,VIDIOC_QUERYBUF,&buf)){perror("QUERYBUF");goto done;}
        maps[i]=mmap(NULL,buf.length,PROT_READ|PROT_WRITE,MAP_SHARED,fd,buf.m.offset);
        if(maps[i]==MAP_FAILED){maps[i]=NULL;perror("mmap");goto done;}
        lengths[i]=buf.length;nmap++;
        if(xio(fd,VIDIOC_QBUF,&buf)){perror("QBUF");goto done;}
    }
    if(xio(fd,VIDIOC_STREAMON,&type)){perror("STREAMON");goto done;}streaming=1;
    if(setvbuf(stdout,NULL,_IOFBF,1U<<20))goto done;
    while(fgets(command,sizeof(command),stdin)){
        size_t bytes;const void *data;unsigned char header[32];struct timespec stamp;
        if(strcmp(command,"F\n")){fprintf(stderr,"Invalid capture command\n");goto done;}
        for(;;){
            struct pollfd event={fd,POLLIN,0};int ready;
            do{ready=poll(&event,1,5000);}while(ready<0&&errno==EINTR);
            if(ready<=0||(event.revents&(POLLERR|POLLHUP|POLLNVAL)))goto done;
            memset(&buf,0,sizeof(buf));buf.type=type;buf.memory=req.memory;
            if(xio(fd,VIDIOC_DQBUF,&buf)){if(errno==EAGAIN)continue;perror("DQBUF");goto done;}
            if(buf.index>=nmap||buf.bytesused>lengths[buf.index]||(buf.flags&V4L2_BUF_FLAG_ERROR))goto done;
            if(warmup){warmup--;if(xio(fd,VIDIOC_QBUF,&buf))goto done;continue;}
            /* Bounded drain: keep the latest already-completed frame. */
            for(i=1;i<nmap;i++){
                struct v4l2_buffer next;memset(&next,0,sizeof(next));next.type=type;next.memory=req.memory;
                if(xio(fd,VIDIOC_DQBUF,&next)){if(errno==EAGAIN)break;perror("drain DQBUF");goto done;}
                if(next.index>=nmap||next.bytesused>lengths[next.index]||(next.flags&V4L2_BUF_FLAG_ERROR))goto done;
                if(xio(fd,VIDIOC_QBUF,&buf))goto done;
                buf=next;
            }
            break;
        }
        if(clock_gettime(CLOCK_MONOTONIC,&stamp))goto done;
        if(chosen==V4L2_PIX_FMT_MJPEG){data=maps[buf.index];bytes=buf.bytesused;if(bytes<4||bytes>64U*1024U*1024U)goto done;}
        else{
            unsigned stride=fmt.fmt.pix.bytesperline,min_stride=w*(chosen==V4L2_PIX_FMT_YUYV?2U:3U),x,y;
            int full=fmt.fmt.pix.quantization==V4L2_QUANTIZATION_FULL_RANGE||
                (fmt.fmt.pix.quantization==V4L2_QUANTIZATION_DEFAULT&&fmt.fmt.pix.colorspace==V4L2_COLORSPACE_JPEG);
            unsigned enc=fmt.fmt.pix.ycbcr_enc;
            int bt709=enc==V4L2_YCBCR_ENC_709||(enc==V4L2_YCBCR_ENC_DEFAULT&&fmt.fmt.pix.colorspace==V4L2_COLORSPACE_REC709);
            int prefix=snprintf((char*)payload,128,"P6\n%u %u\n255\n",w,h);
            if(prefix<=0||prefix>=128||stride<min_stride||(uint64_t)(h-1U)*stride+min_stride>buf.bytesused)goto done;
            if(chosen==V4L2_PIX_FMT_YUYV&&enc!=V4L2_YCBCR_ENC_DEFAULT&&enc!=V4L2_YCBCR_ENC_601&&enc!=V4L2_YCBCR_ENC_709)goto done;
            for(y=0;y<h;y++){
                const unsigned char *row=(const unsigned char*)maps[buf.index]+y*stride;
                unsigned char *dest=payload+prefix+(size_t)y*w*3U;
                if(chosen==V4L2_PIX_FMT_RGB24)memcpy(dest,row,(size_t)w*3U);
                else for(x=0;x<w;x+=2){
                    yuv(dest+3U*x,row[2U*x],row[2U*x+1U],row[2U*x+3U],full,bt709);
                    yuv(dest+3U*(x+1U),row[2U*x+2U],row[2U*x+1U],row[2U*x+3U],full,bt709);
                }
            }
            bytes=(size_t)prefix+(size_t)w*h*3U;data=payload;
        }
        memcpy(header,"TYF1",4);little32(header+4,(uint32_t)bytes);little32(header+8,buf.sequence);
        little32(header+12,w);little32(header+16,h);little32(header+20,chosen);
        {uint64_t us=(uint64_t)stamp.tv_sec*1000000U+(uint64_t)stamp.tv_nsec/1000U;
         little32(header+24,(uint32_t)us);little32(header+28,(uint32_t)(us>>32));}
        if(fwrite(header,1,sizeof(header),stdout)!=sizeof(header)||fwrite(data,1,bytes,stdout)!=bytes||fflush(stdout))goto done;
        if(xio(fd,VIDIOC_QBUF,&buf))goto done;
    }
    if(ferror(stdin))goto done;
    rc=0;
done:
    free(payload);if(streaming)xio(fd,VIDIOC_STREAMOFF,&type);
    for(i=0;i<nmap;i++)munmap(maps[i],lengths[i]);
    if(fd>=0)close(fd);
    return rc;
}
