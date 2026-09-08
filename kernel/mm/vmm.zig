//! Virtuaalimuistinhallinta (VMM) — sivukartoitus Limine CR3:n päällä.
//!
//! **Vastuu**: Sivukartoitus CR3:n kautta, HHDM-muunnos, uusien sivutaulujen luonti.
//! **Riippuvuudet**: `../arch/x86_64/paging.zig`, `pmm.zig`
//! **Käytetään**: `kernel/main.zig`, `heap.zig`

// Tuo paging — CR3, mapPage, mapPageEnsure, flushTlb.
const paging = @import("../arch/x86_64/paging.zig");
// Tuo PMM — fyysisten kehysten allokointi uusille sivutauluille.
const pmm = @import("pmm.zig");

// HHDM-offset — muunna phys → virt lisäämällä tämä (alustetaan bootissa).
pub var hhdm_offset: u64 = undefined;
// Aktiivisen PML4-taulun fyysinen osoite (Liminen CR3 bootissa, alustetaan bootissa).
pub var kernel_pml4_phys: u64 = undefined;
// Vaihe 25 kohde-PML4 per-prosessikartoitusta varten (null = käytä kernel-PML4).
// HUOM: ei saa olla `undefined` — varhainen heap.init lukee tämän ennen
// ensimmäistä spawn-kirjoitusta, ja undefined-luku taittui kääntäjässä
// roskaksi (pml4_phys=0xE → ud2 QEMU-smokessa).
pub var target_pml4_phys: ?u64 = null;
// PMM-callback paging.mapPageEnsure:lle — palauttaa uuden kehyksen fyysinen osoite.
fn allocFramePhys() ?u64 {
    // Allokoi vapaa 4 KiB kehys bitmapista.
    const frame = pmm.allocFrame() orelse return null;
    // Muunna kehysindeksi fyysiseksi tavuosoitteeksi.
    return pmm.frameToPhys(frame);
}

// Alusta VMM — tallenna HHDM ja Liminen PML4 (CR3).
pub fn init(hhdm_off: u64) void {
    // Tallenna HHDM kaikkea phys→virt -muunnosta varten.
    hhdm_offset = hhdm_off;
    // Lue Liminen valmiiksi kartoittama PML4 CR3:stä.
    kernel_pml4_phys = paging.getCr3();
}

// Kartoita virtuaalinen sivu fyysiseen kehykseen (vaatii valmiit sivutaulut).
pub fn mapPage(virt: u64, phys: u64, flags: paging.PageFlags) bool {
    // Yritä kartoitus olemassa oleviin Limine-tauluihin.
    const ok = paging.mapPage(kernel_pml4_phys, hhdm_offset, virt, phys, flags);
    // Flushaa TLB jos kartoitus onnistui.
    if (ok) paging.flushTlb(virt);
    // Palauta onnistuminen kutsujalle.
    return ok;
}

// Kartoita virtuaalinen sivu — luo puuttuvat sivutaulut PMM:stä tarvittaessa.
pub fn mapPageEnsure(virt: u64, phys: u64, flags: paging.PageFlags) bool {
    // Käy sivutaulut läpi ja allokoi puuttuvat tasot PMM:stä.
    // Vaihe 25: käytä kohde-PML4/per-process taulua jos asetettu.
    const ok = paging.mapPageEnsure(
        pml4Phys(),
        hhdm_offset,
        virt,
        phys,
        flags,
        allocFramePhys,
    );
    // Jos uusia sivutauluja (PML4/PDPT/PD) luotiin, ladataan CR3 uudelleen,
    // jotta CPU näkee uudet hakemistorakenteet ja TLB tyhjentyy.
    if (ok) paging.setCr3(paging.getCr3());
    return ok;
}

// Allokoi vapaa kehys PMM:stä ja kartoita se virtuaaliosoitteeseen (valmiit taulut).
pub fn mapNewPage(virt: u64, flags: paging.PageFlags) bool {
    // Allokoi fyysinen kehys bitmapista.
    const frame = pmm.allocFrame() orelse return false;
    // Muunna kehysindeksi fyysiseksi osoitteeksi.
    const phys = pmm.frameToPhys(frame);
    // Kartoita kehys virtuaaliosoitteeseen.
    return mapPage(virt, phys, flags);
}

// Allokoi kehys ja kartoita — luo sivutaulut tarvittaessa (käyttäjäpolku U=1).
pub fn mapNewUserPageEnsure(virt: u64, flags: paging.PageFlags) bool {
    // Allokoi fyysinen kehys bitmapista.
    const frame = pmm.allocFrame() orelse return false;
    // Muunna kehysindeksi fyysiseksi osoitteeksi.
    const phys = pmm.frameToPhys(frame);
    // Kartoita kehys luoden user-sivutaulut.
    // Vaihe 25: kartoita kohde-PML4:n päälle (per-process page table).
    const ok = paging.mapUserPageEnsure(
        pml4Phys(),
        hhdm_offset,
        virt,
        phys,
        flags,
        allocFramePhys,
    );
    // Flushaa TLB uuden kartoituksen jälkeen.
    if (ok) paging.flushTlb(virt);
    return ok;
}

// Allokoi kehys ja kartoita — luo sivutaulut tarvittaessa.
pub fn mapNewPageEnsure(virt: u64, flags: paging.PageFlags) bool {
    // Allokoi fyysinen kehys bitmapista.
    const frame = pmm.allocFrame() orelse return false;
    // Muunna kehysindeksi fyysiseksi osoitteeksi.
    const phys = pmm.frameToPhys(frame);
    // Kartoita kehys luoden puuttuvat sivutaulut.
    return mapPageEnsure(virt, phys, flags);
}

// Kopioi kernel-PML4:n yläpuolisko (indeksit 256..511) lapsen tuoreeseen
// PML4:ään. Lapsi tarvitsee kernel-kartoitukset syscalleja ja IRQ-käsit-
// telijöitä varten — muuten ensimmäinen ring-3 syscall aiheuttaa page faultin.
// HUOM: alemmat taulut jaetaan kernelin kanssa (ei CoW:a); lapsen omat
// user-kartoitukset näkyvät siksi myös kernel-PML4:n kautta. Täysi
// alitaulujen eristys on tulevaa työtä — PML4-taso eristää jo nyt.
pub fn inheritKernelHalf(child_pml4_phys: u64) void {
    // Lapsen tyhjä PML4 HHDM:n kautta.
    const child: [*]paging.PageTableEntry = @ptrFromInt(physToVirt(child_pml4_phys));
    // Kernelin aktiivinen PML4 HHDM:n kautta.
    const kernel: [*]paging.PageTableEntry = @ptrFromInt(physToVirt(kernel_pml4_phys));
    // Kopioi yläpuolisko merkintä kerrallaan.
    var i: usize = 256;
    while (i < 512) : (i += 1) {
        child[i] = kernel[i];
    }
}
// Palauta HHDM-offset (fys → virt: virt = phys + offset).
pub fn hhdm() u64 {
    // Palauta tallennettu Limine HHDM-offset.
    return hhdm_offset;
}

// Palauta aktiivisen PML4:n fyysinen osoite.
pub fn pml4Phys() u64 {
    // Vaihe 25: palauta kohde-PML4 jos asetettu, muuten kernel-boot.
    return target_pml4_phys orelse kernel_pml4_phys;
}

// Kohde-PML4:n asetus/tyhjennys on siirretty spawn.zig:in suoraan kirjoitukseen
// target_pml4_phys-n läpi — ei enää tarvetta erillisille accessor-funktioille.

// Muunna fyysinen osoite HHDM-virtuaaliosoitteeksi.
pub fn physToVirt(phys: u64) u64 {
    // HHDM direct map: virt = phys + hhdm_offset.
    return phys + hhdm_offset;
}

// Kernel data -sivujen oletusliput — present, writable, kernel-only.
pub const KERNEL_DATA_FLAGS = paging.PageFlags{
    // Sivu on present.
    .present = 1,
    // Sivu on kirjoitettavissa.
    .writable = 1,
    // Ei user-tilaa — vain ring 0.
    .user = 0,
};
