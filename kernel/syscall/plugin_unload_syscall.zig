//! Plugin unload boot-testi — sys_plugin_unload + resurssien vapautus (Vaihe 30).
//!
//! **Vastuu**: Varmista unload-oikeus, purku ja resurssien vapautus.
//! **Riippuvuudet**: `dispatch.zig`, `../plugin/loader.zig`, `process_core`, log
//! **Käytetään**: `kernel/boot_tests.zig`

// Tuo jaettu ABI — SYS_plugin_load/unload + virhekoodit.
const abi = @import("zinuxabi");
// Tuo dispatch — invoke() suoraan ilman ring 3.
const dispatch = @import("dispatch.zig");
// Tuo plugin-loader — isPlugin/pluginCount tarkistuksiin.
const loader = @import("../plugin/loader.zig");
// Tuo scope-maskit latausvektoriin.
const scope = @import("../plugin/scope.zig");
// Tuo prosessitaulukko — exists + currentPid EPERM-testin vaihdossa.
const process = @import("process_core");
// Tuo lokitus boot-viesteihin.
const log = @import("../lib/log.zig");

// Boot-testi — sys_plugin_unload oikeus + purku + kaksois-purku.
pub fn runBootTest() void {
    // Pluginien määrä ennen testiä.
    const before = loader.pluginCount();
    // Lataa purettava plugin (kutsuja = lataaja-parent).
    const pid_raw = dispatch.invoke(abi.SYS_plugin_load, loader.PLUGIN_EMBEDDED_ID, 1, scope.MASK_SEND, scope.TYPE_PORT | scope.TYPE_MEMORY, scope.MASK_SEND | scope.MASK_RECV, 4);
    // Varmista positiivinen plugin-pid.
    if (pid_raw <= 1) {
        // Lataus (purun esiehto) epäonnistui.
        log.err("Plugin unload setup failed");
        // Lopeta testi.
        return;
    }
    // Purettava pid u64:na.
    const pid: u64 = @intCast(pid_raw);
    // Rekisterimäärä kasvoi yhdellä.
    if (loader.pluginCount() != before + 1) {
        // Rekisteri ei seurannut latausta.
        log.err("Plugin count not increased");
        // Lopeta testi.
        return;
    }
    // Tallenna kutsuja EPERM-testin palautusta varten.
    const caller = process.currentPid();
    // Allokoi vieras-prosessi (ei lataaja, ei boot).
    const stranger = process.allocNextPid() orelse {
        // Taulukko täynnä.
        log.err("Plugin unload stranger alloc failed");
        // Lopeta testi.
        return;
    };
    // Vaihda current vieraaksi.
    if (!process.setCurrentPid(stranger)) {
        // Vaihto epäonnistui.
        log.err("Plugin unload stranger switch failed");
        // Lopeta testi.
        return;
    }
    // Vieras yrittää purkaa toisen pluginin → EPERM.
    const denied = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
    // Palauta kutsuja ennen tarkistusta (tila siistiksi).
    if (!process.setCurrentPid(caller)) {
        // Palautus epäonnistui.
        log.err("Plugin unload caller restore failed");
        // Lopeta testi.
        return;
    }
    // Varmista EPERM.
    if (denied != abi.EPERM) {
        // Vieraan purku meni läpi.
        log.err("Plugin unload stranger not EPERM");
        // Lopeta testi.
        return;
    }
    // Lataaja purkaa → 0.
    const ret = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
    // Varmista onnistuminen.
    if (ret != 0) {
        // Purku epäonnistui.
        log.err("Plugin unload failed");
        // Lopeta testi.
        return;
    }
    // Ei enää rekisterissä.
    if (loader.isPlugin(pid)) {
        // Rekisteri ei siivonnut.
        log.err("Plugin still registered");
        // Lopeta testi.
        return;
    }
    // Prosessi vapautettu taulukosta.
    if (process.exists(pid)) {
        // Pid jäi taulukkoon.
        log.err("Plugin pid still exists");
        // Lopeta testi.
        return;
    }
    // Rekisterimäärä palautui.
    if (loader.pluginCount() != before) {
        // Rekisteri vuoti paikan.
        log.err("Plugin count not restored");
        // Lopeta testi.
        return;
    }
    // Kaksois-purku → ESRCH.
    const twice = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
    // Varmista ESRCH.
    if (twice != abi.ESRCH) {
        // Puretun purku meni läpi.
        log.err("Plugin double unload not ESRCH");
        // Lopeta testi.
        return;
    }
    // Boot-prosessi ei ole plugin → ESRCH.
    const boot_ret = dispatch.invoke(abi.SYS_plugin_unload, process.BOOT_PID, 0, 0, 0, 0, 0);
    // Varmista ESRCH.
    if (boot_ret != abi.ESRCH) {
        // Boot-pidin purku meni läpi.
        log.err("Plugin unload boot not ESRCH");
        // Lopeta testi.
        return;
    }
    // Oikeus + purku + resurssit OK.
    log.info("Plugin unload OK");
}
