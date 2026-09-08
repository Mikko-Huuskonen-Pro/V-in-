//! Plugin-loader — upotetun plugin-ELF:n lataus + rekisteri (Vaihe 30).
//!
//! **Vastuu**: Lataa plugin-ELF omalle pid:lle omaan sivutauluun, pidä rekisteriä
//!   ladatuista plugineista, vapauta resurssit unloadissa.
//! **Riippuvuudet**: `loader/elf.zig`, `process_core`, `vmm.zig`, `pmm.zig`,
//!   `scope.zig`, `../ipc/capability_core.zig`, `../arch/x86_64/usermode.zig`
//! **Käytetään**: `syscall/dispatch.zig` (load/unload), `syscall/plugin_*_syscall.zig`
//!
//! ## Arkkitehtuurihuomiot
//! - Uudelleenkäyttää Vaihe 5 ELF-parserin + Vaihe 25 per-process PML4-kaavan
//!   (sama allokaatio-järjestys kuin `spawn.zig`, mutta plugin-rekisterillä).
//! - Tiedostojärjestelmää ei ole — plugin-binääri on build.zig:n upottama ELF
//!   (`plugin_prog.bin`). Polku-argumentti tulee vaiheessa 32+ (jakelu).
//! - Manifesti-validointi ei ole täällä vaan `manifest.zig`:ssä; dispatch
//!   kutsuu sitä ennen loadPlugin:ia (kernel päättää, loader suorittaa).

// Tuo ELF-loader — PT_LOAD + erillinen pinokartoitus.
const elf = @import("../loader/elf.zig");
// Tuo ring 3 siirtymä — iretq tietyllä pid:llä.
const usermode = @import("../arch/x86_64/usermode.zig");
// Tuo prosessitaulukko — pid-allokaatio ja sivutaulut.
const process = @import("process_core");
// Tuo VMM — per-process page table + physToVirt.
const vmm = @import("../mm/vmm.zig");
// Tuo PMM — PML4-kehys + physToFrame vapautukseen.
const pmm = @import("../mm/pmm.zig");
// Tuo scope — rekisteri säilyttää pluginin rajan unload-tarkistuksiin.
const scope = @import("scope.zig");
// Tuo capability-ydin — omistettujen objektien peruutus unloadissa.
const cap = @import("../ipc/capability_core.zig");

// Upotettu plugin-ELF — build.zig kopioi user-bin:n tähän ennen kernel-käännöstä.
const plugin_elf = @embedFile("../loader/plugin_prog.bin");

// Plugin-ELF-tunniste sys_plugin_load a1:lle (ainoa vaiheessa 30).
pub const PLUGIN_EMBEDDED_ID: u64 = 0;
// Plugin-pinon heap-slot — vapaa väli (112-115 spawn, 114 cross-ipc).
pub const PLUGIN_STACK_SLOT: u64 = 116;
// Montako pluginia rekisteriin mahtuu (pieni, mitattava raja).
pub const MAX_PLUGINS: usize = 8;

// Yksi ladattu plugin rekisterissä.
pub const PluginEntry = struct {
    // Onko rekisteripaikka käytössä.
    used: bool,
    // Plugin-prosessin pid.
    pid: u64,
    // Lataajan pid (unload-oikeus: parent tai boot).
    parent_pid: u64,
    // Pluginin capability-raja (scope).
    plugin_scope: scope.Scope,
};

// Kiinteä plugin-rekisteri — ei allokaatiota.
var registry: [MAX_PLUGINS]PluginEntry = undefined;
// Onko rekisteri nollattu.
var registry_init: bool = false;

// Nollaa rekisteri tarvittaessa — kutsutaan julkisista funktioista.
fn ensureInit() void {
    // Jo alustettu — ei työtä.
    if (registry_init) return;
    // Tyhjennä jokainen paikka.
    for (&registry) |*e| {
        // Merkitse vapaa.
        e.used = false;
        // Nollaa pid.
        e.pid = 0;
        // Nollaa lataaja.
        e.parent_pid = 0;
        // Nollaa scope tyhjällä rajalla.
        e.plugin_scope = scope.initScope(0, 0, 0, 1);
    }
    // Merkitse alustetuksi.
    registry_init = true;
}

// Onko embedded-tunniste kelvollinen plugin-ELF (vaihe 30: vain 0).
pub fn isValidEmbeddedId(id: u64) bool {
    // Ainoa tuettu plugin-binääri.
    return id == PLUGIN_EMBEDDED_ID;
}

// Etsi pluginin rekisteri-indeksi pid:llä — null jos ei ladattu plugin.
fn findIndex(pid: u64) ?usize {
    // Varmista nollattu rekisteri.
    ensureInit();
    // Käy rekisteripaikat.
    var i: usize = 0;
    while (i < MAX_PLUGINS) : (i += 1) {
        // Täsmäävä käytössä oleva paikka.
        if (registry[i].used and registry[i].pid == pid) return i;
    }
    // Ei ladattu plugin.
    return null;
}

// Onko pid ladattu plugin.
pub fn isPlugin(pid: u64) bool {
    // Rekisteriosuma → plugin.
    return findIndex(pid) != null;
}

// Montako pluginia ladattu.
pub fn pluginCount() usize {
    // Varmista nollattu rekisteri.
    ensureInit();
    // Laskuri.
    var n: usize = 0;
    // Käy paikat.
    for (registry) |e| {
        // Käytössä → laske.
        if (e.used) n += 1;
    }
    // Palauta määrä.
    return n;
}

// Hae pluginin lataaja-parent — null jos ei plugin.
pub fn pluginParent(pid: u64) ?u64 {
    // Etsi rekisteristä.
    const idx = findIndex(pid) orelse return null;
    // Palauta lataajan pid.
    return registry[idx].parent_pid;
}

// Hae pluginin scope-raja — null jos ei plugin (Vaihe 31 gateway).
pub fn pluginScope(pid: u64) ?scope.Scope {
    // Etsi rekisteristä.
    const idx = findIndex(pid) orelse return null;
    // Palauta kopio scopesta.
    return registry[idx].plugin_scope;
}

// Rekisteröi ladattu plugin scopella — false jos rekisteri täynnä.
pub fn registerPlugin(pid: u64, parent_pid: u64, sc: scope.Scope) bool {
    // Varmista nollattu rekisteri.
    ensureInit();
    // Jo rekisteröity → OK (idempotentti).
    if (findIndex(pid) != null) return true;
    // Etsi vapaa paikka.
    var i: usize = 0;
    while (i < MAX_PLUGINS) : (i += 1) {
        // Vapaa paikka löytyi.
        if (!registry[i].used) {
            // Merkitse käytetyksi.
            registry[i].used = true;
            // Tallenna pid.
            registry[i].pid = pid;
            // Tallenna lataaja unload-tarkistukseen.
            registry[i].parent_pid = parent_pid;
            // Tallenna scope-raja.
            registry[i].plugin_scope = sc;
            // Onnistui.
            return true;
        }
    }
    // Rekisteri täynnä.
    return false;
}

// Poista plugin rekisteristä — false jos ei ollut rekisterissä.
pub fn unregisterPlugin(pid: u64) bool {
    // Etsi rekisteristä.
    const idx = findIndex(pid) orelse return false;
    // Merkitse vapaaksi.
    registry[idx].used = false;
    // Nollaa pid.
    registry[idx].pid = 0;
    // Nollaa lataaja.
    registry[idx].parent_pid = 0;
    // Onnistui.
    return true;
}

// Lataa plugin-ELF uudelle pid:lle omaan sivutauluun — palauttaa pid tai null.
pub fn loadPlugin(embedded_id: u64) ?u64 {
    // Vain tunnettu plugin-ELF kelpaa.
    if (!isValidEmbeddedId(embedded_id)) return null;
    // Allokoi seuraava vapaa pid prosessitaulukosta.
    const pid = process.allocNextPid() orelse return null;
    // Aseta vanhemmaksi nykyinen prosessi (unload-oikeus lataajalle).
    if (!process.setParentPid(pid, process.currentPid())) {
        // Siivoa varattu pid — häntä, puhdas poisto.
        _ = process.freePid(pid);
        return null;
    }
    // Allokoi nollattava PML4-kehys PMM:stä (Vaihe 25 kaava).
    const frame = pmm.allocFrame() orelse {
        // Siivoa varattu pid.
        _ = process.freePid(pid);
        return null;
    };
    // Kehysindeksi → fyysinen osoite.
    const pml4_phys = pmm.frameToPhys(frame);
    // Nollaa kehys — tyhjä PML4.
    const pml4_virt = vmm.physToVirt(pml4_phys);
    // Osoitin kehyksen tavuihin.
    const pml4_ptr: [*]u8 = @ptrFromInt(pml4_virt);
    // Nollaa 4 KiB.
    @memset(pml4_ptr[0..4096], 0);
    // Peri kernel-puolisko — syscallet/IRQ-käsittelijät näkyviin (ks. vmm).
    vmm.inheritKernelHalf(pml4_phys);
    // Tallenna prosessitaulukkoon (eristys I2).
    if (!process.setPageTable(pid, pml4_phys)) {
        // Siivoa kehys + pid.
        pmm.freeFrame(frame);
        _ = process.freePid(pid);
        return null;
    }
    // Kohdista kartoitukset pluginin PML4:ään.
    vmm.target_pml4_phys = pml4_phys;
    // Lataa ELF-segmentit + pino kohteen sivutauluun.
    const loaded = elf.loadElfWithStack(plugin_elf, PLUGIN_STACK_SLOT) orelse {
        // Palauta kernelin PML4.
        vmm.target_pml4_phys = null;
        // Siivoa kehys + taulu + pid.
        pmm.freeFrame(frame);
        _ = process.setPageTable(pid, 0);
        _ = process.freePid(pid);
        return null;
    };
    // Takaisin kernelin PML4:ään.
    vmm.target_pml4_phys = null;
    // Tallenna entry/pino prosessitaulukkoon runPlugin:ia varten.
    if (!process.setLoaded(pid, loaded.entry, loaded.stack_top, PLUGIN_STACK_SLOT)) {
        // Siivoa kehys + taulu + pid (segmentit jäävät orvoiksi — ei jakoa).
        pmm.freeFrame(frame);
        _ = process.setPageTable(pid, 0);
        _ = process.freePid(pid);
        return null;
    }
    // Palauta uuden plugin-prosessin tunniste.
    return pid;
}

// Suorita ladattu plugin ring 3:ssa — palaa sys_test_return:in jälkeen.
pub fn runPlugin(pid: u64) bool {
    // Hae ladatun pluginin entry ja pino.
    const info = process.getLoadedInfo(pid) orelse return false;
    // Siirry ring 3:een pluginin pid:llä (getpid toimii oikein).
    usermode.enterUserAs(info.entry, info.stack_top, pid);
    // Paluu sys_test_return ret:llä — plugin suoritettu ("plg\n").
    return true;
}

// Pura plugin: peru capsit, tyhjennä slotit, vapauta PML4, vapauta pid.
pub fn unloadPlugin(pid: u64) bool {
    // Pitää olla rekisteröity plugin.
    if (findIndex(pid) == null) return false;
    // Peruuta kaikki pidin omistamat objektit (portit vapautuvat samalla).
    _ = cap.revokeAllOwnedBy(pid);
    // Tyhjennä pidin slotit (myös muiden omistamiin viitteet).
    _ = cap.clearSlotsForPid(pid);
    // Vapauta per-process PML4-kehys jos tallessa.
    if (process.getPageTable(pid)) |pt| {
        // Nolla tarkoittaa ei-erillistä taulua — ei vapautettavaa.
        if (pt != 0) {
            // Muunna phys → kehysindeksi.
            if (pmm.physToFrame(pt)) |frame| {
                // Vapauta kehys takaisin PMM:ään.
                pmm.freeFrame(frame);
            }
            // Nollaa tauluviite joka tapauksessa.
            _ = process.setPageTable(pid, 0);
        }
    }
    // Vapauta pid prosessitaulukosta.
    if (!process.freePid(pid)) return false;
    // Poista rekisteristä.
    _ = unregisterPlugin(pid);
    // Purettu.
    return true;
}
