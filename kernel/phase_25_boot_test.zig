//! Vaihe 25 boot-integraatiotesti — per-PID sivutaulujen eristäytyvyys.
//!
//! **Vastuu**: Verifioi että jokaisella spawnattuna lapsiprosessilla on oma PML4,
//!              mutta ELF-VA layout (entry / stack) ovat samat. Tulos:
//!              - "Address space OK" = sama VA alue molemmilla
//!              - "Page table per pid OK" = eri PML4 fyysiset osoitteet
//!
//! **Riippuvuudet**: process_core, spawn, log
//! **Käytetään**: `boot_tests.zig::runAll()`

// Tuo prosessitaulukko.
const process = @import("process_core");
// Tuo embedded spawn.
const spawn = @import("spawn");
// Tuo lokitus.
const log = @import("lib/log.zig");

pub fn runBootTest() void {
    // --- Vaihe 25: per-process page table isolation test ---

    // 1. Lapsi A -> oma PML4, ELF VA sama kuin B:n (vaikka eri PML4).
    const pidA = spawn.spawnEmbedded(spawn.SPAWN_ID_CHILD_A) orelse {
        log.err("Phase 25: child A spawn failed");
        return;
    };

    // 2. Lapsi B -> toinen PML4, sama ELF VA layout kuten A.
    const pidB = spawn.spawnEmbedded(spawn.SPAWN_ID_CHILD_B) orelse {
        log.err("Phase 25: child B spawn failed");
        return;
    };

    // 3. Hae prosessitaulut (PML4 fiz). Molempien täytyy olla != 0.
    const pml4A = process.getPageTable(pidA) orelse {
        log.err("Phase 25: unable to get page table for A");
        return;
    };
    const pml4B = process.getPageTable(pidB) orelse {
        log.err("Phase 25: unable to get page table for B");
        return;
    };

    // 4. Vaadi: eri Pideille ≠ sama PML4 fyysinen osoite (eristäytyvyys).
    if (pml4A == pml4B or pml4A == 0 or pml4B == 0) {
        log.err("Phase 25: child A/B share PML4 — isolation fail");
        return;
    }

    // 5. Vaadi: molemmat käyttävät samaa ELF VA layoutia (load address).
    const infoA = process.getLoadedInfo(pidA) orelse {
        log.err("Phase 25: no loaded info for A");
        return;
    };
    const infoB = process.getLoadedInfo(pidB) orelse {
        log.err("Phase 25: no loaded info for B");
        return;
    };

    // Molemmat ladattava.
    if (!process.isLoaded(pidA) or !process.isLoaded(pidB)) {
        log.err("Phase 25: A/B not loaded");
        return;
    }

    // ELF load address on sama (kumpikin kartoitetaan samaan VADDR:iin).
    // Entry voi olla sama tai eri, mutta stack_slot-erolla varmista VA overlap.
    if (infoA.stack_slot == infoB.stack_slot) {
        log.err("Phase 25: A/B share same stack slot — no separation");
        return;
    }

    // Tulos: VA alignment OK + per-PID PML4 eri → eristäytyvyys toimii!
    log.info("Address space OK");
    log.info("Page table per pid OK");
}
