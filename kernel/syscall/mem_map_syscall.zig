// Memory mmap boot-testi — memory-capability  + sys_mem_map (Vaihe 28).
// Vastuu: Luo memory-cap, kutsu sys_mem_map(slot, addr) ja validoi.
// Riippuvuudet: capability_core.zig, cap_syscall_core.zig, dispatch.zig,
//               loader/elf.zig, user_access.zig, vmm.zig

// Tuo capability-ydin — createAndInstall + lookupSlot.
const cap = @import("../ipc/capability_core.zig");
// Tuo CapType.memory enum-arvo (Vaihe 28: memory = 2).
const cap_type = cap.CapType{ .memory = 1 };
// Tuo cap-tyyppivakiot (CAP_TYPE_MEMORY).
const cap_syscore = @import("cap_syscall_core.zig");
// Tuo sys_mem_map syscall-ydin — mapPageEnsure U/W/kayttaja-tila.
const mem_map = @import("mem_map_core.zig");
// Tuo jaettu ABI — SYS_mem_map, ENOMEM tms.
const abi = @import("zinuxabi");
// Tuo dispatch — invoke() suorana ilman ring 3.
const dispatch = @import("dispatch.zig");
// Tuo ELF-loader — upotetun testin lataus.
const elf_loader = @import("../loader/elf.zig");
// Tuo VMM — mm_new_user_page_map boot-infon tallentamiseen.
const vmm = @import("../mm/vmm.zig");
// Tuo user_access — stac/clac SMAP-yhteensopivuuteen user-sivuille.
const user_access = @import("../arch/x86_64/user_access.zig");
// Tuo prosessitaulukko — oma omistaja-pid testin capille.
const process = @import("process_core");
// Tuo lokitus boot-viesteihin.
const log = @import("../lib/log.zig");

// Upotettu mem_map test-ELF build.zig:sta.
const mem_map_test_bin = @embedFile("loader/mem_map_test_prog.bin");

// Testi-VMM sivu osoite — kohde-sivu, jota userland kirjoittaa/testaa mmap:ssa.
const MEM_MAP_TEST_VADDR: u64 = 0xFFFFFFFF9008C000;
// Boot-info slotin indeksi test-ELF:lla (virt_addr + offset).
const MEM_MAP_TEST_SLOT_VADDR: u64 = 0xFFFFFFFF9008C008;
// Boot-info target_page_phys osoite (mmap core kirjoittaa tähän osoitteen).
const MM_TEST_PHYS_ADDR_VADDR: u64 = 0xFFFFFFFF9008C010;

// runBootTest(): Vaihe 28 boot-testi — luo memory-cap + mapPage(virt,phys,U+W) testissa.
pub fn runBootTest() void {
    // Oma omistaja-pid capille — boot-pidin (1) slotit täyttyvät aiemmissa
    // vaiheissa (jokainen testi asentaa sinne), tuoreella pidillä on tyhjät slotit.
    const owner = process.allocNextPid() orelse {
        log.err("Mem map test pid alloc failed");
        return;
    };
    // Luo memory-cap (CAP_TYPE_MEMORY + write + map oikeudet).
    const slot = cap.createAndInstall(
        .memory, // CapType.memory = 2 (cap_syscall_core: CAP_TYPE_MEMORY = 5).
        owner, // omistaja = testin oma pid (ei boot-stub).
        0xfffffde000, // resurssitunniste = mm_new_user_page_map().
        cap.Rights{ .write = true, .map = true },
    ) orelse {
        log.err("Mem map test memory create failed");
        return;
    };
    // Kutsu sys_mem_map(slot, addr) invoke-kautta (Vaihe 28.1).
    // lookupSlot hakee current-pidin sloteista — vaihda omistajaan kutsun ajaksi.
    _ = process.setCurrentPid(owner);
    const ret = dispatch.invoke(abi.SYS_mem_map, slot, MEM_MAP_TEST_VADDR, 0, 0, 0, 0);
    _ = process.setCurrentPid(process.BOOT_PID);
    // Ominaisuuksien pitäisi onnistua palauttamalla OK / 4KiB page mapped.
    if (ret < 0) {
        log.err("Mem map syscall failed");
        return;
    }
    // Kirjoita boot-info test-ELF:lle mmap_virt ja slot_indeksi + kirjoitettavan osoite.
    const mm_slot_ptr = @as(*u32, @ptrFromInt(MEM_MAP_TEST_SLOT_VADDR));
    const mm_phys_ptr = @as(*u64, @ptrFromInt(MM_TEST_PHYS_ADDR_VADDR));
    // SMAP: salli user-kirjoitus ennen ring 3 hyppyä.
    user_access.stac();
    // Tallenna slot-indeksi boot-info-osoitteeseen.
    mm_slot_ptr.* = @intCast(slot);
    // Tallenna tavoite-fyysinen osoite (mmap_page_phys): boot-infor +16.
    mm_phys_ptr.* = mem_map.mm_new_user_page_map();
    // Palauta MMAP-suojaus ennen paluuta.

    user_access.clac();
    log.info("Mem map syscall OK");
}
