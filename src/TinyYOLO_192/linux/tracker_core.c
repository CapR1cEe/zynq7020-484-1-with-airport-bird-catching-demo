/* Single-target zero-mean SAD tracker. No allocation or floating-point SIMD
 * requirement; Cortex-A9 and the host execute the same implementation. */
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <math.h>

#define SIDE 32
struct ty_tracker {
    int32_t valid, missed;
    float x,y,w,h,quality;
    uint8_t pattern[SIDE*SIDE];
};

static int inside(int width,int height,float x,float y,float w,float h)
{
    return isfinite(x)&&isfinite(y)&&isfinite(w)&&isfinite(h)&&w>=4&&h>=4&&
           x>=0&&y>=0&&x+w<=width&&y+h<=height;
}
static uint8_t sample(const uint8_t *image,int width,float x,float y)
{return image[(size_t)(int)y*(size_t)width+(size_t)(int)x];}

void ty_tracker_clear(struct ty_tracker *t){if(t)memset(t,0,sizeof(*t));}

int ty_tracker_seed(struct ty_tracker *t,const uint8_t *image,int width,int height,
                    float x,float y,float w,float h)
{
    int i,j;int64_t sum=0,square=0;
    if(!t||!image||width<1||height<1||!inside(width,height,x,y,w,h))return -1;
    ty_tracker_clear(t);
    for(j=0;j<SIDE;j++)for(i=0;i<SIDE;i++){
        int v=sample(image,width,x+(i+.5f)*w/SIDE,y+(j+.5f)*h/SIDE);
        t->pattern[j*SIDE+i]=(uint8_t)v;sum+=v;square+=v*v;
    }
    /* A uniform crop has no observable displacement. Ask detection to retry. */
    if(square*1024-sum*sum<INT64_C(1024)*1024*16)return 0;
    t->valid=1;t->x=x;t->y=y;t->w=w;t->h=h;t->quality=1.f;
    return 1;
}

static uint32_t cost(const struct ty_tracker *t,const uint8_t *image,int width,
                     float x,float y,float w,float h,int step)
{
    int i,j,count=0,sum_delta=0,mean_delta,index=0;
    int16_t differences[SIDE*SIDE];
    int columns[SIDE];
    uint32_t sad=0;
    for(i=0;i<SIDE;i+=step)columns[i]=(int)(x+(i+.5f)*w/SIDE);
    for(j=0;j<SIDE;j+=step)for(i=0;i<SIDE;i+=step){
        int row=(int)(y+(j+.5f)*h/SIDE);
        int delta=(int)t->pattern[j*SIDE+i]-(int)image[(size_t)row*width+columns[i]];
        differences[count++]=(int16_t)delta;sum_delta+=delta;
    }
    mean_delta=sum_delta/count;
    for(index=0;index<count;index++){
        int delta=(int)differences[index]-mean_delta;
        sad+=(uint32_t)(delta<0?-delta:delta);
    }
    return (sad*1024U)/(uint32_t)count;
}

int ty_tracker_update(struct ty_tracker *t,const uint8_t *image,int width,int height)
{
    static const float scales[3]={.95f,1.f,1.05f};
    uint32_t best=UINT32_MAX;float bx=0,by=0,bw=0,bh=0,cx,cy;
    int dx,dy,s;
    if(!t||!image||!t->valid||width<1||height<1)return 0;
    cx=t->x+t->w*.5f;cy=t->y+t->h*.5f;
    for(s=0;s<3;s++)for(dy=-16;dy<=16;dy++)for(dx=-16;dx<=16;dx++){
        float w=t->w*scales[s],h=t->h*scales[s],x=cx+dx-w*.5f,y=cy+dy-h*.5f;
        uint32_t score;
        if(!inside(width,height,x,y,w,h))continue;
        score=cost(t,image,width,x,y,w,h,4);
        if(score<best){best=score;bx=x;by=y;bw=w;bh=h;}
    }
    if(best!=UINT32_MAX){
        float coarse_x=bx,coarse_y=by;
        best=UINT32_MAX;
        for(dy=-3;dy<=3;dy++)for(dx=-3;dx<=3;dx++){
            float x=coarse_x+dx,y=coarse_y+dy;uint32_t score;
            if(!inside(width,height,x,y,bw,bh))continue;
            score=cost(t,image,width,x,y,bw,bh,1);
            if(score<best){best=score;bx=x;by=y;}
        }
    }
    t->quality=best==UINT32_MAX?0.f:fmaxf(0.f,1.f-(float)best/(1024.f*64.f));
    /* An occluded/ambiguous target must not produce a steering command. */
    if(t->quality<.60f){t->missed++;t->valid=0;return 0;}
    t->x=bx;t->y=by;t->w=bw;t->h=bh;t->missed=0;
    /* Preserve the detector-seeded template to avoid gradual background drift. */
    return 1;
}
