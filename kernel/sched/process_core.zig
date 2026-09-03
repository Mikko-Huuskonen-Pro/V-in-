//! Prosessitaulukon ydin — pid-allokaatio ja current pid (host-testattava).
//!
//! **Vastuu**: Rekisteröi prosessit, pid → indeksi, nykyinen prosessi syscall-kontekstissa.
//! **Riippuvuudet**: ei
//! **Käytetään**: `process.zig`, `capability_core.zig`, `spawn.zig`, host-testit

// Boot/init-prosessin oletus-pid (stub userland ennen spawnia).
pub const BOOT_PID: u64 = 1;
// Maksimi prosessien määrä kernelin taulukossa.
pub const MAX_PROCESSES: usize = 16;
// Ei vanhempaa — boot-prosessin parent_pid (Vaihe 24 wait).
pub const NO_PARENT: u64 = 0;

// Prosessin elinkaaren tila (Vaihe 24 exit/wait).
pub const ProcessState = enum {
    // Prosessi elossa — ei vielä sys_exit.
    running,
    // Prosessi lopettanut — odottaa sys_wait (zombie).
    zombie,
};

// Yksittäinen prosessi prosessitaulukossa.
pub const Process = struct {
    // Onko taulukkopaikka käytössä.
    used: bool,
    // Prosessitunniste (uniikki taulukossa).
    pid: u64,
    // Onko ELF ladattu ja entry/pino valmiina (Vaihe 21 spawn).
    loaded: bool,
    // Ring 3 entry-piste ladatusta ELF:stä.
    entry: u64,
    // Käyttäjäpinon yläreuna iretq:ä varten.
    stack_top: u64,
    // Heap-slot josta pino kartoitettiin.
    stack_slot: u64,
    // Elinkaaren tila — running tai zombie (Vaihe 24).
    state: ProcessState,
    // Vanhemman prosessitunniste — spawn asettaa currentPid (Vaihe 24).
    parent_pid: u64,
    // sys_exit status-koodi zombie-tilassa (Vaihe 24).
    exit_code: u32,
    // Per-process sivutaulun fyysinen PML4-osoite — Vaihe 25 (0 = ei erillistä).
    page_table: u64,
};
// Ladatun prosessin suoritustiedot — runProcess/spawn.
pub const LoadedProcess = struct {
    // ELF e_entry.
    entry: u64,
    // Pinon yläreuna.
    stack_top: u64,
    // Pinon heap-slot (debug/erottelu).
    stack_slot: u64,
};

// Kiinteä prosessitaulukko — indeksi = capability-slottien ryhmä.
var processes: [MAX_PROCESSES]Process = undefined;
// Montako prosessia on rekisteröity.
var used_count: usize = 0;
// Nykyinen prosessi syscall- ja capability-kontekstissa.
var current_pid: u64 = BOOT_PID;
// Onko ydin alustettu.
var initialized: bool = false;

// Nollaa prosessitaulukko — boot ja host-testit.
pub fn initCore() void {
    // Tyhjennä jokainen prosessipaikka.
    for (&processes) |*p| {
        // Merkitse vapaa.
        p.used = false;
        // Nollaa pid.
        p.pid = 0;
        // Ei ladattua ELF:ää.
        p.loaded = false;
        // Nollaa entry.
        p.entry = 0;
        // Nollaa pinon huippu.
        p.stack_top = 0;
        // Nollaa pinon slot.
        p.stack_slot = 0;
        // Prosessi elossa.
        p.state = .running;
        // Ei vanhempaa oletuksena.
        p.parent_pid = NO_PARENT;
        // Ei exit-koodia ennen sys_exit.
        p.exit_code = 0;
        // Ei erillistä sivutaulua nollauksen aikana.
        p.page_table = 0;
    }
    // Ei rekisteröityjä prosesseja.
    used_count = 0;
    // Nykyinen prosessi boot-pid ennen ensimmäistä allocia.
    current_pid = BOOT_PID;
    // Rekisteröi boot-prosessi (pid 1).
    _ = allocProcess(BOOT_PID);
    // Merkitse alustetuksi.
    initialized = true;
}

// Hae prosessin taulukkoindeksi pid:llä.
pub fn findIndex(pid: u64) ?usize {
    // Vaadi alustus.
    if (!initialized) return null;
    // Käy rekisteröidyt prosessit.
    var i: usize = 0;
    while (i < used_count) : (i += 1) {
        // Täsmäävä pid → indeksi.
        if (processes[i].used and processes[i].pid == pid) return i;
    }
    // Prosessia ei löydy.
    return null;
}

// Rekisteröi uusi prosessi taulukkoon — palauttaa false jos täynnä.
pub fn allocProcess(pid: u64) bool {
    // Vaadi alustus (initCore rekursiota varten asettaa initialized viimeisenä).
    if (!initialized and pid != BOOT_PID) return false;
    // Jos initCore kutsuu allocProcess ennen initialized=true, salli vain boot.
    if (!initialized and pid == BOOT_PID and used_count == 0) {
        // Ensimmäinen prosessi initCore:n aikana.
        processes[0] = .{
            .used = true,
            .pid = BOOT_PID,
            .loaded = false,
            .entry = 0,
            .stack_top = 0,
            .stack_slot = 0,
            .state = .running,
            .parent_pid = NO_PARENT,
            .exit_code = 0,
            .page_table = 0,
        };
        // Yksi prosessi rekisteröity.
        used_count = 1;
        // Onnistui.
        return true;
    }
    // Vaadi alustus muiden pid:ien kohdalla.
    if (!initialized) return false;
    // Jo rekisteröity → OK.
    if (findIndex(pid) != null) return true;
    // Taulukko täynnä.
    if (used_count >= MAX_PROCESSES) return false;
    // Lisää uusi prosessi.
    processes[used_count] = .{
        .used = true,
        .pid = pid,
        .loaded = false,
        .entry = 0,
        .stack_top = 0,
        .stack_slot = 0,
        .state = .running,
        .parent_pid = NO_PARENT,
        .exit_code = 0,
        .page_table = 0,
    };
    // Kasvata lukumäärää.
    used_count += 1;
    // Onnistui.
    return true;
}

// Allokoi seuraava vapaa pid (aloita 2:sta) — Vaihe 21 spawn.
pub fn allocNextPid() ?u64 {
    // Vaadi alustus.
    if (!initialized) return null;
    // Etsi ensimmäinen vapaa pid.
    var pid: u64 = 2;
    // Rajaa haku järkevään alueeseen.
    while (pid < 0x10000) : (pid += 1) {
        // Jos pid ei ole taulukossa, rekisteröi ja palauta.
        if (findIndex(pid) == null) {
            // Rekisteröi uusi prosessi.
            if (!allocProcess(pid)) return null;
            // Palauta uusi tunniste.
            return pid;
        }
    }
    // Kaikki numerot käytössä.
    return null;
}

// Tallenna ladatun prosessin suoritustiedot taulukkoon.
pub fn setLoaded(pid: u64, entry: u64, stack_top: u64, stack_slot: u64) bool {
    // Hae prosessin indeksi.
    const idx = findIndex(pid) orelse return false;
    // Merkitse ELF ladatuksi.
    processes[idx].loaded = true;
    // Tallenna entry.
    processes[idx].entry = entry;
    // Tallenna pinon huippu.
    processes[idx].stack_top = stack_top;
    // Tallenna pinon slot.
    processes[idx].stack_slot = stack_slot;
    // Onnistui.
    return true;
}

// Hae ladatun prosessin suoritustiedot — null jos ei ladattu.
pub fn getLoadedInfo(pid: u64) ?LoadedProcess {
    // Hae prosessin indeksi.
    const idx = findIndex(pid) orelse return null;
    // Vaadi ladattu ELF.
    if (!processes[idx].loaded) return null;
    // Palauta kopio suoritustiedoista.
    return .{
        .entry = processes[idx].entry,
        .stack_top = processes[idx].stack_top,
        .stack_slot = processes[idx].stack_slot,
    };
}

// Palauta nykyinen prosessitunniste.
pub fn currentPid() u64 {
    // Palauta syscall-kontekstin pid.
    return current_pid;
}

// Aseta nykyinen prosessi — false jos pid ei ole taulukossa.
pub fn setCurrentPid(pid: u64) bool {
    // Vaadi että prosessi on rekisteröity.
    if (findIndex(pid) == null) return false;
    // Päivitä nykyinen konteksti.
    current_pid = pid;
    // Onnistui.
    return true;
}

// Montako prosessia on rekisteröity.
pub fn processCount() usize {
    // Palauta rekisteröityjen prosessien määrä.
    return used_count;
}

// Palauta rekisteröidyn prosessin pid taulukko-indeksillä (0..processCount-1).
pub fn pidAt(index: usize) ?u64 {
    // Vaadi alustus.
    if (!initialized) return null;
    // Indeksi taulukon ulkopuolella.
    if (index >= used_count) return null;
    // Paikka ei käytössä.
    if (!processes[index].used) return null;
    // Palauta prosessitunniste.
    return processes[index].pid;
}

// Onko prosessilla ladattu ELF (spawnattu user-prosessi).
pub fn isLoaded(pid: u64) bool {
    // Hae prosessin indeksi.
    const idx = findIndex(pid) orelse return false;
    // Palauta loaded-lippu.
    return processes[idx].loaded;
}

// Onko prosessi rekisteröity taulukossa.
pub fn exists(pid: u64) bool {
    // findIndex löytyy → prosessi on olemassa.
    return findIndex(pid) != null;
}

// Hae prosessin elinkaaren tila.
pub fn getState(pid: u64) ?ProcessState {
    // Hae prosessin indeksi.
    const idx = findIndex(pid) orelse return null;
    // Palauta tila.
    return processes[idx].state;
}

// Onko prosessi zombie-tilassa.
pub fn isZombie(pid: u64) bool {
    // Hae tila — false jos prosessia ei ole.
    return getState(pid) == .zombie;
}

// Hae vanhemman prosessitunniste.
pub fn parentPid(pid: u64) ?u64 {
    // Hae prosessin indeksi.
    const idx = findIndex(pid) orelse return null;
    // Palauta parent_pid-kenttä.
    return processes[idx].parent_pid;
}

// Aseta vanhemman prosessitunniste (spawn asettaa currentPid).
pub fn setParentPid(pid: u64, parent: u64) bool {
    // Hae prosessin indeksi.
    const idx = findIndex(pid) orelse return false;
    // Tallenna vanhempi.
    processes[idx].parent_pid = parent;
    // Onnistui.
    return true;
}

// Aseta prosessin per-process PML4-osoite (vaihe 25).
pub fn setPageTable(pid: u64, phys: u64) bool {
    // Hae prosessin indeksi.
    const idx = findIndex(pid) orelse return false;
    // Tallenna sivutaulun fyysinen osoite.
    processes[idx].page_table = phys;
    // Onnistui.
    return true;
}

// Hae zombie-prosessin exit-koodi.
pub fn exitCode(pid: u64) ?u32 {
    // Hae prosessin indeksi.
    const idx = findIndex(pid) orelse return null;
    // Vain zombie palauttaa exit-koodin.
    if (processes[idx].state != .zombie) return null;
    // Palauta sys_exit status.
    return processes[idx].exit_code;
}

// Merkitse prosessi zombieksi sys_exit:llä — palauttaa false jos jo zombie tai puuttuu.
pub fn markZombie(pid: u64, code: u32) bool {
    // Hae prosessin indeksi.
    const idx = findIndex(pid) orelse return false;
    // Ei tuplazombiea.
    if (processes[idx].state == .zombie) return false;
    // Tallenna exit-koodi.
    processes[idx].exit_code = code;
    // Merkitse zombie — odottaa sys_wait.
    processes[idx].state = .zombie;
    // Onnistui.
    return true;
}

// Poista zombie prosessitaulukosta wait:in jälkeen — vapauttaa paikan (stub: pid säilyy).
pub fn reapZombie(pid: u64) bool {
    // Hae prosessin indeksi.
    const idx = findIndex(pid) orelse return false;
    // Vain zombie voidaan reapata.
    if (processes[idx].state != .zombie) return false;
    // Merkitse ei ladattu — prosessi poistettu elinkaaresta.
    processes[idx].loaded = false;
    // Säilytä zombie-tila ja exit_code wait-vastauksen jälkeen (ei poisteta taulukosta vielä).
    // Tuleva scheduler voi vapauttaa taulukkopaikan kokonaan.
    return true;
}

// Vapauta pid — merkitsee prosessipaikan vapaaksi (vaihe 25 virhekäsittely).
pub fn freePid(pid: u64) bool {
    // Etsi indeksi.
    const idx = findIndex(pid) orelse return false;
    // Merkitse vapaa.
    processes[idx].used = false;
    processes[idx].pid = 0;
    processes[idx].loaded = false;
    processes[idx].entry = 0;
    processes[idx].stack_top = 0;
    processes[idx].stack_slot = 0;
    processes[idx].state = .running;
    processes[idx].parent_pid = NO_PARENT;
    processes[idx].exit_code = 0;
    processes[idx].page_table = 0;
    // Alenna lukumäärää.
    if (used_count > 0) used_count -= 1;
    return true;
}
