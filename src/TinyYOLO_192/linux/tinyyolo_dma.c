// SPDX-License-Identifier: GPL-2.0
/* G228 polling driver. HP0 is noncoherent; allocate only from reserved DMA RAM.
 * There is no AXI abort. A timed-out transaction quarantines the device and
 * leaves its DMA allocation and clocks pinned until a coordinated board reset.
 */
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/of.h>
#include <linux/of_reserved_mem.h>
#include <linux/clk.h>
#include <linux/dma-mapping.h>
#include <linux/miscdevice.h>
#include <linux/fs.h>
#include <linux/mm.h>
#include <linux/uaccess.h>
#include <linux/mutex.h>
#include <linux/delay.h>
#include <linux/ktime.h>
#include <linux/slab.h>
#include <linux/kref.h>
#include <linux/io.h>
#include <linux/genalloc.h>
#include "tinyyolo_validate.h"
struct ty_device {
    struct device *dev;
    void __iomem *regs;
    struct clk *fclk, *aclk;
    struct miscdevice misc;
    struct mutex lock;
    struct kref refs;
    atomic_t opened;
    resource_size_t mmio_start, mmio_bytes;
    void *cpu;
    dma_addr_t dma;
    struct gen_pool *ocm_pool;
    unsigned long ocm_allocation, ocm_virtual;
    phys_addr_t ocm_physical;
    u32 ocm_bytes;
    bool faulted, removed, dma_active;
};
/* Optional CPU lookup-table SRAM. The Zynq pool allocator already excludes
 * the SMP trampoline and allocations used for suspend. Never map fixed OCM
 * addresses or remap SLCR banks here. This SRAM is not a PL DMA buffer. */
static void ty_ocm_release(struct ty_device *d)
{
#ifdef CONFIG_GENERIC_ALLOCATOR
    if(d->ocm_allocation)
        gen_pool_free(d->ocm_pool,d->ocm_allocation,TY_OCM_BYTES+PAGE_SIZE);
#endif
    d->ocm_allocation=0; d->ocm_bytes=0;
}
static void ty_ocm_allocate(struct ty_device *d)
{
#if defined(CONFIG_GENERIC_ALLOCATOR) && defined(CONFIG_ARM) && !defined(CONFIG_ARM64) && !defined(CONFIG_ARM_LPAE)
    u64 physical, end;
    if(!of_find_property(d->dev->of_node,"tinyyolo,ocm-pool",NULL)) return;
    d->ocm_pool=of_gen_pool_get(d->dev->of_node,"tinyyolo,ocm-pool",0);
    if(!d->ocm_pool) {
        dev_warn(d->dev,"OCM pool not bound; CPU lookup cache uses normal RAM\n");
        return;
    }
    /* The pool granularity is 32 bytes and its first chunk can start after
     * a small SMP trampoline. Allocate padding, expose complete owned pages. */
    d->ocm_allocation=gen_pool_alloc(d->ocm_pool,TY_OCM_BYTES+PAGE_SIZE);
    if(!d->ocm_allocation) {
        dev_warn(d->dev,"OCM pool has no free lookup-cache span\n");
        return;
    }
    d->ocm_virtual=ALIGN(d->ocm_allocation,PAGE_SIZE);
    d->ocm_physical=gen_pool_virt_to_phys(d->ocm_pool,d->ocm_virtual);
    physical=(u64)d->ocm_physical; end=physical+TY_OCM_BYTES;
    if(physical>0xffffffffULL || end<=physical || !IS_ALIGNED(physical,PAGE_SIZE) ||
       !((physical<0x00040000ULL && end<=0x00040000ULL) ||
         (physical>=0xfffc0000ULL && end<=0x100000000ULL))) {
        dev_warn(d->dev,"Rejecting unexpected OCM pool address\n");
        ty_ocm_release(d);
        return;
    }
    memset_io((void __iomem *)d->ocm_virtual,0,TY_OCM_BYTES);
    d->ocm_bytes=TY_OCM_BYTES;
    dev_info(d->dev,"CPU OCM lookup cache: %u bytes from kernel gen_pool\n",d->ocm_bytes);
#endif
}
static bool ty_drained(struct ty_device *d)
{
    u32 status=readl(d->regs+4);
    return (status==0U || status==2U || status==4U) && readl(d->regs+0x84)==1U;
}
/* A VMA can outlive the file descriptor that created it. Hold a kref for the
 * initial mapping and for every forked VMA, so remove/close cannot unmap the
 * registers or free the coherent DMA while userspace still has a mapping. */
static void ty_destroy(struct kref *ref)
{
    struct ty_device *d=container_of(ref,struct ty_device,refs);
    if (d->dma_active || !ty_drained(d)) {
        dev_err(d->dev,"DMA quarantine: retaining device, MMIO, DMA and clocks until board reset\n");
        return;
    }
    ty_ocm_release(d);
    dma_free_coherent(d->dev,TY_DMA_BYTES,d->cpu,d->dma);
    of_reserved_mem_device_release(d->dev);
    clk_disable_unprepare(d->aclk); clk_disable_unprepare(d->fclk);
    clk_put(d->aclk); clk_put(d->fclk);
    iounmap(d->regs);
    release_mem_region(d->mmio_start,d->mmio_bytes);
    put_device(d->dev);
    kfree(d);
}
static void ty_vma_open(struct vm_area_struct *vma)
{
    struct ty_device *d=vma->vm_private_data;
    if (d) kref_get(&d->refs);
}
static void ty_vma_close(struct vm_area_struct *vma)
{
    struct ty_device *d=vma->vm_private_data;
    if (d) kref_put(&d->refs,ty_destroy);
}
static const struct vm_operations_struct ty_vm_ops={
    .open=ty_vma_open,
    .close=ty_vma_close,
};
static int ty_open(struct inode *inode, struct file *file)
{
    struct ty_device *d=container_of(file->private_data,struct ty_device,misc);
    int rc;
    mutex_lock(&d->lock);
    if (d->removed) rc=-ENODEV;
    else if (d->faulted) rc=-EIO;
    else if (atomic_cmpxchg(&d->opened,0,1)) rc=-EBUSY;
    else {
        kref_get(&d->refs); file->private_data=d;
        rc=nonseekable_open(inode,file);
        if (rc) {atomic_set(&d->opened,0);kref_put(&d->refs,ty_destroy);}
    }
    mutex_unlock(&d->lock);
    return rc;
}
static int ty_release(struct inode *inode, struct file *file)
{
    struct ty_device *d=file->private_data;
    (void)inode;
    mutex_lock(&d->lock);
    if (!ty_drained(d)) d->faulted=true;
    atomic_set(&d->opened,0);
    mutex_unlock(&d->lock);
    kref_put(&d->refs,ty_destroy);
    return 0;
}
static int ty_mmap(struct file *file, struct vm_area_struct *vma)
{
    struct ty_device *d=file->private_data;
    int rc;
    mutex_lock(&d->lock);
    if (!(vma->vm_flags&VM_SHARED) || (vma->vm_flags&VM_EXEC) ||
        d->faulted || d->removed) rc=-EINVAL;
    else {
        vma->vm_flags|=VM_DONTEXPAND|VM_DONTDUMP;
        vma->vm_flags&=~VM_MAYEXEC;
        if(!vma->vm_pgoff && vma->vm_end-vma->vm_start==TY_DMA_BYTES)
            rc=dma_mmap_coherent(d->dev,vma,d->cpu,d->dma,TY_DMA_BYTES);
        else if(d->ocm_bytes && vma->vm_pgoff==(TY_OCM_MMAP_OFFSET>>PAGE_SHIFT) &&
                vma->vm_end-vma->vm_start==d->ocm_bytes) {
#if defined(CONFIG_ARM) && !defined(CONFIG_ARM64) && !defined(CONFIG_ARM_LPAE)
            /* Match devm_ioremap_resource's ARMv7 short-descriptor MT_DEVICE
             * mapping. A cacheable or Normal-NC alias would be incorrect.
             * This is deliberately restricted to the target Cortex-A9 MMU. */
            vma->vm_page_prot=__pgprot_modify(vma->vm_page_prot,L_PTE_MT_MASK,
                L_PTE_MT_DEV_SHARED|L_PTE_SHARED|L_PTE_XN);
            vma->vm_flags|=VM_IO|VM_PFNMAP;
            rc=remap_pfn_range(vma,vma->vm_start,
                d->ocm_physical>>PAGE_SHIFT,d->ocm_bytes,vma->vm_page_prot);
#else
            rc=-ENOTSUPP;
#endif
        } else rc=-EINVAL;
        if (!rc) {
            vma->vm_ops=&ty_vm_ops;
            vma->vm_private_data=d;
            /* vm_ops->open is called for forked mappings, not this initial
             * VMA, so take the initial mapping reference explicitly. */
            kref_get(&d->refs);
        }
    }
    mutex_unlock(&d->lock);
    return rc;
}
static int ty_execute(struct ty_device *d,struct ty_submit *s)
{
    u32 i, status;
    u64 start, deadline, elapsed;
    if (d->faulted) return -EIO;
    if (!ty_validate_request(s,(u64)d->dma,TY_DMA_BYTES)) return -EINVAL;
    if (readl(d->regs+0x4c)!=TY_BUILD || !ty_drained(d) || readl(d->regs+4)==4U) {
        d->faulted=true; return -EIO;
    }
    if (!(s->options&4U)) {
        u32 c, co=s->cfg[8];
        for(c=0;c<co;c++) {
            u64 multiplier;
            u32 shift;
            memcpy(&multiplier,(u8 *)d->cpu+s->cfg[3]+8*c,8);
            memcpy(&shift,(u8 *)d->cpu+s->cfg[4]+4*c,4);
            if (!multiplier || shift<1U || shift>62U) return -EINVAL;
        }
    }
    dma_wmb();
    writel(2U,d->regs);
    if (readl(d->regs+4)!=0U || readl(d->regs+0x84)!=1U) {
        d->faulted=true; return -EIO;
    }
    writel(s->options,d->regs+0x44);
    writel((s->options&2U)?(u32)(d->dma+s->lut_offset):0U,d->regs+0x4c);
    for(i=0;i<15;i++) {
        u32 value=s->cfg[i];
        if (i<7) value=(u32)(d->dma+value);
        writel(value,d->regs+8+4*i);
    }
    start=ktime_get_ns(); deadline=start+(u64)s->timeout_ms*1000000ULL;
    /* A timeout has no AXI abort. Pin module code until HP0 is proven idle;
     * intentionally retain this reference on every uncertain exit. */
    if (!try_module_get(THIS_MODULE)) return -ENODEV;
    d->dma_active=true;
    writel(1U,d->regs);
    for(;;) {
        status=readl(d->regs+4);
        if ((status==2U || status==4U) && readl(d->regs+0x84)==1U) break;
        if ((status!=0U && status!=1U && status!=2U && status!=4U) || ktime_get_ns()>deadline) {
            d->faulted=true; return -ETIMEDOUT;
        }
        usleep_range(50,100);
    }
    d->dma_active=false;
    module_put(THIS_MODULE);
    dma_rmb(); elapsed=ktime_get_ns()-start;
    s->elapsed_ns_lo=(u32)elapsed; s->elapsed_ns_hi=(u32)(elapsed>>32);
    s->status=status; s->error=readl(d->regs+0x44); s->skipped=readl(d->regs);
    s->pl[0]=status; s->pl[1]=s->error;
    s->pl[2]=readl(d->regs+0x48); s->pl[3]=readl(d->regs+0x50);
    for(i=0;i<4;i++) s->pl[4+i]=readl(d->regs+0x54+4*i);
    s->pl[8]=s->elapsed_ns_lo; s->pl[9]=s->elapsed_ns_hi;
    for(i=0;i<6;i++) s->hp[i]=readl(d->regs+0x70+4*i);
    for(i=0;i<30;i++) s->phase[i]=readl(d->regs+0x88+4*i);
    if (status!=2U || s->error) { d->faulted=true; return 0; }
    writel(2U,d->regs);
    if (!ty_drained(d) || readl(d->regs+4)!=0U) {d->faulted=true;return -EIO;}
    return 0;
}
static long ty_ioctl(struct file *file,unsigned int cmd,unsigned long arg)
{
    struct ty_device *d=file->private_data;
    struct ty_submit submit;
    struct ty_info info;
    int rc=0;
    if (mutex_lock_interruptible(&d->lock)) return -ERESTARTSYS;
    if(d->removed) rc=-ENODEV;
    else if(cmd==TY_IOC_INFO) {
        memset(&info,0,sizeof(info)); info.abi=TY_ABI;
        info.build_id=readl(d->regs+0x4c); info.pl_hz=clk_get_rate(d->aclk);
        info.fclk_hz=clk_get_rate(d->fclk); info.dma_bytes=TY_DMA_BYTES; info.faulted=d->faulted;
        info.ocm_bytes=d->ocm_bytes;
        info.ocm_flags=d->ocm_bytes?TY_OCM_DEVICE_MAPPING:0U;
        if(copy_to_user((void __user *)arg,&info,sizeof(info))) rc=-EFAULT;
    } else if(cmd==TY_IOC_INPUT_PUBLISH) {
        if(d->faulted)rc=-EIO;
        else {dma_wmb();smp_mb();}
    } else if(cmd==TY_IOC_SUBMIT) {
        if(copy_from_user(&submit,(void __user *)arg,sizeof(submit))) rc=-EFAULT;
        else {
            rc=ty_execute(d,&submit);
            if(!rc && copy_to_user((void __user *)arg,&submit,sizeof(submit))) rc=-EFAULT;
        }
    } else rc=-ENOTTY;
    mutex_unlock(&d->lock);
    return rc;
}
static const struct file_operations ty_fops={
    .owner=THIS_MODULE,.open=ty_open,.release=ty_release,.unlocked_ioctl=ty_ioctl,
    .mmap=ty_mmap,.llseek=no_llseek,
};
static int ty_probe(struct platform_device *pdev)
{
    struct ty_device *d;
    struct resource *res;
    int rc;
    d=kzalloc(sizeof(*d),GFP_KERNEL);
    if(!d) return -ENOMEM;
    d->dev=get_device(&pdev->dev); mutex_init(&d->lock); atomic_set(&d->opened,0);
    kref_init(&d->refs);
    res=platform_get_resource(pdev,IORESOURCE_MEM,0);
    if(!res || resource_size(res)<0x100U) {rc=-EINVAL;goto free_device;}
    d->mmio_start=res->start; d->mmio_bytes=resource_size(res);
    if(!request_mem_region(d->mmio_start,d->mmio_bytes,dev_name(d->dev))) {rc=-EBUSY;goto free_device;}
    d->regs=ioremap(d->mmio_start,d->mmio_bytes);
    if(!d->regs) {rc=-ENOMEM;goto release_region;}
    d->fclk=clk_get(d->dev,"fclk");
    if(IS_ERR(d->fclk)) {rc=PTR_ERR(d->fclk);goto unmap;}
    d->aclk=clk_get(d->dev,"aclk");
    if(IS_ERR(d->aclk)) {rc=PTR_ERR(d->aclk);goto put_fclk;}
    rc=clk_prepare_enable(d->fclk); if(rc) goto put_aclk;
    rc=clk_prepare_enable(d->aclk); if(rc) goto disable_fclk;
    if(!ty_clock_matches(clk_get_rate(d->fclk),100000000U) ||
       !ty_clock_matches(clk_get_rate(d->aclk),240000000U)) {rc=-EINVAL;goto disable_aclk;}
    rc=dma_set_mask_and_coherent(d->dev,DMA_BIT_MASK(32)); if(rc) goto disable_aclk;
    rc=of_reserved_mem_device_init(d->dev); if(rc) goto disable_aclk;
    d->cpu=dma_alloc_coherent(d->dev,TY_DMA_BYTES,&d->dma,GFP_KERNEL);
    if(!d->cpu) {rc=-ENOMEM;goto release_reserved;}
    if(d->dma<0x18000000ULL || (u64)d->dma+TY_DMA_BYTES>0x1c000000ULL) {rc=-ERANGE;goto free_dma;}
    if(readl(d->regs+0x4c)!=TY_BUILD || !ty_drained(d)) {rc=-ENODEV;goto free_dma;}
    ty_ocm_allocate(d);
    d->misc.minor=MISC_DYNAMIC_MINOR; d->misc.name="tinyyolo0";
    d->misc.fops=&ty_fops; d->misc.parent=d->dev;
    rc=misc_register(&d->misc); if(rc) goto free_dma;
    platform_set_drvdata(pdev,d);
    dev_info(d->dev,"G228 build=%08x fclk=%lu aclk=%lu Hz, DMA %pad/%u bytes\n",
             TY_BUILD,clk_get_rate(d->fclk),clk_get_rate(d->aclk),&d->dma,TY_DMA_BYTES);
    return 0;
free_dma: ty_ocm_release(d); dma_free_coherent(d->dev,TY_DMA_BYTES,d->cpu,d->dma);
release_reserved: of_reserved_mem_device_release(d->dev);
disable_aclk: clk_disable_unprepare(d->aclk);
disable_fclk: clk_disable_unprepare(d->fclk);
put_aclk: clk_put(d->aclk);
put_fclk: clk_put(d->fclk);
unmap: iounmap(d->regs);
release_region: release_mem_region(d->mmio_start,d->mmio_bytes);
free_device: put_device(d->dev); kfree(d);
    return rc;
}
static int ty_remove(struct platform_device *pdev)
{
    struct ty_device *d=platform_get_drvdata(pdev);
    misc_deregister(&d->misc);
    mutex_lock(&d->lock);
    d->removed=true;
    mutex_unlock(&d->lock);
    kref_put(&d->refs,ty_destroy);
    return 0;
}
static const struct of_device_id ty_match[]={{.compatible="tinyyolo,g228"},{}};
MODULE_DEVICE_TABLE(of,ty_match);
static struct platform_driver ty_driver={.probe=ty_probe,.remove=ty_remove,
    .driver={.name="tinyyolo-g228",.of_match_table=ty_match,.suppress_bind_attrs=true}};
module_platform_driver(ty_driver);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("TinyYOLO G228 reserved coherent DMA polling driver");
