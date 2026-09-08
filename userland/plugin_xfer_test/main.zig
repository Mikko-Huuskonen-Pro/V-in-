//! Plugin transfer userland-testi — sys_plugin_transfer ring 3:ssa (Vaihe 31.3).
//!
//! **Vastuu**: Lue siirtoparametrit .capboot-boot-infosta, aja gateway-siirto
//!   syscallilla kutsujana lähdeplugin itse, vahvista serialiin.
//! **Riippuvuudet**: `pxfer` (plugin_transfer-lib), `syscall.zig`
//! **Käytetään**: start.S → xferMain (kernel ajaa pluginin pidillä)

// Tuo plugin-transfer-kirjasto — transfer() + maskit.
const pxfer = @import("pxfer");
// Tuo syscall-apu — print + sysTestReturn.
const sc = @import("syscall.zig");

// Boot-info-osoite — kernel kirjoittaa parametrit ennen ring 3 -hyppyä
// (user.ld .capboot, symboli xferBootInfo @ 0xFFFFFFFF90093000, nm:llä varmistettu).
// Layout: [0]=src_pid u64, [1]=src_slot u64, [2]=dest_pid u64, [3]=mask u64.
const XFER_BOOT_VADDR: u64 = 0xFFFFFFFF90093000;

// Siirtotestin sisäänkäynti — start.S kutsuu tätä.
export fn xferMain() void {
    // Lue parametrit kernelin kirjoittamasta boot-infosta.
    const params = @as(*const [4]u64, @ptrFromInt(XFER_BOOT_VADDR)).*;
    // Lähdepluginin pid (pitäisi olla oma pid).
    const src_pid = params[0];
    // Lähdeslotti omassa nimiavaruudessa.
    const src_slot: u32 = @intCast(params[1]);
    // Kohdepluginin pid.
    const dest_pid = params[2];
    // Siirrettävä oikeusmaski.
    const mask: u32 = @intCast(params[3]);
    // Aja gateway-siirto syscallilla — kutsuja on lähde itse.
    const dest_slot = pxfer.transfer(src_pid, src_slot, dest_pid, mask) catch {
        // Portti kiinni (tai muu kernel-virhe).
        sc.print("pxfer failed\n");
        // Palaa kerneliin.
        sc.sysTestReturn();
    };
    // Siirto onnistui — kohdeslotti talteen (ei tulosteta numeroa, vakaa loki).
    _ = dest_slot;
    // Vahvistus serialiin ennen paluuta.
    sc.print("pxfer OK\n");
    // Palaa kerneliin — kernel verifioi kohteen slotin + viestin.
    sc.sysTestReturn();
}

// Pakota linkittäjän säilyttämään xferMain.
pub export fn xferAnchor() void {}
