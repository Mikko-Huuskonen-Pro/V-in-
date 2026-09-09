//! Task-decomposer — LIFO-purku + timeout-päätös (Vaihe 34.4, puhdas ydin).
//!
//! **Vastuu**: Päätä *missä järjestyksessä* sävelletty ympäristö puretaan
//!   (tiukasti LIFO, häntä ensin) ja *milloin* (tehtävä valmis / timeout /
//!   vika). Ei koske plugineihin, sivutauluihin eikä rekisteriin —
//!   varsinainen `unloadPlugin`-silmukka elää `composer.zig`:ssä.
//! **Riippuvuudet**: ei (puhdas logiikka — host-testattava kuten scope.zig).
//!   Sama syy kuin scopessa: ei kiertoa freestanding-ajureihin testeissä.
//! **Käytetään**: `kernel/composer.zig` (purkusilmukka), host-testit.
//!
//! ## Arkkitehtuurihuomiot (AGENTS.md)
//! - Politiikka vs. mekanismi: tämä tiedosto on politiikka (järjestys +
//!   erääntyminen); mekanismi (revoke/slot/PML4/pid) on loaderissa.
//! - LIFO-pakko: prosessitaulukko on append-only ilman tiivistystä
//!   (Vaihe 20/24) — häntä ensin ei tee aukkoja (sama kuri kuin
//!   Vaihe 30/33 unload-järjestyksessä).
//! - Timeout on kernelin raja, ei vihje: `now >= deadline` purkaa vaikka
//!   tehtävä väittäisi olevansa kesken (ei ikuisia tehtäviä).
//! - Tyhjä koostumus on triviaalisti purettu (0 pluginia → ei työtä).

// Koostumuksen plugin-katto (loader.MAX_PLUGINS-pariteetti).
pub const MAX_COMPOSITION_PLUGINS: usize = 8;

// Koostumuksen nimen maksimipituus (TDL-pariteetti).
pub const MAX_TASK_NAME: usize = 32;

// Yksi aktiivinen koostumus — kernelissä kerrallaan yksi (mitattava raja;
// rinnakkaiset koostumukset rajattu pois vaiheesta 34 dokumentoidusti).
pub const Composition = struct {
    // Onko koostumus aktiivinen.
    active: bool,
    // Tehtävän nimi (TDL).
    name_buf: [MAX_TASK_NAME]u8,
    // Nimen pituus.
    name_len: usize,
    // Ladatut plugin-pidit latausjärjestyksessä (hakemisto 0 = vanhin).
    pids: [MAX_COMPOSITION_PLUGINS]u64,
    // Montako pidiä käytössä.
    count: usize,
    // Koostumuksen alku tickeissä (kutsujan kello).
    started_ticks: u64,
    // Erääntymisraja tickeissä (start + timeout).
    deadline_ticks: u64,
    // Epäonnistuiko ajo (silti puretaan — siivous on ehdoton).
    failed: bool,
};

// Rakenna passiivinen koostumus nimellä + aikarajalla (ei lataa mitään).
pub fn initComposition(name: []const u8, now_ticks: u64, timeout_ticks: u32) Composition {
    // Tyhjä runko.
    var comp: Composition = .{
        .active = false,
        .name_buf = undefined,
        .name_len = 0,
        .pids = undefined,
        .count = 0,
        .started_ticks = now_ticks,
        .deadline_ticks = now_ticks + timeout_ticks,
        .failed = false,
    };
    // Kopioi nimi katkaistuna (kutsuja validoi pituuden TDL-tasolla).
    var i: usize = 0;
    while (i < name.len and i < MAX_TASK_NAME) : (i += 1) {
        comp.name_buf[i] = name[i];
    }
    comp.name_len = i;
    // Nollaa loput deterministisyyteen.
    while (i < MAX_TASK_NAME) : (i += 1) comp.name_buf[i] = 0;
    return comp;
}

// Onko koostumus erääntynyt tick-kellossa (now >= deadline → pura).
pub fn isExpired(now_ticks: u64, deadline_ticks: u64) bool {
    return now_ticks >= deadline_ticks;
}

// Pitääkö purkaa: valmis TAI erääntynyt TAI epäonnistunut.
pub fn shouldDecompose(task_complete: bool, expired: bool, failed: bool) bool {
    if (task_complete) return true;
    if (expired) return true;
    if (failed) return true;
    return false;
}

// LIFO-indeksi: askel 0 → uusin (count-1), askel count-1 → vanhin (0).
pub fn lifoAt(count: usize, step: usize) usize {
    // Tyhjä koostumus — ei indeksiä (kutsuja ei saa kutsua).
    if (count == 0) return 0;
    // Askel yli määrän — kyllästä vanhimpaan (fail-closed, ei kierrosta).
    if (step >= count) return 0;
    return count - 1 - step;
}

// Täytä purkujärjestysvektori LIFO:ssa — palauttaa täytettyjen määrän.
pub fn lifoOrder(count: usize, out: []usize) usize {
    // Leikkaa puskurin kokoon (kutsuja antaa tilaa count:lle).
    const n = if (count < out.len) count else out.len;
    // Askel i → indeksi count-1-i.
    var step: usize = 0;
    while (step < n) : (step += 1) {
        out[step] = lifoAt(count, step);
    }
    return n;
}

// Onko koostumus tyhjä/purettu (ei aktiivisia plugineja).
pub fn isEmpty(count: usize) bool {
    return count == 0;
}
