//! Plugin error diagnostics — terveysindikaattorit per plugin (Vaihe 33.1).
//!
//! **Vastuu**: Kerää jokaisen ladatun pluginin terveyssignaalit kiinteään
//!   taulukkoon: virhelaskuri, viimeinen virhekoodi, vikaluokka ja IPC-viive.
//!   Vastaa kysymykseen "onko plugin healthy / degraded / crashed".
//! **Riippuvuudet**: ei (puhdas logiikka — ei pmm/log/process-importtia).
//!   Muistipaineen lukema (`pmm.availableFrames()`) annetaan parametrina
//!   (`recordMemoryPressure`), jotta tämä on host-testattava kuten scope.zig.
//!   Sama syy kuin scope.zig:ssä: ei kiertoa, ei freestanding-ajureita testeissä.
//! **Käytetään**: `plugin_swap.zig` (heal-päätös), `syscall/plugin_heal_syscall.zig`
//!   (boot-testi), host-testit (`tests/host/plugin_heal_test.zig`).
//!
//! ## Arkkitehtuurihuomiot (AGENTS.md)
//! - Diagnoosi on havainto, ei lupa: tämä moduli ei myönnä capabilityja eikä
//!   koske sivutauluihin. Kernel päättää swapista erikseen (`plugin_swap.zig`).
//! - Kolmitila: healthy (ei vikoja) → degraded (vikoja alle rajan) → crashed
//!   (virheraja täynnä). Rajoja ei kasvateta rajattomasti — laskuri saturates.
//! - Vikaluokan päättely virhekoodista on parhaiten arvaava karkea heuristiikka,
//!   ei tarkka taksonomia. Tarkka syy (page fault vs IPC-timeout) tulee
//!   vaiheen 31.5 watchdogilta; tämä riittää hot-swapin laukaisuun.
//! - Kiinteä taulukko (ei allokaatiota): freestanding-kelpoinen, rajattu
//!   DIAG_MAX_ENTRIES:iin. Täysi taulukko → register palauttaa false
//!   (fail-closed, kuten plugin-rekisteri vaiheessa 30).

// Maksimi diagnoosirivien määrä taulukossa.
pub const DIAG_MAX_ENTRIES: usize = 16;

// Virheraja ennen "crashed" — plugin kaatuu 3. peräkkäisestä viasta.
pub const DIAG_MAX_ERRORS: u16 = 3;

// Muistipainekynnys kehyksinä — vapaa pudotus tästä baselinesta → pressure.
pub const DIAG_MEMORY_LOW: u32 = 4;

// Pluginin terveystila kolmessa tasossa.
pub const HealthStatus = enum(u2) {
    // Ei tunnettuja ongelmia.
    healthy = 0,
    // Vaurioitunut — virheitä mutta alle rajan.
    degraded = 1,
    // Kaatunut — virheraja täynnä (tai tuntematon pid).
    crashed = 2,
};

// Havaitun vian karkea luokka.
pub const FaultType = enum(u4) {
    // Ei vikaa (oletus).
    none = 0,
    // Kova kaatuminen / panic.
    crashed_fault = 1,
    // IPC-ylikuormitus / timeout.
    ipc_overload = 2,
    // Muistipaine (kehykset vähissä).
    memory_pressure = 3,
};

// Yksi pluginin diagnoosirivi.
pub const PluginDiag = struct {
    // Onko rivi käytössä.
    active: bool,
    // Plugin-prosessin pid.
    pid: u64,
    // Kertyneiden virheiden määrä (saturates DIAG_MAX_ERRORS:iin).
    error_count: u16,
    // Viimeisin kirjattu virhekoodi.
    last_error_code: i32,
    // Vakavin havaittu vikaluokka.
    fault_type: FaultType,
    // Suurin havaittu IPC-viive tickeissä.
    ipc_latency_ticks: u32,
};

// Kiinteä diagnoositaulukko — ei heap-allokaatiota.
var diagnostics: [DIAG_MAX_ENTRIES]PluginDiag = undefined;
// Montako riviä taulukon alusta on skannattava (tiivistetty ylhäältä).
var diag_count: usize = 0;
// Onko taulukko nollattu.
var initialized: bool = false;

// Päättele vikaluokka virhekoodista (karkea heuristiikka).
pub fn errorToFault(code: i32) FaultType {
    // Hyvin negatiivinen → kova kaatuminen.
    if (code <= -50) return .crashed_fault;
    // IPC/timeout-alue → ylikuormitus.
    if (code >= -40 and code <= -30) return .ipc_overload;
    // Muut → muistipaine-oletus (tarkennetaan recordMemoryPressure:lla).
    return .memory_pressure;
}

// Nollaa diagnoositaulukko — kutsutaan bootissa ja testeissä.
pub fn initCore() void {
    // Käy jokainen paikka.
    for (&diagnostics) |*entry| {
        // Merkitse vapaaksi.
        entry.active = false;
        // Nollaa pid.
        entry.pid = 0;
        // Nollaa laskuri.
        entry.error_count = 0;
        // Nollaa koodi.
        entry.last_error_code = 0;
        // Ei vikaa.
        entry.fault_type = .none;
        // Ei viivettä.
        entry.ipc_latency_ticks = 0;
    }
    // Ei skannattavia rivejä.
    diag_count = 0;
    // Merkitse alustetuksi.
    initialized = true;
}

// Onko ydin alustettu (testien suojatarkistus).
pub fn isInitialized() bool {
    return initialized;
}

// Etsi diagnoosirivi pid:llä — osoitin tai null.
pub fn getDiagnostic(pid: u64) ?*PluginDiag {
    // Ei alustettu → ei rivejä.
    if (!initialized) return null;
    // Skannaa tiivistetty alue.
    var i: usize = 0;
    while (i < diag_count) : (i += 1) {
        // Täsmäävä käytössä oleva rivi.
        if (diagnostics[i].active and diagnostics[i].pid == pid) return &diagnostics[i];
    }
    // Ei riviä tälle pidille.
    return null;
}

// Etsi rivin indeksi pid:llä (yksityinen apuri).
fn findIndexByPid(pid: u64) ?usize {
    // Ei alustettu → ei rivejä.
    if (!initialized) return null;
    // Skannaa tiivistetty alue.
    var i: usize = 0;
    while (i < diag_count) : (i += 1) {
        // Täsmäävä käytössä oleva rivi.
        if (diagnostics[i].active and diagnostics[i].pid == pid) return i;
    }
    // Ei osumaa.
    return null;
}

// Rekisteröi uusi diagnoosirivi pluginille — false jos taulukko täynnä.
pub fn registerDiagnostic(pid: u64) bool {
    // Vaadi alustus ensin.
    if (!initialized) return false;
    // Pid 0 ei kelpaa (NO_PARENT / ei-prosessi).
    if (pid == 0) return false;
    // Jo rekisteröity → OK (idempotentti).
    if (getDiagnostic(pid) != null) return true;
    // Etsi vapaa paikka koko taulukosta.
    var i: usize = 0;
    while (i < diagnostics.len) : (i += 1) {
        // Vapaa paikka löytyi.
        if (!diagnostics[i].active) {
            // Merkitse käytetyksi.
            diagnostics[i].active = true;
            // Tallenna pid.
            diagnostics[i].pid = pid;
            // Nollaa laskuri.
            diagnostics[i].error_count = 0;
            // Nollaa koodi.
            diagnostics[i].last_error_code = 0;
            // Ei vikaa.
            diagnostics[i].fault_type = .none;
            // Ei viivettä.
            diagnostics[i].ipc_latency_ticks = 0;
            // Laajenna skannausaluetta tarvittaessa.
            if (i >= diag_count) diag_count = i + 1;
            // Onnistui.
            return true;
        }
    }
    // Taulukko täynnä — fail-closed.
    return false;
}

// Poista pluginin rivi — tiivistää skannausalueen ylhäältä.
pub fn deregisterDiagnostic(pid: u64) bool {
    // Etsi rivi.
    const idx = findIndexByPid(pid) orelse return false;
    // Nollaa rivi paikallaan.
    diagnostics[idx].active = false;
    diagnostics[idx].pid = 0;
    diagnostics[idx].error_count = 0;
    diagnostics[idx].last_error_code = 0;
    diagnostics[idx].fault_type = .none;
    diagnostics[idx].ipc_latency_ticks = 0;
    // Tiivistä: pudota tyhjiä rivejä skannausalueen lopusta.
    while (diag_count > 0 and !diagnostics[diag_count - 1].active) {
        diag_count -= 1;
    }
    // Onnistui.
    return true;
}

// Kirjaa virhe pluginille — kasvattaa laskurin (saturating) ja pahentaa luokkaa.
pub fn recordFault(pid: u64, code: i32) void {
    // Hae rivi — tuntematon pid sivuutetaan (ei luoda varjolla).
    const entry = getDiagnostic(pid) orelse return;
    // Tallenna koodi.
    entry.last_error_code = code;
    // Kasvata vain rajalle asti (crashed pysyy crashedina).
    if (entry.error_count < DIAG_MAX_ERRORS) {
        entry.error_count += 1;
    }
    // Pahenna luokkaa vain ylöspäin (ei laimenna kovaa vikaa).
    recordFaultTyped(pid, code, errorToFault(code));
}

// Kirjaa virhe eksplisiittisellä luokalla (watchdogin tarkka syy).
pub fn recordFaultTyped(pid: u64, code: i32, typ: FaultType) void {
    // Hae rivi.
    const entry = getDiagnostic(pid) orelse return;
    // Tallenna koodi.
    entry.last_error_code = code;
    // Kasvata vain rajalle asti.
    if (entry.error_count < DIAG_MAX_ERRORS) {
        // Vältä tuplalaskenta recordFault:in kanssa: kasvata vain jos
        // koodi vaihtui (sama vika ei täytä rajaa yhdellä purskeella).
        // Yksinkertaisuus ennen älyä: aina +1, katto pitää rajan.
        entry.error_count += 1;
    }
    // Päivitä luokka vakavampaan (enum-arvojärjestys = vakavuus).
    if (@intFromEnum(typ) > @intFromEnum(entry.fault_type)) {
        entry.fault_type = typ;
    }
}

// Kirjaa IPC-viive — tallentaa maksimin (piikkien havaitsemiseen).
pub fn recordIpcLatency(pid: u64, ticks: u32) void {
    // Hae rivi.
    const entry = getDiagnostic(pid) orelse return;
    // Päivitä maksimi.
    if (ticks > entry.ipc_latency_ticks) entry.ipc_latency_ticks = ticks;
}

// Merkitse muistipaine — ei alenna olemassa olevaa kovempaa vikaa.
pub fn noteMemoryPressure(pid: u64) void {
    // Hae rivi.
    const entry = getDiagnostic(pid) orelse return;
    // Aseta vain jos ei vielä kovempaa luokkaa.
    if (entry.fault_type == .none or entry.fault_type == .ipc_overload) {
        entry.fault_type = .memory_pressure;
    }
}

// Vertaa vapaita kehyksiä baselineen — puhdas painepäätös ilman pmm-importtia.
//
// Kutsuja (kernel/watchdog) lukee `pmm.availableFrames()` ja antaa luvut tänne.
// Palauttaa true jos paine havaittiin (ja merkitsee rivin).
pub fn recordMemoryPressure(pid: u64, free_now: u32, free_baseline: u32) bool {
    // Hae rivi.
    const entry = getDiagnostic(pid) orelse return false;
    // Baseline alle kynnyksen → vertailu mahdoton, ohita.
    if (free_baseline < DIAG_MEMORY_LOW) return false;
    // Pudotus vähintään kynnyksen verran → paine.
    if (free_now + DIAG_MEMORY_LOW <= free_baseline) {
        noteMemoryPressure(pid);
        _ = entry;
        return true;
    }
    // Ei painetta.
    return false;
}

// Arvioi pluginin terveys — tuntematon pid → crashed (fail-closed).
pub fn getHealth(pid: u64) HealthStatus {
    // Hae rivi.
    const entry = getDiagnostic(pid) orelse return .crashed;
    // Raja täynnä → kaatunut.
    if (entry.error_count >= DIAG_MAX_ERRORS) return .crashed;
    // Vikaluokka päällä → vaurioitunut.
    if (entry.fault_type != .none) return .degraded;
    // Ei vikoja.
    return .healthy;
}

// Ovatko kaikki rekisteröidyt pluginit terveitä (nopea "kaikki OK" -skannaus).
pub fn isAllHealthy() bool {
    // Ei alustettu → ei ongelmia.
    if (!initialized) return true;
    // Käy skannausalue.
    var i: usize = 0;
    while (i < diag_count) : (i += 1) {
        // Vain käytössä olevat rivit.
        if (diagnostics[i].active) {
            // Yksikin ei-terve → false.
            if (getHealth(diagnostics[i].pid) != .healthy) return false;
        }
    }
    // Kaikki terveitä.
    return true;
}

// Alias vanhalle nimelle (yhteensopivuus).
pub fn allHealthy() bool {
    return isAllHealthy();
}

// Montako aktiivista riviä (testien apuri).
pub fn countActive() usize {
    // Ei alustettu → nolla.
    if (!initialized) return 0;
    // Laskuri.
    var n: usize = 0;
    // Käy skannausalue.
    var i: usize = 0;
    while (i < diag_count) : (i += 1) {
        if (diagnostics[i].active) n += 1;
    }
    return n;
}

// Nollaa rivin laskurit swapin jälkeen — plugin aloittaa puhtaalta pöydältä.
pub fn resetDiagnostic(pid: u64) void {
    // Hae rivi.
    const entry = getDiagnostic(pid) orelse return;
    // Nollaa laskuri.
    entry.error_count = 0;
    // Nollaa koodi.
    entry.last_error_code = 0;
    // Ei vikaa.
    entry.fault_type = .none;
    // Ei viivettä.
    entry.ipc_latency_ticks = 0;
}

// Alias vanhalle nimelle (yhteensopivuus).
pub fn resetDiag(pid: u64) void {
    resetDiagnostic(pid);
}
