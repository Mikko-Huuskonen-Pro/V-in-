//! Zinux kernel — pääsisäänkäynti.
//!
//! **Vastuu**: `_start` → early boot → kmain-alustus → idle loop.
//! **Riippuvuudet**: boot, arch, mm, lib
//! **Käytetään**: Limine lataa tämän ELF-binäärin

// Tuo early boot -alustus (UART ennen Limine-validointia).
const boot = @import("boot/entry.zig");
// Tuo Limine request -ankkuri (linksection .limine_requests).
const requests = @import("boot/requests.zig");
// Tuo Limine boot-info ja muistikartan luku.
const limine_boot = @import("boot/limine.zig");
// Tuo Limine → PMM muunnos ja alustus.
const mem_init = @import("boot/mem.zig");
// Tuo lokitusmoduuli (UART + VGA).
const log = @import("lib/log.zig");
// Tuo GDT — segmenttien alustus (Vaihe 2).
const gdt = @import("arch/x86_64/gdt.zig");
// Tuo IDT — keskeytykset ja page fault (Vaihe 2).
const idt = @import("arch/x86_64/idt.zig");
// Tuo PMM — fyysisten kehysten bitmap-allokaattori (Vaihe 2).
const pmm = @import("mm/pmm.zig");
// Tuo VMM — virtuaalimuistin hallinta (Vaihe 2).
const vmm = @import("mm/vmm.zig");
// Tuo kernel heap — first-fit allokaattori (Vaihe 2).
const heap = @import("mm/heap.zig");
// Tuo muistitestit — 100 kehystä + heap smoke test.
const memtest = @import("mm/memtest.zig");
// Tuo SYSCALL MSR-alustus (Vaihe 4.1).
const syscall = @import("arch/x86_64/syscall.zig");
// Pakota syscall dispatch linkitys — syscall_entry.S kutsuu export-funktiota.
const _dispatch_link = @import("syscall/dispatch.zig");
// Tuo KASLR — satunnainen user/heap-slide (Vaihe 7.3).
const kaslr = @import("arch/x86_64/kaslr.zig");
// Tuo boot-tila — smoke / full / dev (build.zig -Dboot=).
const boot_options = @import("boot_options");
// Tuo integraatiotestit — full + dev -tilat.
const boot_tests = @import("boot_tests.zig");
// Tuo QEMU-lopetus — smoke/full-tilan siisti exit.
const qemu_exit = @import("lib/qemu_exit.zig");
// Tuo SMP stub — Limine CPU-määrä (Vaihe 3).
const smp = @import("boot/smp.zig");
// Tuo PIT ticks — linkittää timerOnIrqC timer_irq.S:lle.
const pit_ticks = @import("lib/pit_ticks.zig");
// Tuo scheduler — coop ABAB-demo (full/dev).
const scheduler = @import("sched/scheduler.zig");

// Early boot -pino — 16 KiB, 16-tavun aligned (x86_64 vaatimus).
extern var early_stack: [16 * 1024]u8 align(16);

// Limine siirtyy tähän — aseta pino ja kutsu kmain.
pub export fn _start() callconv(.c) noreturn {
    // Laske pinon yläreuna (kasvaa alaspäin x86_64:ssä).
    const stack_top = @intFromPtr(&early_stack) + early_stack.len;
    // Aseta RSP inline ennen mitään call-operaatiota (return address vaatii oikean pinon).
    asm volatile ("mov %[stack], %%rsp"
        :
        : [stack] "r" (stack_top),
    );
    // Pakota linkittäjän säilyttämään Limine request -osio.
    requests.anchor();
    // Early init: UART + Limine validointi + VGA log init.
    boot.earlyInit();
    // Siirry pääalustukseen — ei palaa takaisin.
    kmain();
}

// Kernel pääfunktio — alustaa alijärjestelmät järjestyksessä.
fn kmain() noreturn {
    // Tulosta boot-viesti serialiin ja VGA:han.
    log.info("Zinux kernel starting...");
    // Tulosta kohdealusta debug-lokitusta varten.
    log.info("Target: x86_64 freestanding");
    // Alusta GDT — kernel code/data segmentit.
    gdt.init();
    // Vahvista GDT-alustus onnistui.
    log.info("GDT initialized");
    // Alusta IDT — page fault #14 oikea handler, muut stub.
    idt.init();
    // Vahvista IDT-alustus onnistui.
    log.info("IDT initialized");
    // Alusta SYSCALL MSRs (STAR/LSTAR/SFMASK + EFER.SCE) — IDT:n jälkeen.
    syscall.init();
    // Pakota dispatch export linkitys (smoke-build ei kutsu boot_tests.runAll).
    _dispatch_link.linkAnchor();
    // Vahvista syscall entry -osoite on asetettu.
    log.info("Syscall MSRs initialized");
    // Hae Limine boot-info (HHDM offset jne.).
    const boot_info = limine_boot.getBootInfo();
    // Alusta PMM Limine-muistikartasta tai fallback 256 MiB.
    if (limine_boot.getMemoryMapEntries()) |entries| {
        // Muunna Limine map → PMM bitmap.
        mem_init.initPmmFromLimine(entries);
        // Vahvista PMM Limine-kartasta.
        log.info("PMM initialized (Limine map)");
    } else {
        // Fallback jos muistikartta puuttuu (ei pitäisi tapahtua Liminessä).
        pmm.initFallback(256 * 1024 * 1024);
        // Vahvista PMM fallback-tilassa.
        log.info("PMM initialized (fallback 256MiB)");
    }
    // Testaa PMM — allokoi ja vapauta yksi kehys boot-vaiheessa.
    if (pmm.allocFrame()) |frame| {
        // Vapauta kehys heti — boot-testi että bitmap toimii.
        pmm.freeFrame(frame);
        // Vahvista PMM allokoi/vapauttaa kehyksiä.
        log.info("PMM alloc test OK");
    }
    // Alusta VMM — tallenna HHDM ja Liminen CR3 (PML4).
    vmm.init(boot_info.hhdm_offset);
    // Vahvista VMM-alustus onnistui.
    log.info("VMM initialized");
    // Laske KASLR-slide ennen heap/user-kartoitusta (Vaihe 7.3).
    kaslr.init(boot_info.hhdm_offset);
    // Alusta kernel heap — kartoittaa INITIAL_PAGES sivua slidattuun alkuun.
    heap.init();
    // Vahvista KASLR-slide aktivoitunut.
    kaslr.runBootTest();
    // Vahvista heap-alustus onnistui.
    log.info("Heap initialized");
    // Aja Vaihe 2 integraatiotestit (100 kehystä + heap smoke test).
    memtest.runAll();
    // Boot on valmis — CI smoke-testi etsii tämän merkkijonon serialista.
    log.info("Zinux boot OK");
    // Smoke: lopeta heti perusalustuksen jälkeen (nopea CI / zig build run).
    if (boot_options.mode == .smoke) {
        // Vahvista smoke-polku serialiin.
        log.info("Smoke boot OK");
        // Pysäytä QEMU — ei aja integraatiotestejä.
        qemu_exit.exitSuccess();
    }
    // Full + dev: aja kaikki integraatiotestit (vaihe 4–18).
    boot_tests.runAll();
    // Logita SMP CPU-määrä Limine-vastauksesta (stub).
    smp.initAndLog();
    // Pakota pit_ticks linkitys (timerOnIrqC).
    _ = pit_ticks.count();
    // Scheduler ABAB-demo — dev jää ikuiseen idleen, full palaa ja lopettaa.
    const idle_forever = boot_options.mode == .dev;
    scheduler.start(idle_forever);
    // Full: kaikki testit + scheduler-demo valmis — lopeta QEMU.
    if (boot_options.mode == .full) {
        // Vahvista full-polku serialiin.
        log.info("Full boot OK");
        // Pysäytä QEMU siististi (ei timeoutia).
        qemu_exit.exitSuccess();
    }
    // Dev: scheduler.start palaa vain jos idle_forever=false — tänne ei päästä.
    while (true) {
        // CLI + HLT — varmuuden vuoksi jos dev-polku muuttuu.
        asm volatile ("cli; hlt" ::: .{ .memory = true });
    }
}
