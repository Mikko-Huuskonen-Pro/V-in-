//! Plugin-hallinta — sandbox-scopen boot-testi (Vaihe 29).
//!
//! **Vastuu**: Verifioi scope-eristys bootissa ennen scheduleria.
//! **Riippuvuudet**: `scope.zig`, `../ipc/capability_core.zig`, `../sched/process_core.zig`, log
//! **Käytetään**: `boot_tests.zig::runAll()`

// Tuo puhdas scope-logiikka.
const scope = @import("scope.zig");
// Tuo capability-ydin maski-vertailuun.
const cap = @import("../ipc/capability_core.zig");
// Tuo prosessitaulukko eristys-tarkistukseen (Vaihe 25 page_table).
const process = @import("process_core");
// Tuo lokitus boot-viesteihin.
const log = @import("../lib/log.zig");

// Boot-testi — scope sallii manifestin rajat, estää eskalaation ja vaatii eristyksen.
pub fn runBootTest() void {
    // Rakenna esimerkki-plugin-scope: portti + muisti, send/recv/map, max 4.
    const sc = scope.initScope(42, scope.TYPE_PORT | scope.TYPE_MEMORY, scope.MASK_SEND | scope.MASK_RECV | scope.MASK_MAP | scope.MASK_READ, 4);
    // Scope pitää olla validi.
    if (!scope.validate(sc)) {
        // Scope-rakenne virheellinen.
        log.err("Plugin scope invalid");
        // Lopeta testi.
        return;
    }
    // Portti-tyyppi (ABI 1) sallittu.
    if (!scope.allowsType(sc, 1)) {
        // Portti pitäisi sallia.
        log.err("Plugin scope port denied");
        // Lopeta testi.
        return;
    }
    // Muisti-tyyppi (ABI 5) sallittu.
    if (!scope.allowsType(sc, 5)) {
        // Muisti pitäisi sallia.
        log.err("Plugin scope memory denied");
        // Lopeta testi.
        return;
    }
    // IRQ-tyyppi (ABI 3) ei sallittu tässä scopessa.
    if (scope.allowsType(sc, 3)) {
        // IRQ ei pitäisi läpäistä.
        log.err("Plugin scope leaked irq");
        // Lopeta testi.
        return;
    }
    // Send+recv maski scopen sisällä.
    if (!scope.allowsRights(sc, scope.MASK_SEND | scope.MASK_RECV)) {
        // Odotetut oikeudet puuttuvat.
        log.err("Plugin scope rights denied");
        // Lopeta testi.
        return;
    }
    // Grant-oikeus ei sallittu tässä scopessa.
    if (scope.allowsRights(sc, scope.MASK_GRANT)) {
        // Grant-eskalointi vuoti.
        log.err("Plugin scope leaked grant");
        // Lopeta testi.
        return;
    }
    // Luonti sallittu kun määräraja ei täynnä.
    if (!scope.allowsCreate(sc, 1, scope.MASK_SEND, 0)) {
        // Luonti pitäisi sallia.
        log.err("Plugin scope create denied");
        // Lopeta testi.
        return;
    }
    // Luonti estetty kun määräraja täynnä (4/4).
    if (scope.allowsCreate(sc, 1, scope.MASK_SEND, 4)) {
        // Katto vuoti.
        log.err("Plugin scope cap limit leaked");
        // Lopeta testi.
        return;
    }
    // Sama tarkistus capability_core-puolella (Rights-rakenteella).
    const rights: cap.Rights = .{ .send = true, .recv = true };
    // Portti + send/recv sallittu molemmissa kerroksissa.
    if (!cap.scopeAllows(sc.allowed_types, sc.allowed_rights, .port, rights)) {
        // Kerrokset eri mieltä — layout-bugi.
        log.err("Plugin scope core mismatch");
        // Lopeta testi.
        return;
    }
    // Grant-oikeus estetty capability_core-kerroksessa.
    const evil: cap.Rights = .{ .send = true, .grant = true };
    // Evil-oikeus ei saa läpäistä.
    if (cap.scopeAllows(sc.allowed_types, sc.allowed_rights, .port, evil)) {
        // Eskalaatio läpäisi kernel-kerroksen.
        log.err("Plugin scope evil grant allowed");
        // Lopeta testi.
        return;
    }
    // Eristys: nolla-sivutaulu ei kelpaa pluginille.
    if (scope.isIsolated(0)) {
        // Jaettu taulu näyttäytyi eristettynä.
        log.err("Plugin isolation fake pass");
        // Lopeta testi.
        return;
    }
    // Eristys: ei-nolla PML4 kelpaa (Vaihe 25 per-process taulu).
    if (!scope.isIsolated(0x1000)) {
        // Oma taulu hylättiin.
        log.err("Plugin isolation denied");
        // Lopeta testi.
        return;
    }
    // Prosessitaulukko toimii scope-pidin kanssa (ei kaadu).
    _ = process.exists(sc.plugin_pid);
    // Kaikki scope-eristysrajat OK.
    log.info("Plugin scope OK");
    // Sandbox-malli kokonaisuutena OK (scope + eristys + maskit).
    log.info("Plugin sandbox OK");
}
