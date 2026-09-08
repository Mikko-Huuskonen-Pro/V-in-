//! Plugin load boot-testi — sys_plugin_load invoke + ajo ring 3:ssa (Vaihe 30).
//!
//! **Vastuu**: Varmista manifesti+scope-valvottu lataus ja pluginin elossaolo.
//! **Riippuvuudet**: `dispatch.zig`, `../plugin/loader.zig`, `../plugin/scope.zig`, log
//! **Käytetään**: `kernel/boot_tests.zig`

// Tuo jaettu ABI — SYS_plugin_load + virhekoodit.
const abi = @import("zinuxabi");
// Tuo dispatch — invoke() suoraan ilman ring 3.
const dispatch = @import("dispatch.zig");
// Tuo plugin-loader — isPlugin/runPlugin tarkistuksiin.
const loader = @import("../plugin/loader.zig");
// Tuo scope-maskit testivektoreihin.
const scope = @import("../plugin/scope.zig");
// Tuo lokitus boot-viesteihin.
const log = @import("../lib/log.zig");

// Boot-testi — sys_plugin_load valvonta + ring 3 ajo.
pub fn runBootTest() void {
    // 30.3 — tuntematon plugin-binääri → EINVAL.
    const bad_id = dispatch.invoke(abi.SYS_plugin_load, 99, 1, scope.MASK_SEND, scope.TYPE_PORT, scope.MASK_SEND, 4);
    // Varmista EINVAL eikä pid.
    if (bad_id != abi.EINVAL) {
        // Tuntematon id meni läpi.
        log.err("Plugin load bad id not EINVAL");
        // Lopeta testi.
        return;
    }
    // 30.3 — eskalaatio: grant-pyyntö scopella ilman grantia → EPERM.
    const evil = dispatch.invoke(abi.SYS_plugin_load, loader.PLUGIN_EMBEDDED_ID, 1, scope.MASK_GRANT, scope.TYPE_PORT, scope.MASK_SEND, 4);
    // Varmista EPERM eikä pid.
    if (evil != abi.EPERM) {
        // Eskalaatio meni läpi.
        log.err("Plugin load escalation not EPERM");
        // Lopeta testi.
        return;
    }
    // 30.3 — kelvollinen lataus: port/send-manifesti, laaja scope, katto 4.
    const pid_raw = dispatch.invoke(abi.SYS_plugin_load, loader.PLUGIN_EMBEDDED_ID, 1, scope.MASK_SEND, scope.TYPE_PORT | scope.TYPE_MEMORY, scope.MASK_SEND | scope.MASK_RECV | scope.MASK_MAP | scope.MASK_READ, 4);
    // Varmista positiivinen plugin-pid.
    if (pid_raw <= 1) {
        // Lataus epäonnistui.
        log.err("Plugin load failed");
        // Lopeta testi.
        return;
    }
    // Uusi plugin-pid u64:na.
    const pid: u64 = @intCast(pid_raw);
    // Rekisterissä latauksen jälkeen.
    if (!loader.isPlugin(pid)) {
        // Rekisteröinti puuttuu.
        log.err("Plugin not registered");
        // Lopeta testi.
        return;
    }
    // Suorita plugin ring 3:ssa — tulostaa "plg\n" serialiin.
    if (!loader.runPlugin(pid)) {
        // Ajo epäonnistui.
        log.err("Plugin run failed");
        // Lopeta testi.
        return;
    }
    // Lataus + valvonta + ajo OK (plugin jää residentiksi unload-testiä varten).
    log.info("Plugin load OK");
}
