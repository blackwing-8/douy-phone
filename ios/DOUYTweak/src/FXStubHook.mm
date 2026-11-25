//
//  FXStubHook.mm —— 基于 __stubs 跳板改写的轻量挂钩
//
//  为什么不用 fishhook / 改 GOT：
//    · 抖音是 chained fixups 二进制，GOT 里是 arm64e 认证指针，
//      直接写裸指针会让 braa 崩溃；要正确签名就得解析 chained fixups + ptrauth，风险极高。
//    · __stubs 是每个镜像里的 12 字节跳板（adrp / ldr / br），只跳转不改数据，
//      x16 本来就是 veneer 的临时寄存器，改写它不影响调用者寄存器。
//
//  怎么确认找对了桩：
//    解码 stub 里的 adrp+ldr 得到 GOT 槽地址，读出槽里的真实函数地址，
//    只有它等于 dlsym(RTLD_DEFAULT, name) 才改写 —— 绝不盲改。
//
//  失败一律放弃（fail-closed），绝不半patch。
//

#import "FXCommon.h"
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/getsect.h>
#import <mach/vm_map.h>
#include <mach/mach.h>
#import <libkern/OSCacheControl.h>
#include <dlfcn.h>
#include <string.h>

#define FX_STUB_SIZE 12

static void FXMakeWritable(void *addr, size_t len)
{
    vm_address_t page = (vm_address_t)addr & ~(vm_address_t)(vm_page_size - 1);
    size_t span = ((vm_address_t)addr + len) - page;
    vm_protect(mach_task_self(), page, span, false,
               VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
}

static void FXMakeExecutable(void *addr, size_t len)
{
    vm_address_t page = (vm_address_t)addr & ~(vm_address_t)(vm_page_size - 1);
    size_t span = ((vm_address_t)addr + len) - page;
    vm_protect(mach_task_self(), page, span, false, VM_PROT_READ | VM_PROT_EXECUTE);
    sys_icache_invalidate(addr, len);
}

/// 解码 stub 的前 8 字节，算出它读取的 GOT 槽地址；不认识就返回 NULL。
static void *FXStubSlotAddress(const uint8_t *stub)
{
    uint32_t w0, w1;
    memcpy(&w0, stub, 4);
    memcpy(&w1, stub + 4, 4);

    // adrp x16, page  (0x90000000 掩码，rd 必须是 16)
    if ((w0 & 0x9F000000) != 0x90000000 || (w0 & 0x1F) != 16)
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

    // ldr x16, [x16, #imm12]  (64 位无符号偏移)
    if ((w1 & 0xFFC00000) != 0xF9400000 || (w1 & 0x1F) != 16 || ((w1 >> 5) & 0x1F) != 16)
    {
        return NULL;
    }
    uint32_t off = ((w1 >> 10) & 0xFFF) * 8;
    return (void *)(page + off);
}

/// 把 stub 改成跳到 replacement（adrp/add/br，12 字节内完成）
static BOOL FXPatchStub(uint8_t *stub, void *replacement)
{
    uintptr_t from = (uintptr_t)stub;
    uintptr_t to = (uintptr_t)replacement;

    // adrp 的寻址范围是 ±4GB（页对齐），超出就放弃
    int64_t delta = (int64_t)(to & ~(uintptr_t)0xFFF) - (int64_t)(from & ~(uintptr_t)0xFFF);
    if (delta > (4LL << 30) || delta < -(4LL << 30))
    {
        return NO;
    }

    int64_t pages = delta >> 12;
    uint32_t adrp = 0x90000010u;                       // adrp x16, page
    adrp |= (uint32_t)((uint64_t)pages & 0x3) << 29;   // immlo
    adrp |= (uint32_t)(((uint64_t)pages >> 2) & 0x7FFFF) << 5;

    uint32_t add = 0x91000010u;                        // add x16, x16, #lo12
    add |= (uint32_t)(to & 0xFFF) << 10;

    uint32_t br = 0xD61F0200u;                         // br x16

    FXMakeWritable(stub, FX_STUB_SIZE);
    memcpy(stub, &adrp, 4);
    memcpy(stub + 4, &add, 4);
    memcpy(stub + 8, &br, 4);
    FXMakeExecutable(stub, FX_STUB_SIZE);
    return YES;
}

/// 在所有已加载镜像里找调用 name 的桩并改写。dryRun=YES 时只统计不改。
FXStubHookResult FXStubHookInstall(const char *name, void *replacement, BOOL dryRun)
{
    FXStubHookResult r = {0};
    r.target = dlsym(RTLD_DEFAULT, name);
    r.replacement = replacement;
    if (r.target == NULL)
    {
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

        const uint8_t *text = getsectiondata(mh, "__TEXT", "__stubs", NULL);
        if (text == NULL)
        {
            continue;
        }

        // __stubs 大小通过段遍历取，避免依赖 getsectiondata 的长度限制
        size_t stubSize = 0;
        const struct load_command *lc = (const struct load_command *)((const uint8_t *)mh + sizeof(*mh));
        for (uint32_t c = 0; c < mh->ncmds; c++)
        {
            if (lc->cmd == LC_SEGMENT_64)
            {
                const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
                const struct section_64 *sect = (const struct section_64 *)(seg + 1);
                for (uint32_t k = 0; k < seg->nsects; k++)
                {
                    if (strncmp(sect[k].sectname, "__stubs", 16) == 0)
                    {
                        stubSize = (size_t)sect[k].size;
                    }
                }
            }
            lc = (const struct load_command *)((const uint8_t *)lc + lc->cmdsize);
        }
        if (stubSize < FX_STUB_SIZE)
        {
            continue;
        }

        for (size_t off = 0; off + FX_STUB_SIZE <= stubSize; off += FX_STUB_SIZE)
        {
            uint8_t *stub = (uint8_t *)(text + off);
            r.stubsTotal++;

            void *slot = FXStubSlotAddress(stub);
            if (slot == NULL)
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

            if (FXPatchStub(stub, replacement))
            {
                r.stubsPatched++;
                if (r.firstPatchedAt == NULL)
                {
                    r.firstPatchedAt = stub;
                }
            }
        }
    }

    return r;
}
