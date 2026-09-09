//! Task-composer — TDL → minimaali plugin-ympäristö → ajo → purku (Vaihe 34.3).
//!
//! **Vastuu**: Ota vastaan validoitu `TaskSpec`, ratkaise se plugin-
//!   vaatimuksiksi userland-heuristiikalla, päätä jokainen vaatimus
//!   manifesti+scope-portin läpi (sama portti kuin `sys_plugin_load`),
//!   lataa plugin-ELF:t, aja ne ja pura LIFO:ssa (`decomposer`-politiikalla).
//! **Riippuvuudet**: `composer_task`/`composer_resolve` (build-moduulit,
//!   sama kaava kuin `plugin_manifest`), `decomposer.zig` (puhdas purku-
//!   politiikka), `plugin/loader.zig`, `plugin/scope.zig`,
//!   `plugin/manifest.zig`, `process_core`, log.
//! **Käytetään**: `kernel/boot_tests.zig::runAll()` (boot-testi).
//!
//! ## Arkkitehtuurihuomiot (AGENTS.md: AI proposes, kernel decides)
//! - Composerin ehdotus on pyyntö: jokainen `PluginReq` kulkee
//!   `buildSingleCapManifest → checkManifest → initScope/validate →
//!   checkScope`-portin läpi ENNEN latausta. Väärä ehdotus → koko
//!   koostumus kieltäytyy (fail-closed), ei koskaan eskalaatio.
//! - Scope-pid sidotaan ladattuun pidiin (Vaiheen 23 S1-oppi: ei asennusta
//!   stale/pid-1-nimiavaruuteen).
//! - Epäonnistunut compose purkaa jo ladatut LIFO:ssa — ei osittaisia
//!   ympäristöjä (C2). Siivous on ehdoton: myös epäonnistunut ajo puretaan.
//! - Kerrallaan yksi aktiivinen koostumus (dokumentoitu rajoite —
//!   rinnakkaiset koostumukset ovat vaiheen 35 federaatiota, eivät tätä).
//! - Kello on looginen (start=0, deadline=timeout): ei ajastinriippuvuutta
//!   boot-testissä; reaalinen tick-integraatio vaiheessa 35+.

// Tuo puhdas TDL-ydin (tekstimuoto + binäärispec, build-moduuli).
const task = @import("composer_task");
// Tuo ratkaisuheuristiikka (tarve → PluginReq, build-moduuli).
const resolve = @import("composer_resolve");
// Tuo purkupolitiikka (LIFO + timeout, puhdas, suhteellinen).
const decomposer = @import("decomposer.zig");
// Tuo scope-raja — initScope/validate lataajan biteistä.
const scope = @import("plugin/scope.zig");
// Tuo manifestivalvonta — buildSingleCapManifest/checkScope.
const manifest = @import("plugin/manifest.zig");
// Tuo plugin-loader — loadPlugin/runPlugin/unloadPlugin + rekisteri.
const loader = @import("plugin/loader.zig");
// Tuo prosessitaulukko — currentPid lataaja-parentiksi (jaettu moduli).
const process = @import("process_core");
// Tuo lokitus boot-viesteihin (vain staattiset merkkijonot).
const log = @import("lib/log.zig");

// Koostumuksen tulos — yksi syy kerrallaan.
pub const ComposeResult = enum(u3) {
    // Kaikki tarpeet ladattu + rekisteröity scope-tarkistettuna.
    ok = 0,
    // Heuristiikka hylkäsi (katto-ristiriita / tuntematon binääri).
    fail_resolve = 1,
    // Manifesti/scope-portti hylkäsi vaatimuksen (ei eskalaatiota).
    fail_validate = 2,
    // ELF-lataus epäonnistui (kehys/pid loppu).
    fail_load = 3,
    // Rekisteri täynnä (ladattu purettu takaisin).
    fail_registry = 4,
};

// Aktiivinen koostumus (vain yksi kerrallaan vaiheessa 34).
var current: decomposer.Composition = .{
    .active = false,
    .name_buf = undefined,
    .name_len = 0,
    .pids = undefined,
    .count = 0,
    .started_ticks = 0,
    .deadline_ticks = 0,
    .failed = false,
};

// Onko koostumus aktiivinen (testien suojatarkistus).
pub fn isComposing() bool {
    return current.active;
}

// Montako pluginia aktiivisessa koostumuksessa (0 jos ei aktiivinen).
pub fn compositionCount() usize {
    if (!current.active) return 0;
    return current.count;
}

// Koostumuksen erääntymisraja (timeout-predikaatin johdotus boot-testissä).
pub fn compositionDeadline() u64 {
    return current.deadline_ticks;
}

// Kopioi ladatut pidit kutsujan puskuriin (purkuvarmistusta varten).
pub fn copyPids(out: []u64) usize {
    if (!current.active) return 0;
    const n = if (current.count < out.len) current.count else out.len;
    var i: usize = 0;
    while (i < n) : (i += 1) out[i] = current.pids[i];
    return n;
}

// Pura osittainen latauslista LIFO:ssa (C2 — ei osittaisia ympäristöjä).
fn unwindLoaded(pids: []const u64) void {
    // Askel i → indeksi LIFO:ssa (uusin ensin).
    var step: usize = 0;
    while (step < pids.len) : (step += 1) {
        const idx = decomposer.lifoAt(pids.len, step);
        _ = loader.unloadPlugin(pids[idx]);
    }
}

// Sävellä tehtävä minimaaliympäristöksi — lataa + rekisteröi scope-portin läpi.
pub fn composeTask(spec: task.TaskSpec) ComposeResult {
    // Vain yksi koostumus kerrallaan (toinen kieltäytyy — ei pinoamista).
    if (current.active) return .fail_registry;
    // Ratkaise tarpeet vaatimuksiksi (katto-ristiriita → hylkää, nolla ladattu).
    var reqs: [decomposer.MAX_COMPOSITION_PLUGINS]resolve.PluginReq = undefined;
    const n = resolve.resolve(spec, &reqs) catch return .fail_resolve;
    // Lataaja-parent on nykyinen prosessi (boot-testissä BOOT).
    const parent = process.currentPid();
    // Käy vaatimukset latausjärjestyksessä (hakemisto 0 = vanhin).
    var loaded: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        // Vain tunnettu binääri kelpaa (rekisteri-ratkaisu vaiheessa 32+).
        // Tässä vaiheessa mitään ei ole vielä ladattu — suora hylkäys.
        if (!loader.isValidEmbeddedId(reqs[i].embedded_id)) {
            return .fail_resolve;
        }
        // Rakenna yhden capin manifesti (rakennevirhe → EINVAL-vastaava hylkäys).
        const m = manifest.buildSingleCapManifest(reqs[i].req_type, reqs[i].req_rights) catch {
            // Pura aiemmin ladatut LIFO:ssa.
            var tmp: [decomposer.MAX_COMPOSITION_PLUGINS]u64 = undefined;
            var k: usize = 0;
            while (k < loaded) : (k += 1) tmp[k] = current.pids[k];
            unwindLoaded(tmp[0..loaded]);
            current.count = 0;
            return .fail_validate;
        };
        // Rakennevalidointi.
        manifest.checkManifest(m) catch {
            var tmp: [decomposer.MAX_COMPOSITION_PLUGINS]u64 = undefined;
            var k: usize = 0;
            while (k < loaded) : (k += 1) tmp[k] = current.pids[k];
            unwindLoaded(tmp[0..loaded]);
            current.count = 0;
            return .fail_validate;
        };
        // Rakenna scope ehdotetuista biteistä (pid sidotaan alle).
        var sc = scope.initScope(parent, reqs[i].scope_types, reqs[i].scope_rights, reqs[i].max_caps);
        // Scope itse kelvoton.
        if (!scope.validate(sc)) {
            var tmp: [decomposer.MAX_COMPOSITION_PLUGINS]u64 = undefined;
            var k: usize = 0;
            while (k < loaded) : (k += 1) tmp[k] = current.pids[k];
            unwindLoaded(tmp[0..loaded]);
            current.count = 0;
            return .fail_validate;
        }
        // Manifesti scopen ulkopuolella → EPERM-vastaava hylkäys (ei eskalaatiota).
        if (!manifest.checkScope(sc, m)) {
            var tmp: [decomposer.MAX_COMPOSITION_PLUGINS]u64 = undefined;
            var k: usize = 0;
            while (k < loaded) : (k += 1) tmp[k] = current.pids[k];
            unwindLoaded(tmp[0..loaded]);
            current.count = 0;
            return .fail_validate;
        }
        // Lataa ELF uudelle pid:lle omaan sivutauluun.
        const pid = loader.loadPlugin(reqs[i].embedded_id) orelse {
            var tmp: [decomposer.MAX_COMPOSITION_PLUGINS]u64 = undefined;
            var k: usize = 0;
            while (k < loaded) : (k += 1) tmp[k] = current.pids[k];
            unwindLoaded(tmp[0..loaded]);
            current.count = 0;
            return .fail_load;
        };
        // Sido scope ladattuun pidiin (S1-korjaus: ei stale-pidiä).
        sc.plugin_pid = pid;
        // Rekisteröi — täysi rekisteri → siivoa lataus ja hylkää.
        if (!loader.registerPlugin(pid, parent, sc)) {
            _ = loader.unloadPlugin(pid);
            var tmp: [decomposer.MAX_COMPOSITION_PLUGINS]u64 = undefined;
            var k: usize = 0;
            while (k < loaded) : (k += 1) tmp[k] = current.pids[k];
            unwindLoaded(tmp[0..loaded]);
            current.count = 0;
            return .fail_registry;
        }
        // Kirjaa latausjärjestyksessä.
        current.pids[loaded] = pid;
        loaded += 1;
        current.count = loaded;
    }
    // Kokoa koostumustietue (nimi TDL-specistä, looginen kello).
    var ni: usize = 0;
    while (ni < spec.name_len and ni < decomposer.MAX_TASK_NAME) : (ni += 1) {
        current.name_buf[ni] = spec.name_buf[ni];
    }
    current.name_len = ni;
    var z: usize = ni;
    while (z < decomposer.MAX_TASK_NAME) : (z += 1) current.name_buf[z] = 0;
    current.started_ticks = 0;
    current.deadline_ticks = spec.timeout_ticks;
    current.failed = false;
    current.active = true;
    return .ok;
}

// Aja koostumuksen pluginet latausjärjestyksessä ring 3:ssa.
pub fn runComposition() bool {
    // Ei aktiivista koostumusta.
    if (!current.active) return false;
    // Käy vanhimmasta uusimpaan.
    var i: usize = 0;
    while (i < current.count) : (i += 1) {
        // Ajo epäonnistui → merkitse, mutta pura silti (siivous ehdoton).
        if (!loader.runPlugin(current.pids[i])) {
            current.failed = true;
            return false;
        }
    }
    return true;
}

// Pura koostumus LIFO:ssa (uusin ensin) — C3/C5.
pub fn decomposeTask() bool {
    // Ei aktiivista koostumusta → triviaalisti purettu.
    if (!current.active) return true;
    // Askel i → indeksi LIFO:ssa.
    var step: usize = 0;
    while (step < current.count) : (step += 1) {
        const idx = decomposer.lifoAt(current.count, step);
        _ = loader.unloadPlugin(current.pids[idx]);
    }
    // Varmista rekisteristä poistuminen (jokainen ladattu poissa).
    var i: usize = 0;
    while (i < current.count) : (i += 1) {
        if (loader.isPlugin(current.pids[i])) return false;
    }
    // Nollaa tietue (C5: nolla pluginia jää).
    current.active = false;
    current.count = 0;
    current.failed = false;
    return true;
}

// Boot-testi — tehtävä → sävelllys → ajo → purku (Vaihe 34).
pub fn runBootTest() void {
    // Demo-tehtävä (kiinteä merkkijono — log.info ottaa vain comptime-str).
    const demo =
        "task \"http+uptime\" { need port:send+recv; need port:recv; timeout 1000; plugins 2; }";
    // Vastaanotto-serial (sama muoto kuin eeden-appendiksin testi).
    log.info("Task received: http+uptime");
    // Sävellys alkaa.
    log.info("Composing system...");
    // Laske demo binäärimuotoon.
    const spec = task.parse(demo) catch {
        log.err("Task parse failed");
        return;
    };
    // Negatiivi 1: tuntematon lause hylätään, mitään ei aloiteta (fail-closed).
    if (task.parse("task \"x\" { frobnicate; }")) |_| {
        log.err("Task bad syntax accepted");
        return;
    } else |_| {}
    // Negatiivi 2: katto-ristiriita (2 tarvetta, katto 1) → TooManyPlugins,
    // nolla pluginia ladattu ennen positiivista (C2 esitarkistus).
    const tight = task.parse("task \"tight\" { need port:send; need port:recv; timeout 100; plugins 1; }") catch {
        log.err("Task tight parse failed");
        return;
    };
    var tight_buf: [decomposer.MAX_COMPOSITION_PLUGINS]resolve.PluginReq = undefined;
    if (resolve.resolve(tight, &tight_buf)) |_| {
        log.err("Task ceiling not enforced");
        return;
    } else |_| {}
    if (isComposing() or compositionCount() != 0) {
        log.err("Task leaked before compose");
        return;
    }
    // Positiivi: sävellä demo (molemmat tarpeet scope-portin läpi).
    if (composeTask(spec) != .ok) {
        log.err("Task compose failed");
        return;
    }
    // Kaksi pluginia (1:1-minimaalisuus).
    if (compositionCount() != 2) {
        log.err("Task compose count wrong");
        _ = decomposeTask();
        return;
    }
    // Ei laajennusta: jokainen vaatimus kaventaa tarvetta (offline-tarkistus).
    var check_buf: [decomposer.MAX_COMPOSITION_PLUGINS]resolve.PluginReq = undefined;
    const rn = resolve.resolve(spec, &check_buf) catch {
        log.err("Task re-resolve failed");
        _ = decomposeTask();
        return;
    };
    var ci: usize = 0;
    while (ci < rn) : (ci += 1) {
        if (!resolve.reqNarrowsNeed(spec.needs[ci], check_buf[ci])) {
            log.err("Task resolve broadened");
            _ = decomposeTask();
            return;
        }
    }
    // Molemmat rekisterissä latauksen jälkeen.
    var pi: usize = 0;
    while (pi < current.count) : (pi += 1) {
        if (!loader.isPlugin(current.pids[pi])) {
            log.err("Task plugin not registered");
            _ = decomposeTask();
            return;
        }
    }
    // Sävellys valmis.
    log.info("Task compose OK");
    // Aja jokainen ring 3:ssa (tulostaa "plg" per plugin serialiin).
    if (!runComposition()) {
        log.err("Task run failed");
        _ = decomposeTask();
        return;
    }
    // Ajo valmis.
    log.info("Task run OK");
    // Tehtävä valmis -serial (eeden-testin muoto).
    log.info("Task complete");
    // Purku alkaa.
    log.info("Decomposing...");
    // Timeout-predikaatti johdotettu koostumuksen deadlineen (C4):
    // alussa ei erääntynyt, rajalla erääntynyt.
    if (decomposer.isExpired(0, compositionDeadline())) {
        log.err("Task premature expiry");
        _ = decomposeTask();
        return;
    }
    if (!decomposer.isExpired(compositionDeadline(), compositionDeadline())) {
        log.err("Task expiry stuck");
        _ = decomposeTask();
        return;
    }
    // Talleta pidit purkuvarmistusta varten (decompose nollaa tietueen).
    var saved: [decomposer.MAX_COMPOSITION_PLUGINS]u64 = undefined;
    const sn = copyPids(&saved);
    // Pura LIFO:ssa.
    if (!decomposeTask()) {
        log.err("Task decompose failed");
        return;
    }
    // Nolla pluginia jäänyt (C5).
    if (compositionCount() != 0 or isComposing()) {
        log.err("Task decompose leaked");
        return;
    }
    var si: usize = 0;
    while (si < sn) : (si += 1) {
        if (loader.isPlugin(saved[si])) {
            log.err("Task plugin survived");
            return;
        }
    }
    // Purku valmis + ydin yksin (eeden-testin muoto).
    log.info("Task decompose OK");
    log.info("Core only. Ready for next task.");
}
