//! Capability-ydin — objektit, oikeudet ja delegointi (host-testattava).
//!
//! **Vastuu**: Capability-objektitaulukko, slotit, oikeuksien tarkistus.
//! **Riippuvuudet**: ei
//! **Käytetään**: `capability.zig`, host-testit

// Tuo audit-ydin — rengaspuskuri capability-tapahtumille (Vaihe 7.4).
const audit = @import("cap_audit_core");
// Tuo porttien ydin — vapauta IPC-portti portti-capabilityn peruutuksessa.
const port_core = @import("port_core.zig");
// Tuo prosessitaulukko — capability-slotit per pid (Vaihe 20).
const process = @import("process_core");

// Capability-objektin tyyppi — mitä resurssia handle edustaa.
pub const CapType = enum(u8) {
    // Tyhjä / virheellinen tyyppi.
    null = 0,
    // IPC-portti (send/recv).
    port = 1,
    // Muistialue (map/read/write).
    memory = 2,
    // IRQ-vektori (myöhemmin).
    irq = 3,
    // Endpoint stub tulevaan IPC:hen.
    endpoint = 4,
};

// Oikeusbitit — delegointi voi siirtää vain osajoukon.
pub const Rights = packed struct(u32) {
    // Luku-oikeus (muisti, portti-metadata).
    read: bool = false,
    // Kirjoitus-oikeus.
    write: bool = false,
    // IPC-lähetys porttiin.
    send: bool = false,
    // IPC-vastaanotto portista.
    recv: bool = false,
    // Muistin kartoitus (mmap).
    map: bool = false,
    // Oikeuksien edelleen delegointi.
    grant: bool = false,
    // Varattu tuleville biteille.
    _reserved: u26 = 0,
};

// Yksittäinen capability-objekti kernelin globaalissa taulukossa.
pub const CapObject = packed struct {
    // Onko objektipaikka käytössä.
    used: bool,
    // Objektin tyyppi (port, memory, …).
    typ: CapType,
    // Omistava prosessi (stub: aina 1 boot-vaiheessa).
    owner_pid: u64,
    // Tyypin spesifinen tunniste (port_id, region_id, …).
    object_id: u64,
};

// Prosessin capability-viite — objektin id + rajatut oikeudet.
pub const CapRef = struct {
    // Viite globaalin taulukon objektiin (0 = virheellinen).
    object_id: u32,
    // Tähän slottiin liitetyt oikeudet.
    rights: Rights,
};

// Maksimi capability-objektien määrä kernelissä.
pub const MAX_OBJECTS: usize = 64;
// Maksimi slottien määrä prosessia kohden (stub-yksi prosessi).
pub const MAX_SLOTS: usize = 32;

// Globaalit capability-objektit — indeksi = object_id.
var objects: [MAX_OBJECTS]CapObject = undefined;
// Seuraava vapaa object_id (1..MAX_OBJECTS-1) — ei käytössä indeksipohjaisessa mallissa.
var next_object_id: u32 = 1;
// Capability-slotit prosessikohtaisesti — [prosessi-indeksi][slot].
var slots: [process.MAX_PROCESSES][MAX_SLOTS]CapRef = undefined;
// Montako slottia kussakin prosessissa on käytössä.
var slot_counts: [process.MAX_PROCESSES]usize = .{0} ** process.MAX_PROCESSES;
// Onko ydin alustettu.
var initialized: bool = false;

// Tarkista että `requested`-oikeudet ovat osajoukko `granted`:sta.
pub fn rightsSubset(granted: Rights, requested: Rights) bool {
    // read-bit: pyydetty vaatii granted.read.
    if (requested.read and !granted.read) return false;
    // write-bit: pyydetty vaatii granted.write.
    if (requested.write and !granted.write) return false;
    // send-bit: pyydetty vaatii granted.send.
    if (requested.send and !granted.send) return false;
    // recv-bit: pyydetty vaatii granted.recv.
    if (requested.recv and !granted.recv) return false;
    // map-bit: pyydetty vaatii granted.map.
    if (requested.map and !granted.map) return false;
    // grant-bit: pyydetty vaatii granted.grant.
    if (requested.grant and !granted.grant) return false;
    // Kaikki pyydetyt bitit sallittu.
    return true;
}

// Leikkaa kaksi oikeusjoukkoa (delegointiin).
pub fn rightsIntersect(a: Rights, b: Rights) Rights {
    // Palauta bitit jotka ovat molemmissa.
    return .{
        // read vain jos molemmissa.
        .read = a.read and b.read,
        // write vain jos molemmissa.
        .write = a.write and b.write,
        // send vain jos molemmissa.
        .send = a.send and b.send,
        // recv vain jos molemmissa.
        .recv = a.recv and b.recv,
        // map vain jos molemmissa.
        .map = a.map and b.map,
        // grant vain jos molemmissa.
        .grant = a.grant and b.grant,
    };
}

// Vaihe 29.1 — Rights-maskiapurit plugin-scopelle (ei kiertoa scope.zig:iin).
//
// **Vastuu**: Muunna Rights ↔ u32 ja tarkista scope-ehto ilman scope-importtia.
// **Miksi täällä**: scope.zig on riippuvuudeton; tämä pitää bittilayoutin yhdessä
//   paikassa kernelin puolella. Bitit täsmäävät cap_syscall_core.MASK_*.
//   Tyyppibitit käyttävät ABI-numeroita (1=port, 5=memory); kernel-enum .memory
//   (arvo 2) kartoitetaan ABI-bitille 5 jotta manifest/scope täsmäävät dispatchiin.

// Muunna Rights → u32 maski (scope/manifest vertailuun).
pub fn rightsToMask(rights: Rights) u32 {
    // Aloita tyhjästä maskista.
    var mask: u32 = 0;
    // read-bit.
    if (rights.read) mask |= 1 << 0;
    // write-bit.
    if (rights.write) mask |= 1 << 1;
    // send-bit.
    if (rights.send) mask |= 1 << 2;
    // recv-bit.
    if (rights.recv) mask |= 1 << 3;
    // map-bit.
    if (rights.map) mask |= 1 << 4;
    // grant-bit.
    if (rights.grant) mask |= 1 << 5;
    // Palauta maski.
    return mask;
}

// Onko Rights annetun scope-oikeusmaskin osajoukko.
pub fn rightsWithinMask(rights: Rights, allowed_mask: u32) bool {
    // Muunna rakenne maskiksi.
    const have = rightsToMask(rights);
    // Varatut bitit sallitussa maskissa hylätään (kutsujan bugi).
    if ((allowed_mask & ~@as(u32, 0x3F)) != 0) return false;
    // Jokaisen pyydetyn bitin pitää löytyä sallitusta.
    return (have & ~allowed_mask) == 0;
}

// Palauta CapType:n ABI-bitti scope-vertailuun (1<<abi_numero).
pub fn typeBit(typ: CapType) u32 {
    // Portti on ABI 1.
    if (typ == .port) return @as(u32, 1) << 1;
    // Kernel-enum .memory (2) luodaan ABI-tyypillä 5 (dispatch-reititys).
    if (typ == .memory) return @as(u32, 1) << 5;
    // IRQ-vektori (tuleva).
    if (typ == .irq) return @as(u32, 1) << 3;
    // Endpoint stub (tuleva IPC).
    if (typ == .endpoint) return @as(u32, 1) << 4;
    // Null ei koskaan sallittu.
    return 0;
}

// Tarkista scope-ehto: tyyppi sallittu JA oikeudet maskin sisällä.
pub fn scopeAllows(allowed_types_mask: u32, allowed_rights_mask: u32, typ: CapType, rights: Rights) bool {
    // Tyyppibitin pitää löytyä sallitusta maskista.
    const bit = typeBit(typ);
    // Null tai tuntematon tyyppi hylätään.
    if (bit == 0) return false;
    // Tyyppi ei sallittu scopessa.
    if ((allowed_types_mask & bit) == 0) return false;
    // Oikeudet scopen ulkopuolella.
    if (!rightsWithinMask(rights, allowed_rights_mask)) return false;
    // Molemmat ehdot täyttyvät.
    return true;
}

// Nollaa objektit ja slotit — kutsutaan bootissa ja testeissä.
pub fn initCore() void {
    // Alusta prosessitaulukko (rekisteröi boot-pid 1).
    process.initCore();
    // Nollaa audit-loki samalla (create/delegate lokitus).
    audit.initCore();
    // Tyhjennä kaikki objektipaikat.
    for (&objects) |*obj| {
        // Merkitse vapaa.
        obj.used = false;
        // Nollaa tyyppi.
        obj.typ = .null;
        // Ei omistajaa.
        obj.owner_pid = 0;
        // Ei objektitunnistetta.
        obj.object_id = 0;
    }
    // Tyhjennä jokaisen prosessin slotit.
    var pi: usize = 0;
    while (pi < process.MAX_PROCESSES) : (pi += 1) {
        // Nollaa slottilaskuri.
        slot_counts[pi] = 0;
        // Tyhjennä slotitaulukko.
        var si: usize = 0;
        while (si < MAX_SLOTS) : (si += 1) {
            // Ei objektiviitettä.
            slots[pi][si].object_id = 0;
            // Ei oikeuksia.
            slots[pi][si].rights = .{};
        }
    }
    // Ensimmäinen id alkaa 1:stä (0 = virheellinen).
    next_object_id = 1;
    // Merkitse alustetuksi.
    initialized = true;
}

// Luo uusi capability-objekti kernel-taulukkoon.
pub fn createObject(typ: CapType, owner_pid: u64, resource_id: u64) ?u32 {
    // Vaadi priori alustus.
    if (!initialized) return null;
    // Etsi vapaa paikka objects-taulukosta.
    var i: usize = 0;
    while (i < objects.len) : (i += 1) {
        // Ohita käytössä olevat paikat.
        if (objects[i].used) continue;
        // Objektin id = taulukko-indeksi + 1 (getObject(id) → objects[id-1]).
        const id: u32 = @intCast(i + 1);
        // Täytä objektikentät.
        objects[i] = .{
            // Paikka käytössä.
            .used = true,
            // Aseta tyyppi.
            .typ = typ,
            // Omistaja-prosessi.
            .owner_pid = owner_pid,
            // Resurssin tunniste (esim. port_num).
            .object_id = resource_id,
        };
        // Kasvata seuraavaa id:tä (tilastoa varten).
        if (id >= next_object_id) next_object_id = id + 1;
        // Audit: objekti luotu (ei oikeuksia vielä — asennetaan installSlot:ssa).
        audit.record(.create, owner_pid, id, audit.NO_SLOT, @bitCast(Rights{}), @intFromEnum(typ));
        // Palauta uuden objektin id.
        return id;
    }
    // Taulukko täynnä.
    return null;
}

// Hae objekti id:llä — null jos puuttuu tai vapaa.
pub fn getObject(id: u32) ?*CapObject {
    // Id 0 on aina virheellinen.
    if (id == 0 or id > objects.len) return null;
    // Indeksi = id - 1 (id 1 → objects[0]).
    const idx: usize = @intCast(id - 1);
    // Hae osoitin objektiin.
    const obj = &objects[idx];
    // Palauta vain jos käytössä.
    if (!obj.used) return null;
    // Kelvollinen objekti.
    return obj;
}

// Asenna capability annetun prosessin slottiin — palauttaa slot-indeksin.
pub fn installSlotForPid(pid: u64, object_id: u32, rights: Rights) ?u32 {
    // Vaadi alustus.
    if (!initialized) return null;
    // Objektin pitää olla olemassa.
    if (getObject(object_id) == null) return null;
    // Hae prosessin taulukkoindeksi.
    const proc_idx = process.findIndex(pid) orelse return null;
    // Slottitaulukko täynnä tälle prosessille.
    if (slot_counts[proc_idx] >= MAX_SLOTS) return null;
    // Uuden slotin indeksi prosessin slot-listassa.
    const slot_idx: u32 = @intCast(slot_counts[proc_idx]);
    // Täytä slotti.
    slots[proc_idx][slot_counts[proc_idx]] = .{
        // Viite objektiin.
        .object_id = object_id,
        // Alkuperäiset oikeudet.
        .rights = rights,
    };
    // Kasvata prosessin slottilaskuria.
    slot_counts[proc_idx] += 1;
    // Hae objekti audit-merkintää varten.
    const obj = getObject(object_id) orelse return null;
    // Audit: capability asennettu slottiin.
    audit.record(.install, obj.owner_pid, object_id, slot_idx, @bitCast(rights), @intFromEnum(obj.typ));
    // Palauta slot-indeksi prosessille.
    return slot_idx;
}

// Asenna capability nykyisen prosessin slottiin — palauttaa slot-indeksin.
pub fn installSlot(object_id: u32, rights: Rights) ?u32 {
    // Delegoi nykyisen prosessin asennukseen.
    return installSlotForPid(process.currentPid(), object_id, rights);
}

// Hae capability-slotti annetulta prosessilta.
pub fn lookupSlotForPid(pid: u64, slot_idx: u32) ?CapRef {
    // Vaadi alustus.
    if (!initialized) return null;
    // Hae prosessin taulukkoindeksi.
    const proc_idx = process.findIndex(pid) orelse return null;
    // Indeksi rajojen sisällä tälle prosessille.
    if (slot_idx >= slot_counts[proc_idx]) return null;
    // Palauta kopio slotista.
    return slots[proc_idx][@intCast(slot_idx)];
}

// Hae slotti nykyiseltä prosessilta.
pub fn lookupSlot(slot_idx: u32) ?CapRef {
    // Delegoi nykyisen prosessin lookupiin.
    return lookupSlotForPid(process.currentPid(), slot_idx);
}

// Hae capability-slotin objektityyppi — null jos slotti mitätöity.
pub fn getSlotType(slot_idx: u32) ?CapType {
    // Hae slotti indeksillä.
    const slot = lookupSlot(slot_idx) orelse return null;
    // Slotti ilman objektiviitettä on mitätöity.
    if (slot.object_id == 0) return null;
    // Hae taustalla oleva objekti.
    const obj = getObject(slot.object_id) orelse return null;
    // Palauta objektin tyyppi.
    return obj.typ;
}

// Hae capability-slotin resurssitunniste — null jos slotti mitätöity.
pub fn getSlotResource(slot_idx: u32) ?u64 {
    // Hae slotti indeksillä.
    const slot = lookupSlot(slot_idx) orelse return null;
    // Slotti ilman objektiviitettä on mitätöity.
    if (slot.object_id == 0) return null;
    // Hae taustalla oleva objekti.
    const obj = getObject(slot.object_id) orelse return null;
    // Palauta tyypin spesifinen resurssitunniste (port_id jne.).
    return obj.object_id;
}

// Tarkista onko slotilla pyydetty oikeus.
pub fn slotHasRights(slot_idx: u32, requested: Rights) bool {
    // Hae slotti.
    const slot = lookupSlot(slot_idx) orelse return false;
    // Pyydetyt bitit ⊆ slotin oikeudet.
    return rightsSubset(slot.rights, requested);
}

// Delegoi osa oikeuksista uuteen slottiin — grant-oikeus vaaditaan.
pub fn delegateSlot(slot_idx: u32, new_rights: Rights) ?u32 {
    // Hae lähdeslotti.
    const src = lookupSlot(slot_idx) orelse return null;
    // Delegointi vaatii grant-bitin lähde-slotissa.
    if (!src.rights.grant) return null;
    // Uudet oikeudet ⊆ alkuperäiset oikeudet.
    if (!rightsSubset(src.rights, new_rights)) return null;
    // Asenna uusi slotti samalle objektille pienemmillä oikeuksilla.
    const derived = installSlot(src.object_id, new_rights) orelse return null;
    // Hae objekti audit-merkintää varten.
    const obj = getObject(src.object_id) orelse return derived;
    // Audit: oikeuksia delegoitu.
    audit.record(.delegate, obj.owner_pid, src.object_id, derived, @bitCast(new_rights), @intFromEnum(obj.typ));
    // Palauta uuden slotin indeksi.
    return derived;
}

// Siirrä capability toiselle prosessille — grant-oikeus vaaditaan lähde-slotissa (Vaihe 22).
pub fn transferSlotToPid(src_slot: u32, dest_pid: u64, new_rights: Rights) ?u32 {
    // Hae lähdeslotti nykyiseltä prosessilta.
    const src = lookupSlot(src_slot) orelse return null;
    // Siirto vaatii grant-bitin lähde-slotissa.
    if (!src.rights.grant) return null;
    // Uudet oikeudet ⊆ alkuperäiset oikeudet.
    if (!rightsSubset(src.rights, new_rights)) return null;
    // Kohdeprosessi pitää olla rekisteröity taulukossa.
    if (process.findIndex(dest_pid) == null) return null;
    // Dedup: tarkista onko kohdeprosessilla jo slotti tähän objektiin (S2-bounded).
    const dest_proc_idx = process.findIndex(dest_pid) orelse return null;
    var si: usize = 0;
    while (si < slot_counts[dest_proc_idx]) : (si += 1) {
        if (slots[dest_proc_idx][si].object_id == src.object_id) {
            // Olemassa oleva slotti — palauta se dedupeeraamalla.
            return @intCast(si);
        }
    }
    // Asenna uusi slotti kohdeprosessin slottiin annetuilla oikeuksilla (ei duplicates).
    const derived = installSlotForPid(dest_pid, src.object_id, new_rights) orelse return null;
    // Hae objekti audit-merkintää varten.
    const obj = getObject(src.object_id) orelse return derived;
    // Audit: capability siirretty/delegoitu toiselle prosessille (delegate-op).
    audit.record(.delegate, dest_pid, src.object_id, derived, @bitCast(new_rights), @intFromEnum(obj.typ));
    // Palauta uuden slotin indeksi kohdeprosessissa.
    return derived;
}

// Peruuta capability-slotti — invalidoi taustalla oleva objekti ja kaikki viitteet.
pub fn revokeSlot(slot_idx: u32) bool {
    // Hae slotti indeksillä.
    const slot = lookupSlot(slot_idx) orelse return false;
    // Slotti ilman objektiviitettä on jo mitätöity.
    if (slot.object_id == 0) return false;
    // Peruuta objekti — nollaa kaikki siihen viittaavat slotit.
    return revokeObject(slot.object_id);
}

// Peruuta objekti — invalidoi kaikki siihen viittaavat slotit.
pub fn revokeObject(object_id: u32) bool {
    // Hae objekti.
    const obj = getObject(object_id) orelse return false;
    // Tallenna tyyppi ja resurssitunniste ennen nollausta.
    const typ = obj.typ;
    const owner = obj.owner_pid;
    const resource_id = obj.object_id;
    // Merkitse objekti vapaaksi.
    obj.used = false;
    // Nollaa tyyppi.
    obj.typ = .null;
    // Poista omistaja.
    obj.owner_pid = 0;
    // Nollaa resurssitunniste.
    obj.object_id = 0;
    // Vapauta IPC-portti jos objekti oli portti-tyyppiä.
    if (typ == .port) {
        // Tuhoa portin jono — vapauttaa port_id uudelleenkäyttöön.
        _ = port_core.destroyPort(@intCast(resource_id));
    }
    // Poista slot-viitteet tähän objektiin kaikista prosesseista.
    var pi: usize = 0;
    while (pi < process.MAX_PROCESSES) : (pi += 1) {
        // Ohita prosessit ilman slotteja.
        if (slot_counts[pi] == 0) continue;
        // Käy prosessin slotit.
        var si: usize = 0;
        while (si < slot_counts[pi]) : (si += 1) {
            // Jos slotti viittaa peruttavaan objektiin.
            if (slots[pi][si].object_id == object_id) {
                // Nollaa slotti (ei tiivistetä listaa boot-stubissa).
                slots[pi][si].object_id = 0;
                // Poista oikeudet.
                slots[pi][si].rights = .{};
            }
        }
    }
    // Audit: objekti peruutettu.
    audit.record(.revoke, owner, object_id, audit.NO_SLOT, @bitCast(Rights{}), @intFromEnum(typ));
    // Onnistui.
    return true;
}

// Peruuta kaikki annetun prosessin omistamat objektit — plugin-unload (Vaihe 30).
// Palauttaa peruttujen objektien määrän. Jokainen revokeObject nollaa myös
// kaikki viittaavat slotit kaikissa prosesseissa (portti vapautuu samalla).
pub fn revokeAllOwnedBy(pid: u64) u32 {
    // Vaadi alustus.
    if (!initialized) return 0;
    // Peruttujen laskuri.
    var count: u32 = 0;
    // Käy objektitaulukko — kerää ensin id:t (revoke muokkaa taulukkoa).
    var i: usize = 0;
    while (i < objects.len) : (i += 1) {
        // Vain käytössä olevat, tämän pidin omistamat.
        if (!objects[i].used) continue;
        // Omistaja ei täsmää.
        if (objects[i].owner_pid != pid) continue;
        // Objektin id = indeksi + 1.
        const id: u32 = @intCast(i + 1);
        // Peruuta objekti + kaikki viitteet.
        if (revokeObject(id)) count += 1;
    }
    // Palauta peruttujen määrä.
    return count;
}

// Tyhjennä yhden prosessin capability-slotit — plugin-unload (Vaihe 30).
// Poistaa myös muiden omistamiin objekteihin jääneet viitteet (esim. siirretyt
// cap-viitteet), jotta vapautetun pidin slotteja ei voi käyttää uudelleen.
pub fn clearSlotsForPid(pid: u64) bool {
    // Vaadi alustus.
    if (!initialized) return false;
    // Hae prosessin taulukkoindeksi.
    const proc_idx = process.findIndex(pid) orelse return false;
    // Nollaa jokainen slotti.
    var si: usize = 0;
    while (si < MAX_SLOTS) : (si += 1) {
        // Ei objektiviitettä.
        slots[proc_idx][si].object_id = 0;
        // Ei oikeuksia.
        slots[proc_idx][si].rights = .{};
    }
    // Nollaa slottilaskuri — uudet asennukset alkavat indeksistä 0.
    slot_counts[proc_idx] = 0;
    // Onnistui.
    return true;
}

// Luo objekti ja asenna se slottiin yhdellä kutsulla.
pub fn createAndInstall(
    typ: CapType,
    owner_pid: u64,
    resource_id: u64,
    rights: Rights,
) ?u32 {
    // Luo kernel-objekti.
    const obj_id = createObject(typ, owner_pid, resource_id) orelse return null;
    // Asenna slottiin omistajaprosessille — palauta slot-indeksi.
    return installSlotForPid(owner_pid, obj_id, rights);
}

// Rekisteröi prosessi taulukkoon — host-testit (sama process_core-instanssi).
pub fn registerProcess(pid: u64) bool {
    // Delegoi prosessitaulukon allokaatioon.
    return process.allocProcess(pid);
}

// Aseta nykyinen prosessi — host-testit cross-process siirtoon.
pub fn setCurrentProcess(pid: u64) bool {
    // Delegoi prosessitaulukon current pid:lle.
    return process.setCurrentPid(pid);
}
