//! Federation-orkestraattori — klusteri → tunneli → migraatio → failover (Vaihe 35).
//!
//! **Vastuu**: Aja kahden loogisen solmun (A=paikallinen, B=naapuri) liitos,
//!   todennettu cap-työntö tunnelin läpi, plugin-migraatio A→B ja heartbeat-
//!   failover yhdessä boot-testissä. Todistaa että hajautuslogiikka toimii
//!   päästä päähän scope-portin läpi.
//! **Riippuvuudet**: `net/cap_tunnel.zig`, `migrate.zig`, `failover.zig`
//!   (suhteelliset), `remote_forwarder` (build-moduuli, sama kaava kuin
//!   `composer_task`), `plugin/loader+scope+manifest+ns_map`,
//!   `ipc/capability_core+port`, `process_core`, `dispatch`, `zinuxabi`, log.
//! **Käytetään**: `kernel/boot_tests.zig::runAll()`.
//!
//! ## Arkkitehtuurihuomiot (AGENTS.md: AI proposes, kernel decides)
//! - "Johto" on loopback-puskuri (yksi kone, ei NIC/TCP-pinnoa vaiheessa 35).
//!   Todennus (HMAC+replay), valtuutus (scope-portti) ja tilakoneet ovat
//!   oikeaa logiikkaa täysin testattuna; kuljetus on vaihdettava pala
//!   (vaihe 35.x). Valehtelu johdosta olisi epärehellinen koe — katso
//!   `docs/FEDERATION.md` (rajoite F-L1).
//! - Kerrosjako: tunneli TODENTAA (kuka/ehjä/tuore), gateway VALTUUTTAA
//!   (saako asentaa). MAC ei ole capability — se on kirjekuori.
//! - Boot-avain on TEST-ONLY-kiinteä (vaiheen 32 tapaan ei salaisuuksia
//!   repossa tuotantona; avainvaihto on vaihetta 35.x).
//! - Kaikki lokit staattisia merkkijonoja (log.info ottaa vain comptime-str).

// Tuo tunneli — seal/open + replay-ikkuna (suhteellinen, sama juuri).
const tunnel = @import("net/cap_tunnel.zig");
// Tuo migraatiotila — staged/pushed/restored/done/aborted (suhteellinen).
const migrate = @import("migrate.zig");
// Tuo klusteri + replika — heartbeat/sweep/ylennys (suhteellinen).
const failover = @import("failover.zig");
// Tuo etävälittäjä — reittitaulukko (build-moduuli, cross-root).
const forwarder = @import("remote_forwarder");
// Tuo jaettu ABI — plugin/ipc-syscallit + virhekoodit.
const abi = @import("zinuxabi");
// Tuo dispatch — invoke() ilman ring 3:a.
const dispatch = @import("syscall/dispatch.zig");
// Tuo plugin-loader — load/run/unload + rekisteri.
const loader = @import("plugin/loader.zig");
// Tuo scope-maskit + initScope/validate.
const scope = @import("plugin/scope.zig");
// Tuo gateway — todetun siirron valtuutettu asennus.
const gateway = @import("plugin/ns_map.zig");
// Tuo capability-ydin — jaetun portin objekti + slotit.
const cap = @import("ipc/capability_core.zig");
// Tuo portit — createPort + MAX_MSG_SIZE.
const port = @import("ipc/port.zig");
// Tuo prosessitaulukko — kontekstit + BOOT_PID.
const process = @import("process_core");
// Tuo lokitus boot-viesteihin.
const log = @import("lib/log.zig");

// Loogiset solmut demossa (A=paikallinen, B=naapuri, 9=haamu).
pub const NODE_A: u32 = 1;
pub const NODE_B: u32 = 2;
pub const NODE_GHOST: u32 = 9;
// Heartbeat-timeout tickeissä (looginen kello — ei ajastinriippuvuutta).
pub const HEARTBEAT_TIMEOUT: u64 = 100;

// Etsi slotti pidin taulukosta taustaobjektin perusteella — null jos ei löydy.
fn findSlotByObject(pid: u64, object_id: u32) ?u32 {
    const total = cap.slotCountForPid(pid);
    var slot: u32 = 0;
    while (slot < total) : (slot += 1) {
        const ref = cap.lookupSlotForPid(pid, slot) orelse continue;
        if (ref.object_id == object_id) return slot;
    }
    return null;
}

// Boot-testi — klusteri + tunneli + migraatio + failover (Vaihe 35).
pub fn runBootTest() void {
    // --- TEST-avain (deterministinen 1..32 — EI tuotantoavain, vaihe 35.x) ---
    var test_key: [tunnel.KEY_LEN]u8 = undefined;
    var ki: usize = 0;
    while (ki < test_key.len) : (ki += 1) test_key[ki] = @intCast(ki + 1);
    // --- Klusteri: A + B liittyvät (sykkeen kera) ---
    var cluster = failover.Cluster.init();
    if (!cluster.join(NODE_A, 0)) {
        log.err("Federate join A failed");
        return;
    }
    log.info("Node A joined");
    if (!cluster.join(NODE_B, 0)) {
        log.err("Federate join B failed");
        return;
    }
    log.info("Node B joined");
    // --- Tunneli: molemmat vertaiset liitetty (liitos = kernelin päätös) ---
    var tun = tunnel.Tunnel.init(test_key);
    tun.addPeer(NODE_A) catch {
        log.err("Federate peer A failed");
        return;
    };
    tun.addPeer(NODE_B) catch {
        log.err("Federate peer B failed");
        return;
    };
    // --- Replikasuunnitelma uptime-palvelulle (koti A, vara B) ---
    var replica = failover.ReplicaPlan.init(NODE_A, NODE_B);
    if (!replica.valid()) {
        log.err("Federate replica invalid");
        return;
    }
    // --- Välittäjä puhtaaksi ---
    var fwd = forwarder.Forwarder.init();

    // --- Lataa plugin PA (A:n uptime, grant-scope migraation lähde) ---
    const raw_a = dispatch.invoke(abi.SYS_plugin_load, loader.PLUGIN_EMBEDDED_ID, 1, scope.MASK_SEND, scope.TYPE_PORT | scope.TYPE_MEMORY, scope.MASK_SEND | scope.MASK_RECV | scope.MASK_GRANT | scope.MASK_READ | scope.MASK_MAP, 4);
    if (raw_a <= 1) {
        log.err("Federate load A failed");
        return;
    }
    const pid_a: u64 = @intCast(raw_a);

    // --- Jaettu jatkuvuusportti (omistaja BOOT → selviää A:n purusta) ---
    const shared_port = port.createPort() orelse {
        log.err("Federate shared port failed");
        _ = loader.unloadPlugin(pid_a);
        return;
    };
    const shared_obj = cap.createObject(.port, process.BOOT_PID, shared_port) orelse {
        log.err("Federate shared object failed");
        _ = loader.unloadPlugin(pid_a);
        return;
    };
    const boot_slot = cap.installSlotForPid(process.BOOT_PID, shared_obj, .{ .read = true, .send = true }) orelse {
        log.err("Federate boot slot failed");
        _ = loader.unloadPlugin(pid_a);
        return;
    };
    if (cap.installSlotForPid(pid_a, shared_obj, .{ .read = true, .recv = true }) == null) {
        log.err("Federate plugin slot failed");
        _ = loader.unloadPlugin(pid_a);
        return;
    }

    // --- A:n oma grant-cap (migroitavan tilan sijainen — stateless-rajoite) ---
    const demo_port = port.createPort() orelse {
        log.err("Federate demo port failed");
        _ = loader.unloadPlugin(pid_a);
        return;
    };
    const demo_rights = cap.Rights{ .read = true, .send = true, .recv = true, .grant = true };
    const demo_obj = cap.createObject(.port, pid_a, demo_port) orelse {
        log.err("Federate demo object failed");
        _ = loader.unloadPlugin(pid_a);
        return;
    };
    const demo_slot = cap.installSlotForPid(pid_a, demo_obj, demo_rights) orelse {
        log.err("Federate demo slot failed");
        _ = loader.unloadPlugin(pid_a);
        return;
    };

    // --- Migraatiosuunnitelma: PA lähteestä A kohteeseen B ---
    var plan = migrate.MigrationPlan.init();
    plan.stage(pid_a, NODE_A, NODE_B) catch {
        log.err("Federate stage failed");
        _ = loader.unloadPlugin(pid_a);
        return;
    };

    // --- Lataa plugin PB (B:n replika, recv-scope, ei grantia) ---
    const raw_b = dispatch.invoke(abi.SYS_plugin_load, loader.PLUGIN_EMBEDDED_ID, 1, scope.MASK_RECV, scope.TYPE_PORT, scope.MASK_SEND | scope.MASK_RECV | scope.MASK_READ, 4);
    if (raw_b <= 1) {
        log.err("Federate load B failed");
        _ = loader.unloadPlugin(pid_a);
        return;
    }
    const pid_b: u64 = @intCast(raw_b);
    if (cap.installSlotForPid(pid_b, shared_obj, .{ .read = true, .recv = true }) == null) {
        log.err("Federate B shared slot failed");
        _ = loader.unloadPlugin(pid_b);
        _ = loader.unloadPlugin(pid_a);
        return;
    }

    // --- Tunnelityöntö: sulje (A) → loopback-johto → avaa (B) ---
    const sealed = tun.sealNext(NODE_A, pid_a, demo_slot, NODE_B, scope.MASK_RECV | scope.MASK_READ);
    // Johto on loopback-kopio (TCP-vaihdoke F-L1 — tavut kulkevat tässä).
    var wire = sealed;
    const opened = tun.open(&wire) catch {
        log.err("Federate tunnel open failed");
        _ = loader.unloadPlugin(pid_b);
        _ = loader.unloadPlugin(pid_a);
        return;
    };
    // Tuple-kentät täsmäävät suljettuun (ei matkalla vaihtunut).
    if (opened.src_node != NODE_A or opened.dest_node != NODE_B or
        opened.src_pid != pid_a or opened.src_slot != demo_slot)
    {
        log.err("Federate tuple mismatch");
        _ = loader.unloadPlugin(pid_b);
        _ = loader.unloadPlugin(pid_a);
        return;
    }
    // Negatiivi 1: saman kuoren uusinta → Replay (ikkuna ei etene hylkäyksellä).
    if (tun.open(&wire)) |_| {
        log.err("Federate replay accepted");
        _ = loader.unloadPlugin(pid_b);
        _ = loader.unloadPlugin(pid_a);
        return;
    } else |e| {
        if (e != error.Replay) {
            log.err("Federate replay wrong error");
            _ = loader.unloadPlugin(pid_b);
            _ = loader.unloadPlugin(pid_a);
            return;
        }
    }
    // Negatiivi 2: peukaloitu oikeusmaski → BadMac.
    var evil = wire;
    evil.grant.rights_mask ^= scope.MASK_SEND;
    if (tun.open(&evil)) |_| {
        log.err("Federate tamper accepted");
        _ = loader.unloadPlugin(pid_b);
        _ = loader.unloadPlugin(pid_a);
        return;
    } else |e| {
        if (e != error.BadMac) {
            log.err("Federate tamper wrong error");
            _ = loader.unloadPlugin(pid_b);
            _ = loader.unloadPlugin(pid_a);
            return;
        }
    }
    // Negatiivi 3: liittymätön haamu → UnknownPeer (MAC olisi validi).
    const ghost = tun.sealNext(NODE_GHOST, pid_a, demo_slot, NODE_B, scope.MASK_RECV);
    var ghost_wire = ghost;
    if (tun.open(&ghost_wire)) |_| {
        log.err("Federate ghost accepted");
        _ = loader.unloadPlugin(pid_b);
        _ = loader.unloadPlugin(pid_a);
        return;
    } else |e| {
        if (e != error.UnknownPeer) {
            log.err("Federate ghost wrong error");
            _ = loader.unloadPlugin(pid_b);
            _ = loader.unloadPlugin(pid_a);
            return;
        }
    }

    // --- Valtuutettu asennus: todettu tuple gatewayn läpi (MAC ≠ lupa) ---
    const got_b = gateway.gatewayTransfer(pid_a, demo_slot, pid_b, scope.MASK_RECV | scope.MASK_READ) orelse {
        log.err("Federate gateway failed");
        _ = loader.unloadPlugin(pid_b);
        _ = loader.unloadPlugin(pid_a);
        return;
    };
    // Live-viesti A→B siirretyllä capilla (tunnelin hyötykuynti).
    const ping = "FED1";
    if (!process.setCurrentPid(pid_a)) {
        log.err("Federate switch A failed");
        _ = loader.unloadPlugin(pid_b);
        _ = loader.unloadPlugin(pid_a);
        return;
    }
    const sent = dispatch.invoke(abi.SYS_ipc_send, demo_slot, @intFromPtr(ping), ping.len, 0, 0, 0);
    _ = process.setCurrentPid(process.BOOT_PID);
    if (sent != ping.len) {
        log.err("Federate send failed");
        _ = loader.unloadPlugin(pid_b);
        _ = loader.unloadPlugin(pid_a);
        return;
    }
    if (!process.setCurrentPid(pid_b)) {
        log.err("Federate switch B failed");
        _ = loader.unloadPlugin(pid_b);
        _ = loader.unloadPlugin(pid_a);
        return;
    }
    var ping_buf: [port.MAX_MSG_SIZE]u8 = undefined;
    const got = dispatch.invoke(abi.SYS_ipc_recv, got_b, @intFromPtr(&ping_buf), ping_buf.len, 0, 0, 0);
    _ = process.setCurrentPid(process.BOOT_PID);
    if (got != ping.len) {
        log.err("Federate recv failed");
        _ = loader.unloadPlugin(pid_b);
        _ = loader.unloadPlugin(pid_a);
        return;
    }

    // --- Välittäjäreitti B:hen (läpinäkyvä osoitus siirretylle capille) ---
    const route_idx = fwd.register(NODE_B, got_b, scope.MASK_RECV | scope.MASK_READ) catch {
        log.err("Federate route failed");
        _ = loader.unloadPlugin(pid_b);
        _ = loader.unloadPlugin(pid_a);
        return;
    };
    fwd.checkSend(route_idx, ping.len) catch {
        log.err("Federate checkSend failed");
        _ = loader.unloadPlugin(pid_b);
        _ = loader.unloadPlugin(pid_a);
        return;
    };
    // Saapuva kehys reitittyy samaan indeksiin.
    if (fwd.route(NODE_B, got_b) != route_idx) {
        log.err("Federate route mismatch");
        _ = loader.unloadPlugin(pid_b);
        _ = loader.unloadPlugin(pid_a);
        return;
    }
    // Tuntematon reitti → hylkää (fail-closed).
    if (fwd.route(NODE_GHOST, got_b) != null) {
        log.err("Federate ghost routed");
        _ = loader.unloadPlugin(pid_b);
        _ = loader.unloadPlugin(pid_a);
        return;
    }

    // --- Työntö valmis (1/1 siltaa) → aja B → palautettu ---
    plan.notePushed(1, 1) catch {
        log.err("Federate push failed");
        _ = loader.unloadPlugin(pid_b);
        _ = loader.unloadPlugin(pid_a);
        return;
    };
    if (!loader.runPlugin(pid_b)) {
        log.err("Federate run B failed");
        _ = loader.unloadPlugin(pid_b);
        _ = loader.unloadPlugin(pid_a);
        return;
    }
    plan.noteRestored() catch {
        log.err("Federate restore failed");
        _ = loader.unloadPlugin(pid_b);
        _ = loader.unloadPlugin(pid_a);
        return;
    };
    // Vara palvelee nyt (replika-seuranta migraatiosta).
    replica.noteServing(pid_b);
    // --- Lähde tyhjenee: pura A → migraatio valmis ---
    if (!loader.unloadPlugin(pid_a)) {
        log.err("Federate unload A failed");
        _ = loader.unloadPlugin(pid_b);
        return;
    }
    plan.finish() catch {
        log.err("Federate finish failed");
        _ = loader.unloadPlugin(pid_b);
        return;
    };
    log.info("Uptime plugin migrated A->B");

    // --- Jatkuvuus migraation yli: BOOT lähettää jaettuun, B vastaanottaa ---
    const cont = "FED3";
    const healed_slot = findSlotByObject(pid_b, shared_obj) orelse {
        log.err("Federate shared slot lost");
        _ = loader.unloadPlugin(pid_b);
        return;
    };
    const sent2 = dispatch.invoke(abi.SYS_ipc_send, @intCast(boot_slot), @intFromPtr(cont), cont.len, 0, 0, 0);
    if (sent2 != cont.len) {
        log.err("Federate continuity send failed");
        _ = loader.unloadPlugin(pid_b);
        return;
    }
    if (!process.setCurrentPid(pid_b)) {
        log.err("Federate switch healed failed");
        _ = loader.unloadPlugin(pid_b);
        return;
    }
    var cont_buf: [port.MAX_MSG_SIZE]u8 = undefined;
    const got2 = dispatch.invoke(abi.SYS_ipc_recv, healed_slot, @intFromPtr(&cont_buf), cont_buf.len, 0, 0, 0);
    _ = process.setCurrentPid(process.BOOT_PID);
    if (got2 != cont.len) {
        log.err("Federate continuity recv failed");
        _ = loader.unloadPlugin(pid_b);
        return;
    }

    // --- Failover: B sykkii, A vanhenee → sweep toteaa → vara ylenee ---
    _ = cluster.heartbeat(NODE_B, 950);
    const dead_n = cluster.sweep(1000, HEARTBEAT_TIMEOUT);
    if (dead_n != 1 or cluster.isAlive(NODE_A)) {
        log.err("Federate sweep missed A");
        _ = loader.unloadPlugin(pid_b);
        return;
    }
    log.info("Node A left");
    if (replica.promoteOnLoss(NODE_A, cluster.isAlive(NODE_A), cluster.isAlive(NODE_B)) != .replicated) {
        log.err("Federate promote failed");
        _ = loader.unloadPlugin(pid_b);
        return;
    }
    log.info("Failover: uptime plugin replicated on B");

    // --- Siivous: pura B, poista vertaiset, reitti ja jaettu objekti ---
    if (!loader.unloadPlugin(pid_b)) {
        log.err("Federate unload B failed");
        return;
    }
    _ = tun.removePeer(NODE_A);
    _ = tun.removePeer(NODE_B);
    _ = fwd.unregister(route_idx);
    _ = cluster.leave(NODE_B);
    _ = cap.revokeObject(shared_obj);
    // Klusteri tyhjä, ei orpoja plugineja.
    if (loader.isPlugin(pid_a) or loader.isPlugin(pid_b)) {
        log.err("Federate plugin survived");
        return;
    }
    // Federaatio päästä päähän OK.
    log.info("Federated cluster OK");
}
