//! Prosessin luonti — upotetut spawn-ELF:t ja runProcess (Vaihe 21).
//!
//! **Vastuu**: Lataa embedded user-ELF uudelle pid:lle, siirry ring 3:een.
//! **Riippuvuudet**: `loader/elf.zig`, `process_core`, `usermode.zig`
//! **Käytetään**: `syscall/spawn_syscall.zig`, `syscall/dispatch.zig`

// Tuo ELF-loader — PT_LOAD + erillinen pinokartoitus.
const elf = @import("loader/elf.zig");
// Tuo ring 3 siirtymä — iretq tietyllä pid:llä.
const usermode = @import("arch/x86_64/usermode.zig");
// Tuo prosessitaulukko — pid-allokaatio ja ladatut kentät.
const process = @import("process_core");
// Tuo VMM — per-process page table (vaihe 25).
const vmm = @import("mm/vmm.zig");
// Tuo PMM — fyysinen kehyshalooja PML4-raamulle.
const pmm = @import("mm/pmm.zig");

// Upotettu spawn-lapsi A — build.zig kopioi ennen kernel-käännöstä.
const spawn_child_a_elf = @embedFile("loader/spawn_child_a_prog.bin");
// Upotettu spawn-lapsi B — eri load-osoite ja pinokartoitus.
const spawn_child_b_elf = @embedFile("loader/spawn_child_b_prog.bin");
// Upotettu spawn-lapsi exit — sys_exit(42) (Vaihe 24).
const spawn_child_exit_elf = @embedFile("loader/spawn_child_exit_prog.bin");

// Embedded ELF -tunniste: spawn-lapsi A.
pub const SPAWN_ID_CHILD_A: u64 = 0;
// Embedded ELF -tunniste: spawn-lapsi B.
pub const SPAWN_ID_CHILD_B: u64 = 1;
// Embedded ELF -tunniste: spawn-lapsi exit (sys_exit).
pub const SPAWN_ID_EXIT: u64 = 2;

// Pinon heap-slot lapsi A:lle — erillään muista user-ELF:istä (slot 112).
const SPAWN_CHILD_A_STACK_SLOT: u64 = 112;
// Pinon heap-slot lapsi B:lle — seuraava vapaa sivu (slot 113).
const SPAWN_CHILD_B_STACK_SLOT: u64 = 113;
// Pinon heap-slot exit-lapselle — erillinen sivu (slot 115).
const SPAWN_CHILD_EXIT_STACK_SLOT: u64 = 115;

// Luo uusi prosessi upotetusta ELF:stä — palauttaa pid tai null.
pub fn spawnEmbedded(id: u64) ?u64 {
    // Valitse ELF-blob tunnisteen mukaan.
    const elf_data: []const u8 = switch (id) {
        // Lapsi A — tulostaa "spa\n" serialiin.
        SPAWN_ID_CHILD_A => spawn_child_a_elf,
        // Lapsi B — tulostaa "spb\n" serialiin.
        SPAWN_ID_CHILD_B => spawn_child_b_elf,
        // Exit-lapsi — kutsuu sys_exit(42).
        SPAWN_ID_EXIT => spawn_child_exit_elf,
        // Tuntematon tunniste.
        else => return null,
    };
    // Valitse erillinen pinokartoitus per lapsi.
    const stack_slot: u64 = switch (id) {
        // Lapsi A pinosivu slot 112.
        SPAWN_ID_CHILD_A => SPAWN_CHILD_A_STACK_SLOT,
        // Lapsi B pinosivu slot 113.
        SPAWN_ID_CHILD_B => SPAWN_CHILD_B_STACK_SLOT,
        // Exit-lapsi pinosivu slot 115.
        SPAWN_ID_EXIT => SPAWN_CHILD_EXIT_STACK_SLOT,
        // Tuntematon tunniste.
        else => return null,
    };
    // Allokoi seuraava vapaa pid prosessitaulukosta.
    const pid = process.allocNextPid() orelse return null;
    // Aseta vanhemmaksi nykyinen prosessi (Vaihe 24 parent/child).
    if (!process.setParentPid(pid, process.currentPid())) return null;

    // === Vaihe 25: per-process PML4-allokaatio ===

    // a) Allokoi nollattu PML4-kehys PMM:stä.
    const pml4_phys = pmm.frameToPhys(pmm.allocFrame() orelse {
        _ = process.freePid(pid);
        return null;
    });

    // b) Nollaa kehys (tyhjä PML4 — kaikki sivutaulu-indeksit = 0).
    const pml4_virt = vmm.physToVirt(pml4_phys);
    const pml4_ptr: [*]u8 = @ptrFromInt(pml4_virt);
    @memset(pml4_ptr[0..4096], 0);

    // c) Tallenna prosessitaulukkoon.
    if (!process.setPageTable(pid, pml4_phys)) {
        _ = process.freePid(pid);
        return null;
    }

    // d) Aseta VMM kohde — nyt kaikki kartoitukset kohdistuvat tähän PML4:ään.
    vmm.target_pml4_phys = pml4_phys;

    // 3. Lataa ELF segmentit kohteen prosessin sivutauluun.
    const loaded = elf.loadElfWithStack(elf_data, stack_slot) orelse {
        vmm.target_pml4_phys = null;
        return null;
    };

    // 5. Tyhjennä kohde — takaisin kernelin PML4:ään.
    vmm.target_pml4_phys = null;
    // Tallenna entry/pino prosessitaulukkoon spawn/runProcess varten.
    if (!process.setLoaded(pid, loaded.entry, loaded.stack_top, stack_slot)) return null;
    // Palauta uuden prosessin tunniste.
    return pid;
}

// Suorita aiemmin spawnattu prosessi ring 3:ssa — palaa sys_test_return:in jälkeen.
pub fn runProcess(pid: u64) bool {
    // Hae ladatun prosessin entry ja pino.
    const info = process.getLoadedInfo(pid) orelse return false;
    // Siirry ring 3:een annetulla pid:llä (getpid toimii oikein).
    usermode.enterUserAs(info.entry, info.stack_top, pid);
    // Paluu sys_test_return ret:llä — prosessi suoritettu.
    return true;
}
