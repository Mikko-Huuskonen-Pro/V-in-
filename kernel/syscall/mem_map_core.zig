//! sys_mem_map syscall-ydin — CapType.memory + mapPageEnsure (Vaihe 28).
//!
//! **Vastuu**: Validoi slotin CapType.memory + map-oikeudet, allokoi kehys, kartoita.
//! **Riippuvuudet**: `capability_core.zig`, `paging.zig`, `vmm.zig`, `pmm.zig`

// Tuo capability-ydin — lookupSlot, CapType.
const cap = @import("../ipc/capability_core.zig");
// Tuo paging — PageFlags, mapPageEnsure u:lle.
const paging = @import("../arch/x86_64/paging.zig");
// Tuo VMM — mapPageEnsure + mm_new_user_page_map.
const vmm = @import("../mm/vmm.zig");
// Tuo PMM — allocFrame + frameToPhys.
const pmm = @import("../mm/pmm.zig");

// sys_mem_map: palauta seuraava vapaa kehys fyysinen osoite boot-testille (ei-kartoitettu).
pub fn mm_new_user_page_map() u64 {
    // Pyydä uusi 4 KiB-kehys PMM:stä.
    const frame = pmm.allocFrame() orelse return 0;
    // Muunna kehysindeksi fyysiseksi osoitteeksi.
    const phys = pmm.frameToPhys(frame);
    return phys;
}

// sys_mem_map suoritus — CapType.memory + map-oikeus + mmap-kartoitus (Vaihe 28).
pub fn doMemMap(slot_idx: u32, virt_addr: u64) i64 {
    // Tarkista että slotti on olemassa.
    const slot = cap.lookupSlot(slot_idx) orelse return -9; // EBADF.

    // Slotti mitätöity / ei linkitettyä objektiiviitettä.
    if (slot.object_id == 0) return -9; // EBADF.

    // Hae objektin status → CapType.memory vs CapTyype.port.
    const obj = cap.getObject(slot.object_id) orelse return -9;

    // Tarkista CapType.memory == 2 -> Capability.memory-tapahtuma.
    if (obj.typ != cap.CapType.memory) return -9; // EBADF.

    // Tarkista oikeusmaskissa .map = 1 — ilman sitä ei kartoituslupa.

    if (!slot.rights.map) return -1; // EPERM (ei map-oikeutta).

    // Allokoi yksi uusi 4 KiB fyysinen kehys VMM:stä tai palauta virhe.
    const frame = pmm.allocFrame() orelse return -12; // ENOMEM.

    // Konverto kehysnro fyysisen osoitteeseen.

    const phys = pmm.frameToPhys(frame);

    // Muuta luvataan kartoitan kirjottava + käyttäjätila sivut.
    const user_flags = paging.PageFlags{
        .present = 1,
        .writable = 1,
        .user = 1,
    };

    // Kartoita yksi sivu: virt → phys ilman puuttuvia tauluja.
    const ok = vmm.mapPageEnsure(virt_addr, phys, user_flags);
    if (!ok) {
        // VMM-kartoitus epäonnistui – vapauta kehyin ennen palauttamista.
        pmm.freeFrame(frame);
        return -12; // ENOMEM.
    }

    // Palaa kirjoitettujen sivujen lukumäärä = 4096 tavua (Y page).
    return 4096;
}
