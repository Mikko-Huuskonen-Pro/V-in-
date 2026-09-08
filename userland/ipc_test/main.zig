//! IPC userland boot-testi — ipc.zig send/recv roundtrip ring 3:ssa.
//!
//! **Vastuu**: Testaa ipc.zig send ja recv kernelin antamalla capability-slotilla.
//! **Riippuvuudet**: `ipc`, `syscall.zig`
//! **Käytetään**: start.S → ipcMain

// Tuo userland IPC-kirjasto.
const ipc = @import("ipc");
// Tuo syscall wrapperit tulostukseen ja paluuseen.
const sc = @import("syscall.zig");

// Kiinteä .capboot-osoite — kernel kirjoittaa portti-slotin ennen ring 3 -hyppyä.
const IPC_PARENT_SLOT_VADDR: u64 = 0xFFFFFFFF90061000;

// IPC-testin sisäänkäynti — start.S kutsuu tätä.
export fn ipcMain() void {
    // Portti-capabilityn slotti — kernel ipc_userland kirjoittaa .capboot:iin.
    const slot = @as(*const u32, @ptrFromInt(IPC_PARENT_SLOT_VADDR)).*;
    // Jos slotti puuttuu, send/recv epäonnistuu varmasti.
    if (slot == 0) {
        // Boot-info puuttuu.
        sc.print("ipc boot slot missing\n");
        // Palaa kerneliin.
        sc.sysTestReturn();
    }
    // Lähetettävä testiviesti.
    const msg = "IPC";
    // Lähetä ipc-kirjaston send()-funktiolla.
    _ = ipc.send(slot, msg) catch {
        // Send epäonnistui.
        sc.print("ipc send failed\n");
        // Palaa kerneliin.
        sc.sysTestReturn();
    };
    // Vastaanottopuskuri pinossa.
    var buf: [ipc.MAX_MSG_SIZE]u8 = undefined;
    // Vastaanota ipc-kirjaston recv()-funktiolla.
    const got = ipc.recv(slot, &buf) catch {
        // Recv epäonnistui.
        sc.print("ipc recv failed\n");
        // Palaa kerneliin.
        sc.sysTestReturn();
    };
    // Varmista pituus.
    if (got != msg.len) {
        // Väärä vastaanotettu pituus.
        sc.print("ipc len mismatch\n");
        // Palaa kerneliin.
        sc.sysTestReturn();
    }
    // Vertaa sisältö tavu kerrallaan.
    var i: usize = 0;
    while (i < msg.len) : (i += 1) {
        // Jos tavu ei täsmää.
        if (buf[i] != msg[i]) {
            // Sisältövirhe.
            sc.print("ipc payload mismatch\n");
            // Palaa kerneliin.
            sc.sysTestReturn();
        }
    }
    // Vahvistus serialiin ennen paluuta.
    sc.print("userland ipc OK\n");
    // Palaa kerneliin — kernel lokittaa "Userland IPC test OK".
    sc.sysTestReturn();
}

// Pakota linkittäjän säilyttämään ipcMain.
pub export fn ipcAnchor() void {}
