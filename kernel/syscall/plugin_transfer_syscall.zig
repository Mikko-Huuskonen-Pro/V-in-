//! Plugin transfer boot-testi — sys_plugin_transfer + gateway end-to-end (Vaihe 31).
//!
//! **Vastuu**: Varmista gateway-siirto syscall-polun läpi: manifestin caps-lista,
//!   negatiiviset portinvartija-tapaukset, P31-viesti pluginista toiseen, ajo.
//! **Riippuvuudet**: `dispatch.zig`, `../plugin/ns_map.zig`, `../plugin/loader.zig`,
//!   `../plugin/scope.zig`, `../plugin/manifest.zig`, `../ipc/capability_core.zig`,
//!   `../ipc/port.zig`, `process_core`, log
//! **Käytetään**: `kernel/boot_tests.zig`
//!
//! ## Arkkitehtuurihuomiot
//! - Positiivinen siirto ajetaan syscallin läpi kutsujana lähdeplugin itse —
//!   todistaa että ABI (RAX=26) kantaa gatewaylle asti, ei vain suora kutsu.
//! - Negatiivit (haamu, vieras, eskalaatio) ajetaan osin suorina gateway-
//!   kutsuina: ne todistavat portinvartija-päätöksen, eivät ABI-kuljetusta.

// Tuo jaettu ABI — SYS_plugin_transfer + virhekoodit.
const abi = @import("zinuxabi");
// Tuo dispatch — invoke() ilman ring 3:a (load/unload/transfer/send/recv).
const dispatch = @import("dispatch.zig");
// Tuo gateway — suorat portinvartija-kutsut negatiiveihin.
const gateway = @import("../plugin/ns_map.zig");
// Tuo plugin-loader — isPlugin/runPlugin + PLUGIN_EMBEDDED_ID.
const loader = @import("../plugin/loader.zig");
// Tuo scope — maskivakiot testin scopeihin.
const scope = @import("../plugin/scope.zig");
// Tuo manifesti — 31.2 caps-listan latausajan valvonta.
const manifest = @import("../plugin/manifest.zig");
// Tuo capability-ydin — portti-capin asennus plugin A:lle.
const cap = @import("../ipc/capability_core.zig");
// Tuo portit — gateway-testin IPC-portti + viestikoko.
const port = @import("../ipc/port.zig");
// Tuo ELF-loader — xfer-testin PT_LOAD A:n sivutauluun.
const elf = @import("../loader/elf.zig");
// Tuo VMM — kohde-PML4 + physToVirt boot-info-kirjoitukseen.
const vmm = @import("../mm/vmm.zig");
// Tuo paging — getPteRaw kohdesivun resolvointiin.
const paging = @import("../arch/x86_64/paging.zig");
// Tuo user_access — stac/clac SMAP-yhteensopivuuteen user-sivuille.
const user_access = @import("../arch/x86_64/user_access.zig");
// Tuo ring 3 siirtymä — xfer-ajon iretq A:n pidillä.
const usermode = @import("../arch/x86_64/usermode.zig");
// Tuo prosessitaulukko — currentPid/BOOT_PID + kontekstinvaihto.
const process = @import("process_core");
// Tuo lokitus boot-viesteihin.
const log = @import("../lib/log.zig");

// Upotettu siirtotesti-ELF — build.zig kopioi userland/plugin_xfer_test ennen käännöstä.
// Polku kernel/syscall-hakemistosta (vrt. loader/elf.zig:n upotukset).
const xfer_test_elf = @embedFile("../loader/plugin_xfer_test_prog.bin");

// Siirtotestin pinon heap-slot — vapaa väli (116 plugin, muut varatut).
const XFER_TEST_STACK_SLOT: u64 = 117;
// Siirtotestin .capboot-osoite — parametrit src_pid/slot/dest/mask (nm:llä varmistettu).
const XFER_BOOT_VADDR: u64 = 0xFFFFFFFF90093000;

// Boot-testi — 31.2 caps-listan valvonta + 31.1/31.3 gateway-siirto syscallin läpi.
pub fn runBootTest() void {
    // --- 31.2: monen capin manifestin valvonta lataushetkellä ---
    // Kahden capin vaatimuslista (port/send + memory/map).
    const reqs = [_]manifest.CapReq{
        // Portti send/recv-oikeuksin.
        .{ .cap_type = 1, .rights_mask = scope.MASK_SEND | scope.MASK_RECV },
        // Muisti map/read-oikeuksin.
        .{ .cap_type = 5, .rights_mask = scope.MASK_MAP | scope.MASK_READ },
    };
    // Väljä scope molemmille capeille, katto 2.
    const roomy = scope.initScope(77, scope.TYPE_PORT | scope.TYPE_MEMORY, scope.MASK_SEND | scope.MASK_RECV | scope.MASK_MAP | scope.MASK_READ, 2);
    // Koko lista läpäisee valvonnan.
    if (!manifest.enforceCapsAtLoad(roomy, &reqs, 0)) {
        // Kaksicapinen manifesti hylättiin aiheettomasti.
        log.err("Plugin manifest caps denied");
        // Lopeta testi.
        return;
    }
    // Tiukka katto (1) — toinen cap ei mahdu.
    const tight = scope.initScope(77, scope.TYPE_PORT | scope.TYPE_MEMORY, scope.MASK_SEND | scope.MASK_RECV | scope.MASK_MAP | scope.MASK_READ, 1);
    // Katto estää toisen capin.
    if (manifest.enforceCapsAtLoad(tight, &reqs, 0)) {
        // Määräraja vuoti.
        log.err("Plugin manifest caps ceiling leaked");
        // Lopeta testi.
        return;
    }
    // Eskalaatio: grant-pyyntö scopella ilman grantia.
    const evil = [_]manifest.CapReq{
        // Grant-oikeus porttiin.
        .{ .cap_type = 1, .rights_mask = scope.MASK_GRANT },
    };
    // Grant-eskalointi estetty.
    if (manifest.enforceCapsAtLoad(roomy, &evil, 0)) {
        // Grant vuoti scopesulun läpi.
        log.err("Plugin manifest caps grant leaked");
        // Lopeta testi.
        return;
    }
    // Manifestin caps-lista valvottu lataushetkellä.
    log.info("Plugin manifest caps OK");

    // --- 31.1/31.3: lataa kaksi pluginia eri scopeilla ---
    // Plugin A: portti + muisti, grant-mukana (saa avata portin B:lle).
    const raw_a = dispatch.invoke(abi.SYS_plugin_load, loader.PLUGIN_EMBEDDED_ID, 1, scope.MASK_SEND, scope.TYPE_PORT | scope.TYPE_MEMORY, scope.MASK_SEND | scope.MASK_RECV | scope.MASK_GRANT | scope.MASK_READ | scope.MASK_MAP, 4);
    // Varmista positiivinen pid.
    if (raw_a <= 1) {
        // A:n lataus epäonnistui.
        log.err("Plugin gateway load A failed");
        // Lopeta testi.
        return;
    }
    // Plugin A:n pid.
    const pid_a: u64 = @intCast(raw_a);
    // Plugin B: vain portti, ei grantia (ei saa avata kenellekään).
    const raw_b = dispatch.invoke(abi.SYS_plugin_load, loader.PLUGIN_EMBEDDED_ID, 1, scope.MASK_RECV, scope.TYPE_PORT, scope.MASK_SEND | scope.MASK_RECV | scope.MASK_READ, 4);
    // Varmista positiivinen pid.
    if (raw_b <= 1) {
        // B:n lataus epäonnistui.
        log.err("Plugin gateway load B failed");
        // Lopeta testi.
        return;
    }
    // Plugin B:n pid.
    const pid_b: u64 = @intCast(raw_b);

    // --- Negatiivinen: tuntematon pid ei ole nimiavaruus ---
    // Siirto olemattomasta pluginista → null (suora portinvartija-kutsu).
    if (gateway.gatewayTransfer(9999, 0, pid_b, scope.MASK_RECV) != null) {
        // Haamunimiavaruus läpäisi portin.
        log.err("Plugin gateway ghost passed");
        // Lopeta testi.
        return;
    }

    // --- Negatiivinen: vieras kutsuja ei avaa porttia syscallillakaan ---
    // Kolmas osapuoli (ei plugin, ei boot) yrittää A→B-siirtoa syscallilla.
    const stranger = process.allocNextPid() orelse {
        // Vieras-pid ei mahdu taulukkoon.
        log.err("Plugin gateway stranger alloc failed");
        // Lopeta testi.
        return;
    };
    // Vaihda vieraaseen kontekstiin.
    if (!process.setCurrentPid(stranger)) {
        // Kontekstinvaihto epäonnistui.
        log.err("Plugin gateway stranger switch failed");
        // Lopeta testi.
        return;
    }
    // Vieraan syscall → EPERM (juuri init-pidissä, ei vieraassa).
    const denied = dispatch.invoke(abi.SYS_plugin_transfer, pid_a, 0, pid_b, scope.MASK_RECV, 0, 0);
    // Varmista EPERM eikä slotti.
    if (denied != abi.EPERM) {
        // Vieras avasi portin.
        log.err("Plugin gateway stranger passed");
        // Lopeta testi.
        return;
    }
    // Palauta boot-konteksti.
    if (!process.setCurrentPid(process.BOOT_PID)) {
        // Palautus epäonnistui.
        log.err("Plugin gateway caller restore failed");
        // Lopeta testi.
        return;
    }
    // Siivoa vieras-pid (viimeisin → ei taulukkoaukkoa).
    _ = process.freePid(stranger);

    // --- Gateway-cap A:lle: portti grant-oikeuksin ---
    // Luo fyysinen IPC-portti plugin-viestille.
    const port_id = port.createPort() orelse {
        // Portin luonti epäonnistui.
        log.err("Plugin gateway port create failed");
        // Lopeta testi.
        return;
    };
    // Oikeudet: luku + lähetys + vastaanotto + siirto-oikeus.
    const rights_a = cap.Rights{
        // Lue portin metatiedot.
        .read = true,
        // Lähetä viestejä.
        .send = true,
        // Vastaanota viestejä.
        .recv = true,
        // Siirrä B:lle gatewayn läpi.
        .grant = true,
    };
    // Asenna capability plugin A:lle (kernel auktoriteettina).
    const slot_a = cap.createAndInstall(.port, pid_a, port_id, rights_a) orelse {
        // Asennus A:lle epäonnistui.
        log.err("Plugin gateway cap install A failed");
        // Lopeta testi.
        return;
    };

    // --- Negatiivinen: eskalaatio B:n scopea vasten ---
    // Grant-oikeus B:lle, jonka scopesta grant puuttuu → null.
    if (gateway.gatewayTransfer(pid_a, slot_a, pid_b, scope.MASK_GRANT) != null) {
        // Eskalaatio läpäisi portinvartijan.
        log.err("Plugin gateway escalation passed");
        // Lopeta testi.
        return;
    }

    // --- Ring 3: lähdeplugin ajaa siirron itse syscallilla ---
    // A:n PML4 kohteeksi (xfer-ELF kartoitetaan A:n sivutauluun).
    const pml4_a = process.getPageTable(pid_a) orelse {
        // A:lla ei sivutaulua.
        log.err("Plugin xfer no page table A");
        // Lopeta testi.
        return;
    };
    // Nolla tarkoittaa jaettua taulua — pluginilla pitää olla oma.
    if (pml4_a == 0) {
        // A ei eristetty.
        log.err("Plugin xfer shared table A");
        // Lopeta testi.
        return;
    }
    // Kartoitukset A:n PML4:ään.
    vmm.target_pml4_phys = pml4_a;
    // Lataa xfer-ELF A:n sivutauluun (segmentit + pino slot 117).
    const xfer = elf.loadElfWithStack(xfer_test_elf, XFER_TEST_STACK_SLOT) orelse {
        // Palauta kernelin PML4 ennen paluuta.
        vmm.target_pml4_phys = null;
        // Lataus epäonnistui.
        log.err("Plugin xfer ELF load failed");
        // Lopeta testi.
        return;
    };
    // Boot-info: src_pid/slot/dest/mask .capboot-sivuun HHDM-aliasen kautta.
    // Sivu näkyy vain A:n taulussa — kernel-CR3-kirjoitus faultaisi.
    const boot_raw = paging.getPteRaw(pml4_a, vmm.hhdm(), XFER_BOOT_VADDR) orelse {
        // Palauta kernelin PML4 ennen paluuta.
        vmm.target_pml4_phys = null;
        // Sivu ei kartoitettu.
        log.err("Plugin xfer bootinfo unmapped");
        // Lopeta testi.
        return;
    };
    // Kehyksen HHDM-alias kirjoitukseen.
    const boot_ptr: [*]u64 = @ptrFromInt(vmm.physToVirt(boot_raw & 0x000FFFFFFFFFF000));
    // SMAP: salli user-sivun kirjoitus kernelistä.
    user_access.stac();
    // Lähde-pid (kutsuja itse).
    boot_ptr[0] = pid_a;
    // Lähdeslotti A:n nimiavaruudessa.
    boot_ptr[1] = slot_a;
    // Kohdepluginin pid.
    boot_ptr[2] = pid_b;
    // Siirrettävä maski (sama kuin syscall-polulla alla).
    boot_ptr[3] = scope.MASK_RECV | scope.MASK_READ;
    // Palauta SMAP-suojaus.
    user_access.clac();
    // Takaisin kernelin PML4:ään ennen hyppyä.
    vmm.target_pml4_phys = null;
    // Aja ring 3:ssa A:n pidillä — kutsuja on lähde itse, portti aukeaa.
    usermode.enterUserAs(xfer.entry, xfer.stack_top, pid_a);
    // Paluu sys_test_return:lla — userland tulosti "pxfer OK".
    log.info("Plugin xfer ring3 OK");

    // --- Positiivinen: sama siirto syscallilla kutsujana A ---
    // Ring 3 asensi B:lle jo slotin — S2-dedup palauttaa saman (ei duplikaattia).
    // Vaihda lähteen kontekstiin — syscallin kutsuja on grantin omistaja.
    if (!process.setCurrentPid(pid_a)) {
        // Kontekstinvaihto A:han epäonnistui.
        log.err("Plugin gateway set pid A failed");
        // Lopeta testi.
        return;
    }
    // Siirrä vastaanotto-oikeus B:n nimiavaruuteen syscallin läpi.
    const slot_b_raw = dispatch.invoke(abi.SYS_plugin_transfer, pid_a, slot_a, pid_b, scope.MASK_RECV | scope.MASK_READ, 0, 0);
    // Varmista slottinumero eikä virhe.
    if (slot_b_raw < 0) {
        // Sallittu siirto hylättiin syscallissa.
        log.err("Plugin gateway transfer failed");
        // Lopeta testi.
        return;
    }
    // Kohteen slotti u64:na.
    const slot_b: u32 = @intCast(slot_b_raw);
    // Siirto B:n scope-rajan läpi OK.
    log.info("Plugin gateway transfer OK");
    // Testiviesti plugin A:lta (konteksti yhä A — lähetys samalla).
    const msg = "P31";
    // Lähetä invoke-kautta.
    const sent = dispatch.invoke(abi.SYS_ipc_send, @intCast(slot_a), @intFromPtr(msg), msg.len, 0, 0, 0);
    // Varmista täysi lähetys.
    if (sent != @as(i64, @intCast(msg.len))) {
        // Send A:lta epäonnistui.
        log.err("Plugin gateway send A failed");
        // Lopeta testi.
        return;
    }
    // B vastaanottaa siirretyllä slotillaan (current = B).
    if (!process.setCurrentPid(pid_b)) {
        // Kontekstinvaihto B:hen epäonnistui.
        log.err("Plugin gateway set pid B failed");
        // Lopeta testi.
        return;
    }
    // Vastaanottopuskuri kernel-pinossa.
    var buf: [port.MAX_MSG_SIZE]u8 = undefined;
    // Vastaanota invoke-kautta.
    const got = dispatch.invoke(abi.SYS_ipc_recv, @intCast(slot_b), @intFromPtr(&buf), buf.len, 0, 0, 0);
    // Varmista vastaanotettu pituus.
    if (got != @as(i64, @intCast(msg.len))) {
        // Recv B:ssä epäonnistui.
        log.err("Plugin gateway recv B failed");
        // Lopeta testi.
        return;
    }
    // Vertaa tavut yksi kerrallaan.
    var i: usize = 0;
    while (i < msg.len) : (i += 1) {
        // Jos tavu ei täsmää.
        if (buf[i] != msg[i]) {
            // Sisältövirhe plugin-viestissä.
            log.err("Plugin gateway payload mismatch");
            // Lopeta testi.
            return;
        }
    }
    // Palauta boot-konteksti.
    if (!process.setCurrentPid(process.BOOT_PID)) {
        // Palautus epäonnistui.
        log.err("Plugin gateway boot restore failed");
        // Lopeta testi.
        return;
    }
    // Viesti kulki pluginista toiseen gatewayn läpi.
    log.info("Plugin gateway message OK");
    // Molemmat pluginit elossa ring 3:ssa ("plg" × 2 serialissa).
    if (!loader.runPlugin(pid_a)) {
        // A:n ajo epäonnistui.
        log.err("Plugin gateway run A failed");
        // Lopeta testi.
        return;
    }
    if (!loader.runPlugin(pid_b)) {
        // B:n ajo epäonnistui.
        log.err("Plugin gateway run B failed");
        // Lopeta testi.
        return;
    }
    // Pura B ensin (viimeisin → ei taulukkoaukkoa), sitten A.
    if (dispatch.invoke(abi.SYS_plugin_unload, pid_b, 0, 0, 0, 0, 0) != 0) {
        // B:n purku epäonnistui.
        log.err("Plugin gateway unload B failed");
        // Lopeta testi.
        return;
    }
    if (dispatch.invoke(abi.SYS_plugin_unload, pid_a, 0, 0, 0, 0, 0) != 0) {
        // A:n purku epäonnistui.
        log.err("Plugin gateway unload A failed");
        // Lopeta testi.
        return;
    }
    // Plugin IPC -yhdyskäytävä toimii päästä päähän.
    log.info("Plugin IPC gateway OK");
}
