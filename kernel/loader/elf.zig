//! ELF64-loader — PT_LOAD kartoitus ring 3 -prosessille.
//!
//! **Vastuu**: Jäsennä ELF, kartoita segmentit VMM:llä, käynnistä boot-testi.
//! **Riippuvuudet**: `elf_core.zig`, `vmm.zig`, `paging.zig`, `usermode.zig`
//! **Käytetään**: `kernel/main.zig`

// Tuo ELF-jäsennyksen ydin.
const core = @import("elf_core.zig");
// Tuo VMM — user-sivujen kartoitus.
const vmm = @import("../mm/vmm.zig");
// Tuo sivutus — PAGE_SIZE ja user-polku.
const paging = @import("../arch/x86_64/paging.zig");
// Tuo ring 3 siirtymä — iretq + paluu.
const usermode = @import("../arch/x86_64/usermode.zig");
// Tuo lokitus boot-viesteihin.
const log = @import("../lib/log.zig");
// Tuo user_access — stac/clac SMAP-yhteensopivuuteen user-sivuille.
const user_access = @import("../arch/x86_64/user_access.zig");
// Tuo heap — kiinteät user-ELF linkitysosoitteet (slot 0 = HEAP_START).
const heap = @import("../mm/heap.zig");

// Upotettu loader-testi ELF — build.zig kopioi user-bin:n tähän ennen kernel-käännöstä.
const test_elf = @embedFile("test_prog.bin");

// Loader-testin pinon heap-slot (slot 33).
const LOADER_TEST_STACK_SLOT: u64 = 33;

// Ladattu käyttäjäkuva — entry + pinon huippu.
pub const LoadedImage = struct {
    // ELF e_entry — suoritus alkaa täältä.
    entry: u64,
    // Käyttäjäpinon yläreuna ring 3:lle.
    stack_top: u64,
};

// Ring 3 sivulippu — present + writable + user (data/rodata).
const USER_RW_FLAGS = paging.PageFlags{
    // Sivu kartoitettu.
    .present = 1,
    // Kirjoitus sallittu (data/BSS).
    .writable = 1,
    // Ring 3 pääsee sivulle.
    .user = 1,
};

// Kartoita yksi 4 KiB sivu segmentille — älä ylikirjoita jo kartoitettua sivua.
fn mapUserPage(virt: u64, executable: bool) bool {
    // Tarkista onko sivu jo kartoitettu (useat PT_LOAD samalla sivulla).
    const already = paging.getPteRaw(vmm.pml4Phys(), vmm.hhdm(), virt) != null;
    // Uusi sivu — allokoi PMM:stä ja kartoita writable latausta varten.
    if (!already) {
        if (!vmm.mapNewUserPageEnsure(virt, USER_RW_FLAGS)) return false;
    }
    // Suoritettava segmentti samalla sivulla — varmista NX pois.
    if (executable) {
        return paging.setUserPagePath(vmm.pml4Phys(), vmm.hhdm(), virt, true);
    }
    // Ensimmäinen ei-suoritettava kartoitus — aseta user-bitti.
    if (!already) {
        return paging.setUserPagePath(vmm.pml4Phys(), vmm.hhdm(), virt, false);
    }
    // Sivu jo olemassa (esim. .text + .rodata) — säilytä olemassa oleva kartoitus.
    return true;
}

// Kartoita [vaddr, vaddr+mem_size) sivu kerrallaan.
fn mapSegmentRange(vaddr: u64, mem_size: u64, executable: bool) bool {
    // Sivun koko x86_64:ssa.
    const page_size = paging.PAGE_SIZE;
    // Ensimmäinen sivu alueen alussa (tasattu alaspäin).
    var page = vaddr & ~(page_size - 1);
    // Alueen yläraja (exclusive).
    const end = vaddr + mem_size;
    // Käy jokainen sivu alueella.
    while (page < end) {
        // Kartoita yksi sivu.
        if (!mapUserPage(page, executable)) return false;
        // Seuraava sivu.
        page += page_size;
    }
    // Kaikki sivut kartoitettu.
    return true;
}

// Kopioi segmentin file-osuus ELF-blobista + nollaa BSS.
// Kohde kirjoitetaan HHDM-aliasen kautta: kartoitus on saatettu tehdä
// kohde-PML4:ään (per-process spawn), jota kernelin aktiivinen CR3 ei
// välttämättä näe — suora vaddr-kirjoitus aiheuttaisi page faultin.
fn copySegmentData(seg: core.LoadSegment, elf_data: []const u8) bool {
    // Segmentin file data ELF-blobissa.
    if (seg.file_offset + seg.file_size > elf_data.len) return false;
    // SMAP: salli user-sivujen kirjoitus kernelistä.
    user_access.stac();
    // Kopioi alustettu osa sivu kerrallaan HHDM-aliasen kautta.
    var off: u64 = 0;
    while (off < seg.file_size) {
        // Kohdesivun alku ja offset sivun sisällä.
        const vpage = (seg.vaddr + off) & ~(paging.PAGE_SIZE - 1);
        const page_off = (seg.vaddr + off) & (paging.PAGE_SIZE - 1);
        // Etsi kehyksen fyysinen osoite kohde-PML4:stä.
        const pte_raw = paging.getPteRaw(vmm.pml4Phys(), vmm.hhdm(), vpage) orelse {
            user_access.clac();
            return false;
        };
        // Kehyksen alku (4 KiB tasattu) + HHDM-alias + sivun sisäinen offset.
        const phys = pte_raw & 0x000FFFFFFFFFF000;
        const hptr: [*]u8 = @ptrFromInt(vmm.physToVirt(phys) + page_off);
        // Tämän sivun osuus (ei sivurajan yli).
        const n = @min(paging.PAGE_SIZE - page_off, seg.file_size - off);
        // Kopioi yksi pätkä ELF-blobista.
        @memcpy(hptr[0..n], elf_data[seg.file_offset + off ..][0..n]);
        // Seuraava pätkä.
        off += n;
    }
    // Nollaa BSS (mem_size - file_size) jos on.
    if (seg.mem_size > seg.file_size) {
        // BSS-alue sivu kerrallaan HHDM-aliasen kautta.
        var bss_off: u64 = seg.file_size;
        while (bss_off < seg.mem_size) {
            const vpage = (seg.vaddr + bss_off) & ~(paging.PAGE_SIZE - 1);
            const page_off = (seg.vaddr + bss_off) & (paging.PAGE_SIZE - 1);
            const pte_raw = paging.getPteRaw(vmm.pml4Phys(), vmm.hhdm(), vpage) orelse {
                user_access.clac();
                return false;
            };
            const phys = pte_raw & 0x000FFFFFFFFFF000;
            const hptr: [*]u8 = @ptrFromInt(vmm.physToVirt(phys) + page_off);
            const n = @min(paging.PAGE_SIZE - page_off, seg.mem_size - bss_off);
            @memset(hptr[0..n], 0);
            bss_off += n;
        }
    }
    // Palauta SMAP-suojaus.
    user_access.clac();
    return true;
}

// Laske pinon sivun virtuaalinen alku annetusta heap-slotista.
fn stackBaseForSlot(stack_slot: u64) u64 {
    // Kiinteä HEAP_START + slot × 4 KiB (user-ELF linkitysosoitteet).
    return heap.HEAP_START + stack_slot * paging.PAGE_SIZE;
}

// Laske pinon yläreuna iretq:ä varten (16 tavun aligned).
fn stackTopForSlot(stack_slot: u64) u64 {
    // Yksi sivu pinolle — yläreuna - 16 tavua.
    return stackBaseForSlot(stack_slot) + paging.PAGE_SIZE - 16;
}

// Kartoita käyttäjäpinon yksi sivu annettuun osoitteeseen.
fn mapUserStackAt(stack_base: u64) bool {
    // Kartoita pinosivu (writable, ei executable).
    return mapUserPage(stack_base, false);
}

// Lataa jäsennetty ELF muistiiin — pinon sivu stack_base:ssa.
fn loadParsed(parsed: core.ParsedElf, elf_data: []const u8, stack_base: u64) bool {
    // Kartoita jokainen PT_LOAD-segmentti.
    for (parsed.segments) |seg| {
        // Suoritettavuus PF_X-bitistä.
        const executable = core.segmentExecutable(seg);
        // Kartoita sivut segmentin linkitys-vaddr:iin.
        if (!mapSegmentRange(seg.vaddr, seg.mem_size, executable)) return false;
        // Kopioi tiedot ELF-blobista segmenttiin.
        if (!copySegmentData(seg, elf_data)) return false;
    }
    // Kartoita erillinen käyttäjäpinon sivu annettuun osoitteeseen.
    if (!mapUserStackAt(stack_base)) return false;
    // Kaikki segmentit + pino valmiina.
    return true;
}

// Lataa ELF blobista — jäsentää, kartoittaa ja palauttaa entry + stack_top.
pub fn loadElfWithStack(elf_data: []const u8, stack_slot: u64) ?LoadedImage {
    // Segmenttipuskuri parseElf:lle.
    var segments: [core.MAX_LOAD_SEGMENTS]core.LoadSegment = undefined;
    // Jäsennä ELF-otsikko ja PT_LOAD:t.
    const parsed = core.parseElf(elf_data, &segments) catch return null;
    // Pinon sivun alku valitusta slotista.
    const stack_base = stackBaseForSlot(stack_slot);
    // Kartoita segmentit ja pino.
    if (!loadParsed(parsed, elf_data, stack_base)) return null;
    // Palauta hyppypiste ja pinon yläreuna (slidattu entry).
    return .{
        .entry = parsed.entry,
        .stack_top = stackTopForSlot(stack_slot),
    };
}

// Lataa ELF blobista — oletuspino (loader-testi slot 33).
pub fn loadElf(elf_data: []const u8) ?LoadedImage {
    // Delegoi stack_slot-parametrilla.
    return loadElfWithStack(elf_data, LOADER_TEST_STACK_SLOT);
}

// Boot-testi — lataa upotettu ELF, aja ring 3 (sys_write "elf" + paluu).
pub fn runBootTest() void {
    // Lataa test_elf blob kernel-muistiin / sivuja.
    const loaded = loadElfWithStack(test_elf, LOADER_TEST_STACK_SLOT) orelse {
        // Jäsentäminen tai kartoitus epäonnistui.
        log.err("ELF load failed");
        return;
    };
    // Siirry ring 3:een ladatun entry:n kautta.
    usermode.enterUser(loaded.entry, loaded.stack_top);
    // Paluu sys_test_return ret:llä (sama kuin usermode-testi).
    log.info("ELF loader test OK");
}
