//! x86_64 sivutus — 4-tasoinen paging (PML4 → PDPT → PD → PT).
//!
//! **Vastuu**: CR3-luku, sivutaulujen kävely, yhden sivun kartoitus.
//! **Riippuvuudet**: ei
//! **Käytetään**: `mm/vmm.zig`

// Sivukoko x86_64:ssa on 4 KiB.
pub const PAGE_SIZE: u64 = 4096;
// Bittien määrä virtuaaliosoitteen indeksissä per taso.
pub const INDEX_BITS: u64 = 9;
// Maski yhden tason indeksille (512 merkintää per taulu).
pub const INDEX_MASK: u64 = 0x1FF;

// Sivutaulumerkinnän liput (x86_64 PTE/PDE bits).
pub const PageFlags = packed struct(u64) {
    // Sivu/tau lu on present — CPU voi käyttää sitä.
    present: u1 = 1,
    // Kirjoitettavissa (writable) vs read-only.
    writable: u1 = 1,
    // Käyttäjätila (ring 3) pääsee sivulle.
    user: u1 = 0,
    // Write-through cache policy.
    write_through: u1 = 0,
    // Cache disable (UC-muisti).
    cache_disable: u1 = 0,
    // CPU asettaa accessed-bitin kun sivua luetaan.
    accessed: u1 = 0,
    // CPU asettaa dirty-bitin kun sivua kirjoitetaan.
    dirty: u1 = 0,
    // 2 MiB / 1 GiB huge page (PD/PDPT-taso).
    huge: u1 = 0,
    // Global page — ei flushata TLB:stä prosessinvaihdossa.
    global: u1 = 0,
    // Vapaasti käytettävät bitit ohjelmistolle.
    _avail: u3 = 0,
    // Fyysinen kehysnumero (bitit 51..12).
    addr: u52 = 0,

    // Muunna liput raa'aksi u64-arvoksi inline asm / muistinkirjoitusta varten.
    pub fn toU64(self: PageFlags) u64 {
        // Bitcast säilyttää bitit sellaisenaan.
        return @bitCast(self);
    }

    // Muunna raaka u64 → PageFlags-rakenne.
    pub fn fromU64(raw: u64) PageFlags {
        // Bitcast takaisin packed struct -muotoon.
        return @bitCast(raw);
    }
};

// 64-bit sivutaulumerkintä — sama rakenne kaikilla tasoilla.
pub const PageTableEntry = packed struct(u64) {
    // Present-bitti — 1 = merkintä aktiivinen.
    present: u1,
    // Writable-bitti — 1 = kirjoitus sallittu.
    writable: u1,
    // User/supervisor — 0 = vain ring 0.
    user: u1,
    // Write-through cache.
    write_through: u1,
    // Cache disabled.
    cache_disable: u1,
    // Accessed — CPU päivittää.
    accessed: u1,
    // Dirty — CPU päivittää kirjoituksessa.
    dirty: u1,
    // Huge page -merkintä.
    huge: u1,
    // Global TLB -merkintä.
    global: u1,
    // Ohjelmiston vapaat bitit.
    _avail: u3,
    // Fyysinen osoite ylempine bitteineen (>> 12).
    addr: u52,

    // Onko merkintä present (käytössä)?
    pub fn isPresent(self: PageTableEntry) bool {
        // Present-bitti 1 tarkoittaa aktiivista merkintää.
        return self.present == 1;
    }

    // Palauta merkinnän osoittama fyysinen osoite (4 KiB aligned).
    pub fn physicalAddr(self: PageTableEntry) u64 {
        // Siirrä addr-kenttä 12 bittiä vasemmalle → tavuosoite.
        return @as(u64, self.addr) << 12;
    }

    // Muodosta merkintä fyysisestä osoitteesta ja lipuista.
    pub fn fromPhys(phys: u64, flags: PageFlags) PageTableEntry {
        // Kopioi liput muokattavaksi.
        var f = flags;
        // Aseta fyysinen kehysnumero addr-kenttään.
        f.addr = @truncate(phys >> 12);
        // Palauta bitcastattuna PageTableEntry-muotoon.
        return @bitCast(f.toU64());
    }
};

// Callback tyyppi — allokoi yksi 4 KiB fyysinen kehys tai palauta null.
pub const FrameAllocFn = *const fn () ?u64;

// Lue CR3 — osoittaa aktiiviseen PML4-tauluun (fysinen osoite).
pub fn getCr3() u64 {
    // Rekisteri johon luetaan CR3.
    var cr3: u64 = undefined;
    // Lue CR3 CPU:sta inline assemblyllä.
    asm volatile ("mov %%cr3, %[out]"
        : [out] "=r" (cr3),
        :
        : .{ .memory = true });
    // Palauta aktiivisen sivutaulun fyysisen osoite.
    return cr3;
}

// Kirjoita CR3 — aktivoi uuden sivutaulun.
pub fn setCr3(pml4_phys: u64) void {
    // Kirjoita uusi PML4-osoite CR3-rekisteriin.
    asm volatile ("mov %[in], %%cr3"
        :
        : [in] "r" (pml4_phys),
        : .{ .memory = true });
}

// Lue CR2 — page fault -virheen virtuaaliosoite.
pub fn getCr2() u64 {
    // Rekisteri johon luetaan CR2.
    var cr2: u64 = undefined;
    // Lue CR2 inline assemblyllä.
    asm volatile ("mov %%cr2, %[out]"
        : [out] "=r" (cr2),
    );
    // Palauta page fault -osoite.
    return cr2;
}

// Poimi PML4-indeksi virtuaaliosoitteesta (bitit 47..39).
fn pml4Index(virt: u64) u64 {
    // Siirrä 39 bittiä oikealle ja maskaa 9 bittiä.
    return (virt >> 39) & INDEX_MASK;
}

// Poimi PDPT-indeksi (bitit 38..30).
fn pdptIndex(virt: u64) u64 {
    // Siirrä 30 bittiä oikealle ja maskaa 9 bittiä.
    return (virt >> 30) & INDEX_MASK;
}

// Poimi PD-indeksi (bitit 29..21).
fn pdIndex(virt: u64) u64 {
    // Siirrä 21 bittiä oikealle ja maskaa 9 bittiä.
    return (virt >> 21) & INDEX_MASK;
}

// Poimi PT-indeksi (bitit 20..12).
fn ptIndex(virt: u64) u64 {
    // Siirrä 12 bittiä oikealle ja maskaa 9 bittiä.
    return (virt >> 12) & INDEX_MASK;
}

// Muunna virtuaalinen sivutauluosoite HHDM:llä (phys + offset → virt).
pub fn physToVirt(phys: u64, hhdm: u64) [*]PageTableEntry {
    // HHDM: kaikki fyysinen RAM on virt = phys + hhdm.
    const virt = phys + hhdm;
    // Palauta osoitin sivutaulutaulukkona (512 merkintää).
    return @ptrFromInt(virt);
}

// Liput uudelle sivutaulukehykselle — present + writable, ei user.
const TABLE_FLAGS = PageFlags{
    // Sivutaulu on present.
    .present = 1,
    // Sivutaulu on kirjoitettavissa (kernel päivittää PTE:itä).
    .writable = 1,
    // Ei user-tilaa sivutauluille.
    .user = 0,
};

// Liput käyttäjäpolun sivutauluille — U=1 kaikilla tasoilla (ring 3 pääsy).
const USER_TABLE_FLAGS = PageFlags{
    // Sivutaulu on present.
    .present = 1,
    // Sivutaulu on kirjoitettavissa.
    .writable = 1,
    // Ring 3 saa käyttää tätä sivutaulupolkua.
    .user = 1,
};

// Nollaa 4 KiB kehys HHDM-virtuaaliosoitteella.
fn zeroFrame(phys: u64, hhdm: u64) void {
    // Muunna fyysinen kehys HHDM-virtuaaliosoitteeksi.
    const virt = phys + hhdm;
    // Osoitin kehyksen alkuun tavuina.
    const ptr: [*]u8 = @ptrFromInt(virt);
    // Nollaa koko sivu ennen sivutaulun käyttöä.
    @memset(ptr[0..PAGE_SIZE], 0);
}

// Varmista että sivutaulumerkintä osoittaa kehykseen — allokoi tarvittaessa.
fn ensureEntry(entry: *PageTableEntry, hhdm: u64, alloc_frame: FrameAllocFn, table_flags: PageFlags) bool {
    // Jos merkintä on jo present, ei tarvitse tehdä mitään.
    if (entry.isPresent()) return true;
    // Pyydä PMM:stä uusi 4 KiB kehys sivutaululle.
    const phys = alloc_frame() orelse return false;
    // Nollaa uusi sivutaulu — kaikkien PTE:iden pitää aluksi olla 0.
    zeroFrame(phys, hhdm);
    // Kirjoita merkintä osoittamaan uuteen sivutauluun.
    entry.* = PageTableEntry.fromPhys(phys, table_flags);
    // Onnistui — seuraava taso on nyt saatavilla.
    return true;
}

// Aseta user-bitti (U=1) yhdelle sivutaulumerkinnälle.
fn setEntryUserBit(entry: *PageTableEntry) void {
    // Kirjoita raakana — OR bitti 2 (user/supervisor).
    const raw: *volatile u64 = @ptrCast(entry);
    raw.* = raw.* | 0x4;
}

// Kartoita yksi 4 KiB sivu — luo puuttuvat PT/PD/PDPT-tasot PMM:stä.
pub fn mapPageEnsure(
    pml4_phys: u64,
    hhdm: u64,
    virt: u64,
    phys: u64,
    flags: PageFlags,
    alloc_frame: FrameAllocFn,
) bool {
    // Käytä kernel-only sivutaululippuja (oletus).
    return mapPageEnsureWithTables(pml4_phys, hhdm, virt, phys, flags, alloc_frame, TABLE_FLAGS);
}

// Kartoita yksi 4 KiB käyttäjäsivu — koko polku U=1 (ring 3 pääsy).
pub fn mapUserPageEnsure(
    pml4_phys: u64,
    hhdm: u64,
    virt: u64,
    phys: u64,
    flags: PageFlags,
    alloc_frame: FrameAllocFn,
) bool {
    // Käytä user-sivutaululippuja kaikilla luoduilla tasoilla.
    return mapPageEnsureWithTables(pml4_phys, hhdm, virt, phys, flags, alloc_frame, USER_TABLE_FLAGS);
}

// Kartoita yksi 4 KiB sivu — valittavilla sivutaululipuilla.
fn mapPageEnsureWithTables(
    pml4_phys: u64,
    hhdm: u64,
    virt: u64,
    phys: u64,
    flags: PageFlags,
    alloc_frame: FrameAllocFn,
    table_flags: PageFlags,
) bool {
    // Hae PML4-taulu HHDM:n kautta.
    const pml4 = physToVirt(pml4_phys, hhdm);
    // Valitse oikea PML4-merkintä virtuaaliosoitteen perusteella.
    const pml4e = &pml4[pml4Index(virt)];
    // Luo PML4-merkintä ja PDPT jos puuttuu (uusi virtuaalinen alue).
    if (!ensureEntry(pml4e, hhdm, alloc_frame, table_flags)) return false;
    // Seuraa PDPT-tasolle.
    const pdpt = physToVirt(pml4e.physicalAddr(), hhdm);
    // Valitse PDPT-merkintä.
    const pdpte = &pdpt[pdptIndex(virt)];
    // Luo PDPT-merkintä jos puuttuu.
    if (!ensureEntry(pdpte, hhdm, alloc_frame, table_flags)) return false;
    // Seuraa PD-tasolle.
    const pd = physToVirt(pdpte.physicalAddr(), hhdm);
    // Valitse PD-merkintä.
    const pde = &pd[pdIndex(virt)];
    // Luo PD-merkintä jos puuttuu.
    if (!ensureEntry(pde, hhdm, alloc_frame, table_flags)) return false;
    // 2 MiB huge page — ei voi kirjoittaa 4 KiB PTE:hen ilman splittausta.
    if (pde.huge == 1) return false;
    // Seuraa PT-tasolle.
    const pt = physToVirt(pde.physicalAddr(), hhdm);
    // Valitse lopullinen PTE-merkintä.
    const pte = &pt[ptIndex(virt)];
    // Kirjoita sivu kartoitukseen halutuilla lipuilla.
    pte.* = PageTableEntry.fromPhys(phys, flags);
    // Kartoitus valmis.
    return true;
}

// Kartoita yksi 4 KiB sivu olemassa olevaan PML4:ään (Limine page tables).
pub fn mapPage(pml4_phys: u64, hhdm: u64, virt: u64, phys: u64, flags: PageFlags) bool {
    // Hae PML4-taulu HHDM:n kautta.
    const pml4 = physToVirt(pml4_phys, hhdm);
    // Valitse PML4-merkintä.
    const pml4e = &pml4[pml4Index(virt)];
    // Kaikkien tasojen pitää olla valmiina — ei luo uusia.
    if (!pml4e.isPresent()) return false;
    // Seuraa PDPT-tasolle.
    const pdpt = physToVirt(pml4e.physicalAddr(), hhdm);
    // Valitse PDPT-merkintä.
    const pdpte = &pdpt[pdptIndex(virt)];
    // PDPT-merkinnän pitää olla present.
    if (!pdpte.isPresent()) return false;
    // Seuraa PD-tasolle.
    const pd = physToVirt(pdpte.physicalAddr(), hhdm);
    // Valitse PD-merkintä.
    const pde = &pd[pdIndex(virt)];
    // PD-merkinnän pitää olla present.
    if (!pde.isPresent()) return false;
    // Seuraa PT-tasolle.
    const pt = physToVirt(pde.physicalAddr(), hhdm);
    // Valitse PTE-merkintä.
    const pte = &pt[ptIndex(virt)];
    // Kirjoita sivu kartoitukseen.
    pte.* = PageTableEntry.fromPhys(phys, flags);
    // Onnistui ilman uusien taulujen luontia.
    return true;
}

// Palauta PTE:n raaka u64 (debug / NX-tarkistus).
pub fn getPteRaw(pml4_phys: u64, hhdm: u64, virt: u64) ?u64 {
    // Kävele sivutaulut lopulliseen PTE:hen.
    const pml4 = physToVirt(pml4_phys, hhdm);
    const pml4e = pml4[pml4Index(virt)];
    if (pml4e.present == 0) return null;
    const pdpt = physToVirt(pml4e.physicalAddr(), hhdm);
    const pdpte = pdpt[pdptIndex(virt)];
    if (pdpte.present == 0) return null;
    const pd = physToVirt(pdpte.physicalAddr(), hhdm);
    const pde = pd[pdIndex(virt)];
    if (pde.present == 0 or pde.huge == 1) return null;
    const pt = physToVirt(pde.physicalAddr(), hhdm);
    const pte = &pt[ptIndex(virt)];
    if (pte.present == 0) return null;
    // Palauta raaka PTE ilman packed struct -muunnosta.
    const pte_raw: *u64 = @ptrCast(pte);
    return pte_raw.*;
}

// Aseta koko sivutuspolku user-käyttöön; valinnainen NX-poisto lehti-PTE:stä.
pub fn setUserPagePath(pml4_phys: u64, hhdm: u64, virt: u64, executable: bool) bool {
    // Kävele sivutaulut lopulliseen PTE:hen.
    const pml4 = physToVirt(pml4_phys, hhdm);
    const pml4e = &pml4[pml4Index(virt)];
    if (pml4e.present == 0) return false;
    setEntryUserBit(pml4e);
    const pdpt = physToVirt(pml4e.physicalAddr(), hhdm);
    const pdpte = &pdpt[pdptIndex(virt)];
    if (pdpte.present == 0) return false;
    setEntryUserBit(pdpte);
    const pd = physToVirt(pdpte.physicalAddr(), hhdm);
    const pde = &pd[pdIndex(virt)];
    if (pde.present == 0 or pde.huge == 1) return false;
    setEntryUserBit(pde);
    const pt = physToVirt(pde.physicalAddr(), hhdm);
    const pte = &pt[ptIndex(virt)];
    if (pte.present == 0) return false;
    setEntryUserBit(pte);
    if (executable) {
        const pte_raw: *volatile u64 = @ptrCast(pte);
        const frame = pte_raw.* & 0x000FFFFFFFFFF000;
        pte_raw.* = frame | 0x7;
    }
    flushTlb(virt);
    setCr3(getCr3());
    return true;
}

// Aseta PTE user-bitti ja poista NX — varmistus ring 3 -sivuille (vanha nimi).
pub fn setPteUserExecutable(pml4_phys: u64, hhdm: u64, virt: u64) bool {
    return setUserPagePath(pml4_phys, hhdm, virt, true);
}

// TLB flush yhdelle sivulle — pakollinen PTE-muutoksen jälkeen.
pub fn flushTlb(virt: u64) void {
    // invlpg invalidoi yhden sivun TLB-merkinnän.
    asm volatile ("invlpg (%[addr])"
        :
        : [addr] "r" (virt),
        : .{ .memory = true });
}
