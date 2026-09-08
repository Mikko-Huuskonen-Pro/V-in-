//! Plugin self-heal boot-testi — diagnostiikka + validointi + hot-swap (Vaihe 33).
//!
//! **Vastuu**: Todista päästä päähän että kaatunut plugin havaitaan,
//!   korvaava instanssi validoidaan ja vaihdetaan tilalle IPC-jatkuvuudella.
//! **Riippuvuudet**: `dispatch.zig` (load/unload/send/recv), `../plugin/loader.zig`,
//!   `../plugin/scope.zig`, `../plugin/manifest.zig`, `../plugin/ns_map.zig`,
//!   `../ipc/capability_core.zig`, `../ipc/port.zig`, `../plugin_diag.zig`,
//!   `../plugin_swap.zig`, `process_core`, log.
//! **Käytetään**: `kernel/boot_tests.zig::runAll()`.
//!
//! ## Arkkitehtuurihuomiot
//! - Jatkuvuus jaetulla portilla: yhteinen IPC-portti omistetaan BOOT:ille,
//!   joten se selviää vanhan purusta. Vanhan OMISTAMAT capit kuolevat mukana
//!   (Phase 31.5 snapshotit toisivat omistetun tilan migraation).
//! - Paikallaanvaihto (sama pid): ei taulukkoaukkoja append-only
//!   prosessitaulukossa (ks. plugin_swap.zig). Järjestys on LIFO-turvallinen:
//!   apuplugin B puretaan ennen swapia, joten A on häntä.
//! - Kaikki lokit staattisia merkkijonoja (log.info ottaa vain comptime-str).

// Tuo jaettu ABI — plugin/ipc-syscallit + virhekoodit.
const abi = @import("zinuxabi");
// Tuo dispatch — invoke() ilman ring 3:a.
const dispatch = @import("dispatch.zig");
// Tuo plugin-loader — isPlugin/runPlugin + scope/parent.
const loader = @import("../plugin/loader.zig");
// Tuo scope-maskit + gateway-predikaatti.
const scope = @import("../plugin/scope.zig");
// Tuo manifestivalvonta — offline-putken vaiheet.
const manifest = @import("../plugin/manifest.zig");
// Tuo gateway — live-siirto A→B ennen swapia.
const gateway = @import("../plugin/ns_map.zig");
// Tuo capability-ydin — jaetun portin objekti + slotit.
const cap = @import("../ipc/capability_core.zig");
// Tuo portit — createPort + MAX_MSG_SIZE.
const port = @import("../ipc/port.zig");
// Tuo diagnostiikka — crash-havainto + reset.
const diag = @import("../plugin_diag.zig");
// Tuo swap-orkestraattori — paikallaanvaihto.
const swap = @import("../plugin_swap.zig");
// Tuo prosessitaulukko — kontekstit + BOOT_PID.
const process = @import("process_core");
// Tuo lokitus boot-viesteihin.
const log = @import("../lib/log.zig");

// Etsi slotti pidin taulukosta taustaobjektin perusteella — null jos ei löydy.
fn findSlotByObject(pid: u64, object_id: u32) ?u32 {
    // Käy pidin slotit.
    const total = cap.slotCountForPid(pid);
    var slot: u32 = 0;
    while (slot < total) : (slot += 1) {
        const ref = cap.lookupSlotForPid(pid, slot) orelse continue;
        if (ref.object_id == object_id) return slot;
    }
    return null;
}

// Boot-testi — 33.1 diagnostiikka + 33.3 validointi + 33.4 hot-swap.
pub fn runBootTest() void {
    // Diagnoositaulukko puhtaaksi (muut testit eivät käytä sitä).
    diag.initCore();

    // --- Lataa plugin A grant-scopella (swapin kohde, häntä) ---
    const raw_a = dispatch.invoke(abi.SYS_plugin_load, loader.PLUGIN_EMBEDDED_ID, 1, scope.MASK_SEND, scope.TYPE_PORT | scope.TYPE_MEMORY, scope.MASK_SEND | scope.MASK_RECV | scope.MASK_GRANT | scope.MASK_READ | scope.MASK_MAP, 4);
    if (raw_a <= 1) {
        log.err("Heal load A failed");
        return;
    }
    const pid_a: u64 = @intCast(raw_a);

    // Rekisteröi diagnostiikka + totea terve.
    if (!diag.registerDiagnostic(pid_a)) {
        log.err("Heal diag register failed");
        return;
    }
    if (diag.getHealth(pid_a) != .healthy) {
        log.err("Heal diag not healthy");
        return;
    }

    // --- Jaettu jatkuvuusportti (omistaja BOOT → selviää swapista) ---
    const shared_port = port.createPort() orelse {
        log.err("Heal shared port failed");
        return;
    };
    const shared_obj = cap.createObject(.port, process.BOOT_PID, shared_port) orelse {
        log.err("Heal shared object failed");
        return;
    };
    // BOOT:in lähetysslotti (read+send).
    const boot_slot = cap.installSlotForPid(process.BOOT_PID, shared_obj, .{ .read = true, .send = true }) orelse {
        log.err("Heal boot slot failed");
        return;
    };
    // A:n vastaanottoslotti (read+recv — A:n scopen osajoukko).
    if (cap.installSlotForPid(pid_a, shared_obj, .{ .read = true, .recv = true }) == null) {
        log.err("Heal plugin slot failed");
        return;
    }

    // --- A:n oma grant-cap gateway-demoon (omistaja A → kuolee swapissa) ---
    const demo_port = port.createPort() orelse {
        log.err("Heal demo port failed");
        return;
    };
    const demo_rights = cap.Rights{ .read = true, .send = true, .recv = true, .grant = true };
    const demo_obj = cap.createObject(.port, pid_a, demo_port) orelse {
        log.err("Heal demo object failed");
        return;
    };
    const demo_slot = cap.installSlotForPid(pid_a, demo_obj, demo_rights) orelse {
        log.err("Heal demo slot failed");
        return;
    };

    // --- 33.3 validointiputki offline: manifesti + scope + gateway-predikaatti ---
    const m = manifest.buildSingleCapManifest(1, scope.MASK_SEND) catch {
        log.err("Heal manifest build failed");
        return;
    };
    manifest.checkManifest(m) catch {
        log.err("Heal manifest invalid");
        return;
    };
    const sc_a = loader.pluginScope(pid_a) orelse {
        log.err("Heal no scope A");
        return;
    };
    if (!manifest.checkScope(sc_a, m)) {
        log.err("Heal manifest scope denied");
        return;
    }
    // Gateway-predikaatti puhtain faktoin (ei kirjoitusta).
    if (!scope.allowsGatewayTransfer(sc_a, 1, scope.MASK_RECV | scope.MASK_READ, 0, true, true, true)) {
        log.err("Heal gateway predicate denied");
        return;
    }
    log.info("Plugin heal validation OK");

    // --- Live-gateway A→B (todistaa siirtokehyksen ennen swapia) ---
    const raw_b = dispatch.invoke(abi.SYS_plugin_load, loader.PLUGIN_EMBEDDED_ID, 1, scope.MASK_RECV, scope.TYPE_PORT, scope.MASK_SEND | scope.MASK_RECV | scope.MASK_READ, 4);
    if (raw_b <= 1) {
        log.err("Heal load B failed");
        return;
    }
    const pid_b: u64 = @intCast(raw_b);
    // Siirrä demo-cap B:lle gatewayn läpi (kutsuja BOOT — sallittu juuri).
    const got_b = gateway.gatewayTransfer(pid_a, demo_slot, pid_b, scope.MASK_RECV | scope.MASK_READ) orelse {
        log.err("Heal gateway transfer failed");
        return;
    };
    // Viesti A→B siirretyllä capilla.
    const ping = "HS1";
    if (!process.setCurrentPid(pid_a)) {
        log.err("Heal switch A failed");
        return;
    }
    const sent = dispatch.invoke(abi.SYS_ipc_send, demo_slot, @intFromPtr(ping), ping.len, 0, 0, 0);
    _ = process.setCurrentPid(process.BOOT_PID);
    if (sent != ping.len) {
        log.err("Heal gateway send failed");
        return;
    }
    if (!process.setCurrentPid(pid_b)) {
        log.err("Heal switch B failed");
        return;
    }
    var ping_buf: [port.MAX_MSG_SIZE]u8 = undefined;
    const got = dispatch.invoke(abi.SYS_ipc_recv, got_b, @intFromPtr(&ping_buf), ping_buf.len, 0, 0, 0);
    _ = process.setCurrentPid(process.BOOT_PID);
    if (got != ping.len) {
        log.err("Heal gateway recv failed");
        return;
    }
    // Pura B (häntä → ei taulukkoaukkoa). A on taas häntä swapia varten.
    if (dispatch.invoke(abi.SYS_plugin_unload, pid_b, 0, 0, 0, 0, 0) != 0) {
        log.err("Heal unload B failed");
        return;
    }

    // --- 33.1 crash-simulaatio: 3 vikaa → crashed ---
    diag.recordFault(pid_a, -60);
    diag.recordFault(pid_a, -61);
    diag.recordFault(pid_a, -62);
    if (diag.getHealth(pid_a) != .crashed) {
        log.err("Heal crash not detected");
        return;
    }
    log.info("Plugin diagnostics OK");

    // --- 33.4 hot-swap samaan pidiin ---
    if (swap.swapPlugin(pid_a, loader.PLUGIN_EMBEDDED_ID) != .ok) {
        log.err("Heal swap failed");
        return;
    }
    // Diagnoosi puhtaaksi vaihdon jälkeen.
    diag.resetDiagnostic(pid_a);
    if (diag.getHealth(pid_a) != .healthy) {
        log.err("Heal reset not healthy");
        return;
    }

    // --- Jatkuvuus: BOOT lähettää jaettuun porttiin, uusi instanssi vastaanottaa ---
    const heal_msg = "HS3";
    const healed_slot = findSlotByObject(pid_a, shared_obj) orelse {
        log.err("Heal shared slot lost");
        return;
    };
    const sent2 = dispatch.invoke(abi.SYS_ipc_send, @intCast(boot_slot), @intFromPtr(heal_msg), heal_msg.len, 0, 0, 0);
    if (sent2 != heal_msg.len) {
        log.err("Heal continuity send failed");
        return;
    }
    if (!process.setCurrentPid(pid_a)) {
        log.err("Heal switch healed failed");
        return;
    }
    var heal_buf: [port.MAX_MSG_SIZE]u8 = undefined;
    const got2 = dispatch.invoke(abi.SYS_ipc_recv, healed_slot, @intFromPtr(&heal_buf), heal_buf.len, 0, 0, 0);
    _ = process.setCurrentPid(process.BOOT_PID);
    if (got2 != heal_msg.len) {
        log.err("Heal continuity recv failed");
        return;
    }
    // Tavut täsmäävät.
    var i: usize = 0;
    while (i < heal_msg.len) : (i += 1) {
        if (heal_buf[i] != heal_msg[i]) {
            log.err("Heal payload mismatch");
            return;
        }
    }

    // Uusi instanssi ajaa ring 3:ssa ("plg").
    if (!loader.runPlugin(pid_a)) {
        log.err("Heal run failed");
        return;
    }

    // Siivoa: pura A (häntä), deregister diag.
    if (dispatch.invoke(abi.SYS_plugin_unload, pid_a, 0, 0, 0, 0, 0) != 0) {
        log.err("Heal unload A failed");
        return;
    }
    _ = diag.deregisterDiagnostic(pid_a);
    // Jaettu objekti BOOT:in nimissä — siivoa slotit (objekti jää BOOT:ille,
    // porttitaulukko on pieni ja boot-testi kertakäyttöinen).
    _ = cap.revokeObject(shared_obj);

    // Itseparantuvuus päästä päähän OK.
    log.info("Self-heal OK");
}
