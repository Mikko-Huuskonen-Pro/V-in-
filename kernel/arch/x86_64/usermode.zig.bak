//! Ring 3 siirtymä — iretq käyttäjätilaan ja SYSCALL-palu reitti.
//!
//! **Vastuu**: Käyttäjäsivujen kartoitus, koodin kopiointi, boot-testi.
//! **Riippuvuudet**: `gdt.zig`, `vmm.zig`, `paging.zig`, `usermode_entry.S`
//! **Käytetään**: `kernel/main.zig`

// Tuo GDT — user code/data segmenttivalitsimet.
const gdt = @import("gdt.zig");
// Tuo VMM — uusien käyttäjäsivujen kartoitus.
const vmm = @import("../../mm/vmm.zig");
// Tuo sivulippujen rakenne.
const paging = @import("paging.zig");
// Tuo heap-alue — kiinteät user-testi osoitteet (slot × PAGE).
const heap = @import("../../mm/heap.zig");
// Tuo lokitus boot-viesteihin.
const log = @import("../../lib/log.zig");
// Tuo user_access — stac/clac SMAP-yhteensopivuuteen user-sivuille.
const user_access = @import("user_access.zig");
// Tuo prosessitaulukko — current pid ring 3 -kontekstissa (Vaihe 20).
const process = @import("process_core");

// Sivujen offset heapin alusta — yli INITIAL_PAGES (4) + marginaali.
const USER_PAGE_SLOT: u64 = 16;
// Käyttäjäkoodisivu — kiinteä linkitysosoite (ei slide: user-ELF abs-addr).
const USER_CODE_ADDR: u64 = heap.HEAP_START + USER_PAGE_SLOT * paging.PAGE_SIZE;
// Käyttäjäpinon sivu — seuraava 4 KiB sivu.
const USER_STACK_ADDR: u64 = USER_CODE_ADDR + paging.PAGE_SIZE;
// Pinon yläreuna (kasvaa alaspäin).
const USER_STACK_TOP: u64 = USER_STACK_ADDR + paging.PAGE_SIZE - 16;

// Ring 3 sivulippu — present + writable + user.
const USER_PAGE_FLAGS = paging.PageFlags{
    // Sivu kartoitettu.
    .present = 1,
    // Kirjoitus sallittu.
    .writable = 1,
    // Ring 3 pääsee sivulle.
    .user = 1,
};

// Ring 3 testikoodi alku — kernel .text (kopioidaan user-sivulle).
extern fn userEntry() void;
// Ring 3 testikoodi loppu — kopiointimäärän laskentaan.
extern fn userEntryEnd() void;

// Kernel pinon osoite ennen iretq:ä — export assemblylle.
pub export var usermode_saved_kernel_rsp: u64 = 0;
// Palautettava pid ennen ring 3 -hyppyä (sys_test_return / sys_exit palauttaa).
var usermode_saved_pid: u64 = process.BOOT_PID;
// Ring 3:ssa suoritettava prosessi — varmuus currentPid:lle syscallien aikana (Vaihe 24).
pub var usermode_ring3_pid: u64 = process.BOOT_PID;

// Siirry ring 3:een — usermode_jump.S iretq (palaa ret:llä sys_test_return:in kautta).
extern fn usermodeEnterIret(
    entry: u64,
    user_stack: u64,
    user_cs: u64,
    user_ss: u64,
    rflags: u64,
) callconv(.c) void;

// Palaa kernel boot-testiin — usermode_jump.S ret.
extern fn usermodeReturnToKernel() callconv(.c) noreturn;

// Kartoita 4K user-sivut, kopioi koodi, pakota P|W|U|!NX PTE:hen.
fn setupUserPages() bool {
    // Kopiointialue kernel .text:stä.
    const code_start: u64 = @intFromPtr(&userEntry);
    const code_end: u64 = @intFromPtr(&userEntryEnd);
    const code_len = code_end - code_start;
    // Koko yhden sivun sisällä.
    if (code_len == 0 or code_len > paging.PAGE_SIZE) return false;
    // Kartoita koodi- ja pino-sivut PMM:stä (user-sivutaulupolku).
    if (!vmm.mapNewUserPageEnsure(USER_CODE_ADDR, USER_PAGE_FLAGS)) return false;
    if (!vmm.mapNewUserPageEnsure(USER_STACK_ADDR, USER_PAGE_FLAGS)) return false;
    if (!paging.setUserPagePath(vmm.pml4Phys(), vmm.hhdm(), USER_CODE_ADDR, true)) return false;
    if (!paging.setUserPagePath(vmm.pml4Phys(), vmm.hhdm(), USER_STACK_ADDR, false)) return false;
    const dst: [*]u8 = @ptrFromInt(USER_CODE_ADDR);
    const src: [*]const u8 = @ptrFromInt(code_start);
    user_access.stac();
    @memcpy(dst[0..code_len], src[0..code_len]);
    user_access.clac();
    return true;
}

// Hae ring 3 -prosessin tunniste (asetettu enterUserAs:ssa).
pub fn activeRing3Pid() u64 {
    // Palauta viimeisin user-kontekstin pid.
    return usermode_ring3_pid;
}

// Palaa kerneliin sys_test_return/sys_exit-käsittelijästä.
pub fn returnToKernelTestContinue() noreturn {
    // Palauta edellinen prosessikonteksti ennen kernel-jatkoa.
    _ = process.setCurrentPid(usermode_saved_pid);
    // Delegoi assembly-toteutukselle.
    usermodeReturnToKernel();
}

// Siirry ring 3:een annetulla entry:llä ja pinolla (iretq + sys_test_return paluu).
pub fn enterUser(entry: u64, user_stack_top: u64) void {
    // Oletus: boot/init-prosessi pid 1.
    enterUserAs(entry, user_stack_top, process.BOOT_PID);
}

// Siirry ring 3:een tietyllä prosessitunnisteella (syscall getpid).
pub fn enterUserAs(entry: u64, user_stack_top: u64, pid: u64) void {
    // Tallenna nykyinen pid ennen user-kontekstia.
    usermode_saved_pid = process.currentPid();
    // Tallenna ring 3 -prosessi erikseen (Vaihe 24 sys_exit).
    usermode_ring3_pid = pid;
    // Aseta current pid userland-syscallien ajaksi.
    _ = process.setCurrentPid(pid);
    // User segmenttivalitsimet RPL 3.
    const user_cs: u64 = gdt.USER_CODE_SEL | 3;
    const user_ss: u64 = gdt.USER_DATA_SEL | 3;
    // RFLAGS: bitti 1 pakollinen, IF=0.
    const rflags: u64 = 0x2;
    // Siirry ring 3:een — palaa ret:llä sys_test_return:in kautta.
    usermodeEnterIret(entry, user_stack_top, user_cs, user_ss, rflags);
}

// Boot-testi — ring 3 sys_write("hello") + paluu kerneliin.
pub fn runBootTest() void {
    // Kartoita sivut ja kopioi koodi.
    if (!setupUserPages()) {
        // Sivujen kartoitus epäonnistui.
        log.err("Usermode page setup failed");
        return;
    }
    // Siirry ring 3:een kopioituun blobiin (slidattu osoite).
    enterUser(USER_CODE_ADDR, USER_STACK_TOP);
    // Paluu sys_test_return ret:llä.
    log.info("Usermode test OK");
}
