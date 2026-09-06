//! Capability-syscall-ydin — oikeusmaskin dekoodaus ja virhekoodit (host-testattava).
//!
//! **Vastuu**: rights_mask → Rights, delegointivirheiden ABI-mapping.
//! **Riippuvuudet**: ei
//! **Käytetään**: `dispatch.zig`, `cap_syscall.zig`, host-testit

// EPERM — ei grant-oikeutta tai pyydetyt oikeudet ylittävät slotin.
pub const EPERM: i64 = -1;
// EBADF — virheellinen capability-slotti.
pub const EBADF: i64 = -9;
// EINVAL — varattu maski-bitti tai slottitaulukko täynnä.
pub const EINVAL: i64 = -22;

// Oikeusbitit rights_mask-argumentissa (sys_cap_delegate arg2).
pub const MASK_READ: u32 = 1 << 0;
// write-bitti maskissa.
pub const MASK_WRITE: u32 = 1 << 1;
// send-bitti maskissa.
pub const MASK_SEND: u32 = 1 << 2;
// recv-bitti maskissa.
pub const MASK_RECV: u32 = 1 << 3;
// map-bitti maskissa.
pub const MASK_MAP: u32 = 1 << 4;
// grant-bitti maskissa.
pub const MASK_GRANT: u32 = 1 << 5;
// Sallitut bitit yhdistettynä — varattujen bittien tarkistukseen.
pub const MASK_ALL: u32 = MASK_READ | MASK_WRITE | MASK_SEND | MASK_RECV | MASK_MAP | MASK_GRANT;

// Capability-tyyppi: IPC-portti (sys_cap_create arg1).
pub const CAP_TYPE_PORT: u32 = 1;
// Capability-tyyppi: muisti (sys_cap_create arg1, Vaihe 28).
pub const CAP_TYPE_MEMORY: u32 = 5;

// Onko sys_cap_create -tyyppi tuettu (Vaihe 28: +memory).
pub fn typeValid(typ: u32) bool {
    // Portti ja muisti-tyypit tuettu.
    return typ == CAP_TYPE_PORT or typ == CAP_TYPE_MEMORY;
}

// Rights packed struct — sama layout kuin capability_core.Rights.
pub const Rights = packed struct(u32) {
    // Luku-oikeus.
    read: bool = false,
    // Kirjoitus-oikeus.
    write: bool = false,
    // IPC-lähetys.
    send: bool = false,
    // IPC-vastaanotto.
    recv: bool = false,
    // Muistin kartoitus.
    map: bool = false,
    // Delegointioikeus.
    grant: bool = false,
    // Varattu — ei saa olla maskissa.
    _reserved: u26 = 0,
};

// Onko maskissa varattuja bittejä?
pub fn maskValid(mask: u32) bool {
    // Kaikkien bittien pitää olla MASK_ALL-joukkossa.
    return (mask & ~MASK_ALL) == 0;
}

// Muunna u32 rights_mask → Rights-rakenne.
pub fn rightsFromMask(mask: u32) ?Rights {
    // Hylkää varatut bitit.
    if (!maskValid(mask)) return null;
    // Rakenna Rights bitit maskista.
    return .{
        // read-bitti.
        .read = (mask & MASK_READ) != 0,
        // write-bitti.
        .write = (mask & MASK_WRITE) != 0,
        // send-bitti.
        .send = (mask & MASK_SEND) != 0,
        // recv-bitti.
        .recv = (mask & MASK_RECV) != 0,
        // map-bitti.
        .map = (mask & MASK_MAP) != 0,
        // grant-bitti.
        .grant = (mask & MASK_GRANT) != 0,
    };
}

// Muunna Rights-rakenne → u32 rights_mask.
pub fn rightsToMask(rights: Rights) u32 {
    // Aloita tyhjästä maskista.
    var mask: u32 = 0;
    // read-bitti päälle jos asetettu.
    if (rights.read) mask |= MASK_READ;
    // write-bitti päälle jos asetettu.
    if (rights.write) mask |= MASK_WRITE;
    // send-bitti päälle jos asetettu.
    if (rights.send) mask |= MASK_SEND;
    // recv-bitti päälle jos asetettu.
    if (rights.recv) mask |= MASK_RECV;
    // map-bitti päälle jos asetettu.
    if (rights.map) mask |= MASK_MAP;
    // grant-bitti päälle jos asetettu.
    if (rights.grant) mask |= MASK_GRANT;
    // Palauta koko maski.
    return mask;
}
