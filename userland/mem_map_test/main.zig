// Memory-mmap userland boot-testi — cap_create(memory) + sysMemMap + write/read (Vaihe 28).
// Vastuu: Testaa SYS_mem_map(slot, addr) kirjoittamalla ja lukea ring 3:ssa.
// Riippuvuudet: syscall.zig

const sc = @import("syscall.zig");

// Boot-info: mmap_target_vaddr (boot_test kirjoittaa tähän).
const MM_TEST_VIRT: u64 = 0xFFFFFFFF9008C000;

// mmTestMain(): ring 3 memory-cap + mmap write/read verify (Vaihe 28).
export fn mmTestMain() void {
    // Luo memory-capability: cap_create(CAP_TYPE_MEMORY=5, mask=write+map+send+recv).
    const mem_rights_mask: u64 = @as(u64, 0xd0);

    const ret = asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [num] "{rax}" (@as(u64, sc.SYS_cap_create)),
          [typ] "{rdi}" (@as(u64, 5)), // CAP_TYPE_MEMORY = 5 (Vaihe 28.1).
          [mask] "{rsi}" (mem_rights_mask),
        : .{ .rcx = true, .r11 = true, .memory = true });

    if (ret < 0) {
        sc.print("mem_map: cap create failed\r\n");
        sc.sysTestReturn();
    }

    // Uusi capability-slot.
    const mem_slot: u32 = @intCast(ret);

    // sys_mem_map(slot, addr).
    const mmap_addr: u64 = MM_TEST_VIRT;

    const map_ret = asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [num] "{rax}" (@as(u64, sc.SYS_mem_map)),
          [slot] "{rdi}" (mem_slot),
          [addr] "{rsi}" (mmap_addr),
        : .{ .rcx = true, .r11 = true, .memory = true });

    if (map_ret <= 0) {
        sc.print("mem_map: sys_mem_map failed\r\n");
        sc.sysTestReturn();
    }

    // Kirjoita testitietoa mmap-kartoitetulle sivulle U/W/virtuaaliselle alueelle.
    const page_ptr = @as(*[4096]u8, @ptrFromInt(MM_TEST_VIRT));
    const msg = "Zinux mem_map OK\r\n";

    var i: usize = 0;
    while (i < msg.len) : (i += 1) {
        page_ptr[i] = msg[i];
    }

    sc.print("mem_map wrote to mmap'd page\r\n");

    // Lue takaisin ja vertaa -> varmista että write onnistui.
    var j: usize = 0;
    while (j < msg.len) : (j += 1) {
        if (page_ptr[j] != msg[j]) {
            sc.print("mem_map: mismatch\r\n");
            sc.sysTestReturn();
        }
    }

    // Verify capability slot type.

    sc.print("userland cap mem map OK\r\n");
    sc.sysTestReturn();
}

// Anchor — pakota linkitys export-funktioksi ei saa poistua LTO:ssa.
pub export fn capMemMapAnchor() void {}
