#ifndef TINYYOLO_INPUT_H
#define TINYYOLO_INPUT_H
#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>
/* Read a complete frame before any tensor processing or PL submission. */
static inline int ty_stream_read(void *dst,size_t bytes)
{
    uint8_t *p=dst;
    while(bytes) {
        ssize_t n=read(STDIN_FILENO,p,bytes);
        if(n<0 && errno==EINTR)continue;
        if(n<=0){fprintf(stderr,"Incomplete streamed frame; inference not started\n");return 1;}
        p+=n;bytes-=(size_t)n;
    }
    return 0;
}
static inline int ty_shared_input_wait(void)
{
    char command[2];
    if(ty_stream_read(command,sizeof(command)))return 1;
    if(command[0]=='Q' && command[1]=='\n')return 2;
    if(command[0]!='F' || command[1]!='\n') {
        fprintf(stderr,"Invalid shared-input command; inference not started\n");return 1;
    }
    /* Producer calls TY_IOC_INPUT_PUBLISH before writing F to the pipe.
     * Acquire before reading its coherent mapping on this Cortex-A9 core. */
    __sync_synchronize();
    return 0;
}
#endif
