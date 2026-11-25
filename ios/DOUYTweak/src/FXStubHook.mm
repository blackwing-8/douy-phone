//
//  FXStubHook.mm —— 基于 __stubs 跳板改写的轻量挂钩
//
//  设计约束（每一条都是上一版崩溃的直接教训）：
//    1. 绝不在 dylib 加载时执行 —— 只由用户点按钮触发，失败也只是"没生效"
//    2. vm_protect 必须检查返回值，失败就放弃改写（否则写只读页 = 必崩）
//    3. 段/节长度必须成对取自同一个 section，不能跨段借用（否则越界读）
//    4. 解引用槽地址前先做 vm_region 映射校验
//    5. 默认 dryRun：只统计不改写
//
//  为什么不用 fishhook / 改 GOT：
//    抖音是 chained fixups + arm64e 认证指针，直接写裸指针会让 braa 崩溃。
//    __stubs 是 12 字节跳板（adrp / ldr / br），x16 本就是 veneer 的临时寄存器，
//    改写它不影响调用方寄存器，也不需要处理 ptrauth 签名。
//

#import "FXCommon.h"
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/getsect.h>
#import <mach/vm_map.h>
#import <mach/vm_region.h>
#import <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <dlfcn.h>
#include <string.h>

#define FX_STUB_SIZE 12

/// vm_protect 改权限，失败返回 NO
static BOOL FXMakeWritable(void *addr, size_t len)
{
    vm_address_t page = (vm_address_t)addr & ~(vm_address_t)(vm_page_size - 1);
    size_t span = ((vm_address_t)addr + len) - page;
    kern_return_t kr = vm_protect(mach_task_self(), page, span, false,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    return kr == KERN_SUCCESS;
}

static BOOL FXMakeExecutable(void *addr, size_t len)
{
    vm_address_t page = (vm_address_t)addr & ~(vm_address_t)(vm_page_size - 1);
    size_t span = ((vm_address_t)addr + len) - page;
    kern_return_t kr = vm_protect(mach_task_self(), page, span, false,
                                  VM_PROT_READ | VM_PROT_EXECUTE);
    sys_icache_invalidate(addr, len);
    return kr == KERN_SUCCESS;
}

/// 地址是否落在已映射区域内（解引用前必须校验）
static BOOL FXIsMapped(const void *addr)
{
    vm_address_t region = (vm_address_t)addr;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;

    kern_return_t kr = vm_region_64(mach_task_self(), &region, &size, VM_REGION_BASIC_INFO_64,
                                    (vm_region_info_t)&info, &count, &object);
    if (object != MACH_PORT_NULL)
    {
        mach_port_deallocate(mach_task_self(), object);
    }
    if (kr != KERN_SUCCESS)
    {
        return NO;
    }
    uintptr_t a = (uintptr_t)addr;
    return a >= (uintptr_t)region && a + sizeof(void *) <= (uintptr_t)region + size;
}

/// 解码 stub 前 8 字节，算出它读取的槽地址；不是标准形式返回 NULL
static void *FXStubSlotAddress(const uint8_t *stub)
{
    uint32_t w0, w1;
    memcpy(&w0, stub, 4);
    memcpy(&w1, stub + 4, 4);

    if ((w0 & 0x9F000000) != 0x90000000 || (w0 & 0x1F) != 16)   // adrp x16
    {
        return NULL;
    }

    int64_t immlo = (w0 >> 29) & 0x3;
    int64_t immhi = (w0 >> 5) & 0x7FFFF;
    int64_t imm = (immhi << 2) | immlo;
    if (imm & (1LL << 20))
    {
        imm -= 1LL << 21;
    }
    uintptr_t pc = (uintptr_t)stub;
    uintptr_t page = (pc & ~(uintptr_t)0xFFF) + (uintptr_t)(imm << 12);

    if ((w1 & 0xFFC00000) != 0xF9400000 ||                        // ldr x16, [x16, #imm]
        (w1 & 0x1F) != 16 || ((w1 >> 5) & 0x1F) != 16)
    {
        return NULL;
    }
    return (void *)(page + (uintptr_t)(((w1 >> 10) & 0xFFF) * 8));
}

/// 把 stub 改成跳到 replacement；成功返回 YES
static BOOL FXPatchStub(uint8_t *stub, void *replacement)
{
    uintptr_t from = (uintptr_t)stub;
    uintptr_t to = (uintptr_t)replacement;

    int64_t delta = (int64_t)(to & ~(uintptr_t)0xFFF) - (int64_t)(from & ~(uintptr_t)0xFFF);
    if (delta > (4LL << 30) || delta < -(4LL << 30))
    {
        return NO;
    }

    int64_t pages = delta >> 12;
    uint32_t adrp = 0x90000010u;                          // adrp x16, page
    adrp |= (uint32_t)((uint64_t)pages & 0x3) << 29;      // immlo
    adrp |= (uint32_t)(((uint64_t)pages >> 2) & 0x7FFFF) << 5;

    // ⚠️ Rn 必须是 x16（位[9:5]=16）。写成 0x91000010 会变成 add x16, x0 → 必崩
    uint32_t add = 0x91000010u | (16u << 5);              // add x16, x16, #lo12
    add |= (uint32_t)(to & 0xFFF) << 10;

    uint32_t br = 0xD61F0200u;                            // br x16

    if (!FXMakeWritable(stub, FX_STUB_SIZE))
    {
        return NO;                                        // 改不动就放弃，绝不硬写
    }
    memcpy(stub, &adrp, 4);
    memcpy(stub + 4, &add, 4);
    memcpy(stub + 8, &br, 4);
    FXMakeExecutable(stub, FX_STUB_SIZE);
    return YES;
}

FXStubHookResult FXStubHookInstall(const char *name, void *replacement, BOOL dryRun)
{
    FXStubHookResult r;
    memset(&r, 0, sizeof(r));
    r.target = dlsym(RTLD_DEFAULT, name);
    r.replacement = replacement;
    if (r.target == NULL)
    {
        r.note = @"找不到符号";
        return r;
    }

    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; i++)
    {
        const struct mach_header_64 *mh = (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (mh == NULL || mh->magic != MH_MAGIC_64)
        {
            continue;
        }
        r.imagesScanned++;

        const struct load_command *lc = (const struct load_command *)((const uint8_t *)mh + sizeof(*mh));
        for (uint32_t c = 0; c < mh->ncmds; c++)
        {
            if (lc->cmd == LC_SEGMENT_64)
            {
                const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
                const struct section_64 *sect = (const struct section_64 *)(seg + 1);
                for (uint32_t k = 0; k < seg->nsects; k++)
                {
                    if (strncmp(sect[k].sectname, "__stubs", 16) != 0)
                    {
                        continue;
                    }

                    // 关键：偏移与长度必须成对取自这一个 section
                    uint32_t fileOff = sect[k].offset;
                    size_t size = (size_t)sect[k].size;
                    if (fileOff == 0 || size < FX_STUB_SIZE)
                    {
                        continue;
                    }

                    const uint8_t *text = getsectiondata(mh, seg->segname, "__stubs", NULL);
                    if (text == NULL)
                    {
                        continue;
                    }

                    for (size_t off = 0; off + FX_STUB_SIZE <= size; off += FX_STUB_SIZE)
                    {
                        r.stubsTotal++;
                        void *slot = FXStubSlotAddress(text + off);
                        if (slot == NULL || !FXIsMapped(slot))
                        {
                            continue;
                        }

                        void *value = NULL;
                        memcpy(&value, slot, sizeof(value));
                        if (value != r.target)
                        {
                            continue;
                        }

                        r.stubsMatched++;
                        if (dryRun)
                        {
                            continue;
                        }
                        if (FXPatchStub((uint8_t *)(text + off), replacement))
                        {
                            r.stubsPatched++;
                            if (r.firstPatchedAt == NULL)
                            {
                                r.firstPatchedAt = (void *)(text + off);
                            }
                        }
                    }
                }
            }
            lc = (const struct load_command *)((const uint8_t *)lc + lc->cmdsize);
        }
    }

    return r;
}
