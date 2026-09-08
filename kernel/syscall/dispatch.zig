//! Syscall dispatch — numerosta handler-funktioon.
//!
//! **Vastuu**: Syscall-taulukko, sys_write/sys_exit stubit.
//! **Riippuvuudet**: `../../libs/zinuxabi.zig`, UART, log
//! **Käytetään**: `arch/x86_64/syscall_entry.S`, `main.zig`

// Tuo jaettu ABI — syscall-numerot ja virhekoodit.
const abi = @import("zinuxabi");
// Tuo UART sys_write-toteutukseen.
const uart = @import("../drivers/char/uart.zig");
// Tuo lokitus boot-testiin.
const log = @import("../lib/log.zig");
// Tuo usermode — ring 3 paluu boot-testiin.
const usermode = @import("../arch/x86_64/usermode.zig");
// Tuo PMM — vapaiden kehysten laskuri meminfo-syscallille.
const pmm = @import("../mm/pmm.zig");
// Tuo kernel heap — kokonaiskoko meminfo-syscallille.
const heap = @import("../mm/heap.zig");
// Tuo user_access — stac/clac SMAP-yhteensopivuuteen.
const user_access = @import("../arch/x86_64/user_access.zig");
// Tuo IPC-portit — sendViaSlot/recvViaSlot capability-tarkistuksella.
const port = @import("../ipc/port.zig");
// Tuo IPC-syscall-ydin — PortError → ABI.
const ipc_core = @import("ipc_syscall_core.zig");
// Tuo estävän recv-ydin — odotusloop ennen uudelleenyritystä.
const ipc_block_core = @import("ipc_block_core.zig");
// Tuo capability-ydin — delegateSlot lookup.
const cap = @import("../ipc/capability_core.zig");
// Tuo capability-syscall-ydin — rights_mask dekoodaus.
const cap_core = @import("cap_syscall_core.zig");
// Tuo prosessitaulukko — current pid getpid-syscallille (Vaihe 20).
const process = @import("process_core");
// Tuo spawn — sys_spawn upotetuista ELF:istä (Vaihe 21).
const spawn = @import("../spawn.zig");
// Tuo ps-ydin — prosessilistan muotoilu sys_ps:lle (Vaihe 23).
const ps_core = @import("ps_syscall_core.zig");
// Tuo wait-ydin — sys_wait parent/child-tarkistus (Vaihe 24).
const wait_core = @import("wait_syscall_core.zig");
// Tuo sys_mem_map syscall-ydin — CapType.memory + mapPageEnsure (Vaihe 28).
const mem_map_core = @import("mem_map_core.zig");
// Tuo plugin-loader — loadPlugin/unloadPlugin + rekisteri (Vaihe 30).
const plugin_loader = @import("../plugin/loader.zig");
// Tuo plugin-manifest-valvonta — buildSingleCapManifest/checkScope (Vaihe 30).
const plugin_manifest = @import("../plugin/manifest.zig");
// Tuo plugin-scope — initScope/validate lataajan biteistä (Vaihe 30).
const plugin_scope = @import("../plugin/scope.zig");
// Tuo plugin IPC -yhdyskäytävä — gatewayTransfer nimiavaruuksien välille (Vaihe 31).
const ns_map = @import("../plugin/ns_map.zig");

// Syscall-käsittelijän funktiotyyppi (6 argumenttia, i64 paluu).
const SyscallFn = *const fn (u64, u64, u64, u64, u64, u64) i64;

// Syscall-kehyksen kuvaus — assembly tallentaa rekisterit ennen C-kutsua.
pub const SyscallFrame = extern struct {
    // Syscall-numero (RAX).
    num: u64,
    // Argumentti 1 (RDI).
    arg1: u64,
    // Argumentti 2 (RSI).
    arg2: u64,
    // Argumentti 3 (RDX).
    arg3: u64,
    // Argumentti 4 (R10).
    arg4: u64,
    // Argumentti 5 (R8).
    arg5: u64,
    // Argumentti 6 (R9).
    arg6: u64,
    // Käyttäjän paluosoite (RCX syscall:in jälkeen).
    user_rip: u64,
    // Käyttäjän RFLAGS (R11 syscall:in jälkeen).
    user_rflags: u64,
};

// sys_write — kirjoita fd:hen (1=stdout UART, 2=stderr UART).
fn sysWrite(a1: u64, a2: u64, a3: u64, _: u64, _: u64, _: u64) i64 {
    // Tiedoston kuvaus (fd).
    const fd = a1;
    // Puskurin osoite (kernel stub: luotetaan osoitteeseen).
    const buf = a2;
    // Kirjoitettavien tavujen määrä.
    const len = a3;
    // Vain stdout/stderr tuettu toistaiseksi.
    if (fd != 1 and fd != 2) return abi.EBADF;
    // Tyhjä kirjoitus on OK.
    if (len == 0) return 0;
    // Osoitin puskuriin tavuina.
    const ptr: [*]const u8 = @ptrFromInt(buf);
    // SMAP: salli user-sivujen luku kernelistä.
    user_access.stac();
    // Kirjoita jokainen tavu UART:iin.
    var i: u64 = 0;
    while (i < len) : (i += 1) {
        // Tulosta yksi merkki serialiin.
        uart.putc(ptr[i]);
    }
    // Palauta SMAP-suojaus.
    user_access.clac();
    // Palauta kirjoitettujen tavujen määrä.
    return @intCast(len);
}

// sys_read — lue fd:stä (0=stdin UART + injektorirengas).
fn sysRead(a1: u64, a2: u64, a3: u64, _: u64, _: u64, _: u64) i64 {
    // Tiedoston kuvaus (vain stdin tuettu).
    const fd = a1;
    // Puskurin osoite ring 3:ssa.
    const buf = a2;
    // Luettavien tavujen enimmäismäärä.
    const len = a3;
    // Vain stdin (fd 0) tuettu toistaiseksi.
    if (fd != 0) return abi.EBADF;
    // Tyhjä luku on OK.
    if (len == 0) return 0;
    // Osoitin puskuriin tavuina.
    const ptr: [*]u8 = @ptrFromInt(buf);
    // SMAP: salli user-sivujen kirjoitus kernelistä.
    user_access.stac();
    // Lue tavuja kunnes puskuri täynnä.
    var i: u64 = 0;
    while (i < len) : (i += 1) {
        // Blokkaava luku rengasjonosta tai UART:ista.
        ptr[i] = uart.readc();
        // Lopeta rivin lopussa (shell-komento valmis).
        if (ptr[i] == '\n') {
            // Palauta SMAP-suojaus ennen paluuta.
            user_access.clac();
            // Palauta luettujen tavujen määrä mukaan lukien newline.
            return @intCast(i + 1);
        }
    }
    // Palauta SMAP-suojaus.
    user_access.clac();
    // Puskuri täynnä ilman newlinea.
    return @intCast(len);
}

// sys_exit — merkitse prosessi zombieksi ja palaa kerneliin ring 3:sta (Vaihe 24).
fn sysExit(a1: u64, _: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    // Exit status-koodi (u32).
    const code: u32 = @truncate(a1);
    // Ring 3 polku — käytä enterUserAs:ssa tallennettua pid:ä (varmuus currentPid:lle).
    if (usermode.usermode_saved_kernel_rsp != 0) {
        // Synkronoi current pid ennen zombie-merkintää.
        _ = process.setCurrentPid(usermode.activeRing3Pid());
    }
    // Nykyinen prosessi lopettaa itsensä.
    const pid = process.currentPid();
    // Merkitse zombie — virhe jos jo zombie tai puuttuu.
    if (!process.markZombie(pid, code)) return abi.ESRCH;
    // Ring 3 kontekstista palaa spawn boot-testiin (kuten sys_test_return).
    if (usermode.usermode_saved_kernel_rsp != 0) {
        // Ei paluuta — hyppää takaisin kernel-pinolle.
        usermode.returnToKernelTestContinue();
    }
    // Kernel invoke -polku — ei pitäisi tapahtua boot-testissä.
    asm volatile ("cli; hlt");
    // Ei saavuteta.
    unreachable;
}

// Callback wait_core:lle — onko prosessi olemassa.
fn waitExists(pid: u64) bool {
    // Delegoi process_core.exists.
    return process.exists(pid);
}

// Callback wait_core:lle — vanhemman pid.
fn waitParentOf(pid: u64) ?u64 {
    // Delegoi process_core.parentPid.
    return process.parentPid(pid);
}

// Callback wait_core:lle — onko zombie.
fn waitIsZombie(pid: u64) bool {
    // Delegoi process_core.isZombie.
    return process.isZombie(pid);
}

// Callback wait_core:lle — exit-koodi.
fn waitExitCode(pid: u64) ?u32 {
    // Delegoi process_core.exitCode.
    return process.exitCode(pid);
}

// sys_wait — odota yhden lapsen zombie-tila ja palauta exit-koodi (Vaihe 24).
fn sysWait(a1: u64, _: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    // Odotettavan lapsen prosessitunniste.
    const child_pid = a1;
    // Nykyinen prosessi on vanhempi.
    const parent_pid = process.currentPid();
    // Delegoi wait-ytimelle — ECHILD/ESRCH/EAGAIN tai exit-koodi.
    return wait_core.tryWaitChild(
        parent_pid,
        child_pid,
        waitExists,
        waitParentOf,
        waitIsZombie,
        waitExitCode,
    );
}

// sys_getpid — palauta nykyisen prosessin tunniste.
fn sysGetpid(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    // Delegoi prosessitaulukon current pid:lle.
    return @intCast(process.currentPid());
}

// sys_spawn — luo uusi prosessi upotetusta ELF-tunnisteesta (Vaihe 21).
fn sysSpawn(a1: u64, _: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    // Embedded ELF -tunniste (0 = lapsi A, 1 = lapsi B).
    const embedded_id = a1;
    // Lataa ELF uudelle pid:lle prosessitaulukkoon.
    const pid = spawn.spawnEmbedded(embedded_id) orelse return abi.EINVAL;
    // Palauta uuden prosessin tunniste.
    return @intCast(pid);
}

// sys_cap_transfer — siirrä capability toiselle prosessille (Vaihe 22).
fn sysCapTransfer(a1: u64, a2: u64, a3: u64, _: u64, _: u64, _: u64) i64 {
    // Lähde capability-slotti nykyisessä prosessissa.
    const src_slot: u32 = @intCast(a1);
    // Kohdeprosessin tunniste.
    const dest_pid = a2;
    // Siirrettävät oikeudet bitmaskina.
    const mask: u32 = @intCast(a3);
    // Dekoodaa maski → Rights (hylkää varatut bitit).
    const new_rights_raw = cap_core.rightsFromMask(mask) orelse return abi.EINVAL;
    // Muunna cap_syscall_core.Rights → capability_core.Rights.
    const new_rights: cap.Rights = @bitCast(new_rights_raw);
    // Siirrä slotti kohdeprosessiin — grant vaaditaan lähde-slotissa.
    const derived = cap.transferSlotToPid(src_slot, dest_pid, new_rights) orelse return abi.EPERM;
    // Palauta uuden slotin indeksi kohdeprosessissa.
    return @intCast(derived);
}

// sys_test_return — palaa kernel boot-testiin ring 3:sta (Vaihe 4.5).
fn sysTestReturn(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    // Vaihda boot-pinon osoitteeseen ja hyppää runBootTest-jatkoon.
    usermode.returnToKernelTestContinue();
}

// Kopioi literaali kernel-puskuriin — palauttaa uusi offset.
fn appendLiteral(buf: []u8, offset: usize, text: []const u8) usize {
    // Nykyinen kirjoituskohta.
    var pos = offset;
    // Kopioi jokainen merkki jos mahtuu.
    for (text) |c| {
        // Puskuri täynnä — lopeta.
        if (pos >= buf.len) break;
        // Tallenna merkki.
        buf[pos] = c;
        // Siirry eteenpäin.
        pos += 1;
    }
    // Palauta uusi offset.
    return pos;
}

// Kirjoita desimaaliluku kernel-puskuriin — palauttaa uusi offset.
fn appendDecimal(buf: []u8, offset: usize, val: usize) usize {
    // Nollatapaus erikseen.
    if (val == 0) {
        // Yksi nollamerkki jos mahtuu.
        if (offset < buf.len) buf[offset] = '0';
        // Palauta offset + 1 tai sama jos täynnä.
        return if (offset < buf.len) offset + 1 else offset;
    }
    // Väliaikainen numeropuskuri käänteisessä järjestyksessä.
    var digits: [20]u8 = undefined;
    // Montako numeroa kerätty.
    var dlen: usize = 0;
    // Jäännös jakoa varten.
    var n = val;
    // Kerää numerot.
    while (n > 0) : (n /= 10) {
        // ASCII-numero jäännöksestä.
        digits[dlen] = @truncate('0' + (n % 10));
        // Kasvata pituus.
        dlen += 1;
    }
    // Nykyinen offset.
    var pos = offset;
    // Tulosta numerot oikeassa järjestyksessä.
    while (dlen > 0) {
        // Vähennä ennen tulostusta.
        dlen -= 1;
        // Puskuri täynnä — lopeta.
        if (pos >= buf.len) break;
        // Kopioi numero.
        buf[pos] = digits[dlen];
        // Siirry eteenpäin.
        pos += 1;
    }
    // Palauta uusi offset.
    return pos;
}

// Kopioi kernel-puskuri käyttäjän osoitteeseen — palauttaa kopioitujen tavujen määrä.
fn copyToUser(user: [*]u8, user_len: u64, kernel_buf: []const u8, kernel_len: usize) i64 {
    // Tyhjä kopiointi on OK.
    if (user_len == 0 or kernel_len == 0) return 0;
    // Kopioitavien tavujen enimmäismäärä.
    const copy_len = @min(kernel_len, @as(usize, @intCast(user_len)));
    // SMAP: salli user-sivujen kirjoitus kernelistä.
    user_access.stac();
    // Kopioi tavu kerrallaan ring 3 -puskuriin.
    var i: usize = 0;
    while (i < copy_len) : (i += 1) {
        // Kirjoita yksi tavu user-muistiin.
        user[i] = kernel_buf[i];
    }
    // Palauta SMAP-suojaus.
    user_access.clac();
    // Palauta kopioitujen tavujen määrä.
    return @intCast(copy_len);
}

// sys_meminfo — täytä käyttäjän puskuri PMM/heap-tiedoilla.
fn sysMeminfo(a1: u64, a2: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    // Käyttäjän puskurin osoite.
    const user: [*]u8 = @ptrFromInt(a1);
    // Puskurin enimmäispituus.
    const user_len = a2;
    // Kernel-puskuri muotoilua varten.
    var kbuf: [96]u8 = undefined;
    // Kirjoitusoffset kernel-puskurissa.
    var pos: usize = 0;
    // PMM total -rivi.
    pos = appendLiteral(&kbuf, pos, "PMM total: ");
    pos = appendDecimal(&kbuf, pos, pmm.totalFrames());
    pos = appendLiteral(&kbuf, pos, " frames\nPMM free: ");
    pos = appendDecimal(&kbuf, pos, pmm.availableFrames());
    pos = appendLiteral(&kbuf, pos, " frames\nHeap size: ");
    pos = appendDecimal(&kbuf, pos, heap.totalSize());
    pos = appendLiteral(&kbuf, pos, " bytes\n");
    // Kopioi muotoiltu teksti käyttäjän puskuriin.
    return copyToUser(user, user_len, kbuf[0..pos], pos);
}

// Kopioi käyttäjän puskuri kernel-puskuriin — palauttaa kopioitujen tavujen määrä.
fn copyFromUser(kernel_buf: []u8, user: [*]const u8, user_len: u64) i64 {
    // Tyhjä kopiointi on OK.
    if (user_len == 0) return 0;
    // Kopioitavien tavujen enimmäismäärä.
    const copy_len = @min(kernel_buf.len, @as(usize, @intCast(user_len)));
    // SMAP: salli user-sivujen luku kernelistä.
    user_access.stac();
    // Kopioi tavu kerrallaan ring 3 -puskurista.
    var i: usize = 0;
    while (i < copy_len) : (i += 1) {
        // Lue yksi tavu user-muistista.
        kernel_buf[i] = user[i];
    }
    // Palauta SMAP-suojaus.
    user_access.clac();
    // Palauta kopioitujen tavujen määrä.
    return @intCast(copy_len);
}

// sys_ipc_send — lähetä viesti capability-slotin kautta.
fn sysIpcSend(a1: u64, a2: u64, a3: u64, _: u64, _: u64, _: u64) i64 {
    // Capability-slott indeksi.
    const slot_idx: u32 = @intCast(a1);
    // Käyttäjän puskurin osoite.
    const user: [*]const u8 = @ptrFromInt(a2);
    // Lähetettävien tavujen määrä.
    const len = a3;
    // Tyhjä viesti on OK ilman user-kopiota.
    if (len == 0) {
        // Lähetä nollapituinen viesti porttiin.
        const sent = port.sendViaSlot(slot_idx, "") catch |err| return ipc_core.mapPortError(err);
        // Palauta lähetettyjen tavujen määrä.
        return @intCast(sent);
    }
    // Viesti ei saa ylittää portin MAX_MSG_SIZE.
    if (len > port.MAX_MSG_SIZE) return abi.EINVAL;
    // Kernel-puskuri user-datalle ennen sendViaSlot-kutsua.
    var kbuf: [port.MAX_MSG_SIZE]u8 = undefined;
    // Kopioitavien tavujen enimmäismäärä.
    const copy_len = @min(@as(usize, @intCast(len)), kbuf.len);
    // SMAP: salli user-sivujen luku kernelistä.
    user_access.stac();
    // Kopioi user-puskuri kerneliin tavu kerrallaan.
    var i: usize = 0;
    while (i < copy_len) : (i += 1) {
        // Lue yksi tavu user-muistista.
        kbuf[i] = user[i];
    }
    // Palauta SMAP-suojaus.
    user_access.clac();
    // Lähetä slotin kautta (capability-tarkistus port.zig:ssä).
    const sent = port.sendViaSlot(slot_idx, kbuf[0..copy_len]) catch |err| return ipc_core.mapPortError(err);
    // Palauta lähetettyjen tavujen määrä.
    return @intCast(sent);
}

// sys_ipc_try_recv — vastaanota viesti ilman blokkausta (EAGAIN jos jono tyhjä).
fn sysIpcTryRecv(a1: u64, a2: u64, a3: u64, _: u64, _: u64, _: u64) i64 {
    // Capability-slott indeksi.
    const slot_idx: u32 = @intCast(a1);
    // Käyttäjän puskurin osoite.
    const user: [*]u8 = @ptrFromInt(a2);
    // Puskurin enimmäispituus.
    const user_len = a3;
    // Tyhjä puskuri — ei kopioitavaa.
    if (user_len == 0) return 0;
    // Kernel-puskuri vastaanotolle.
    var kbuf: [port.MAX_MSG_SIZE]u8 = undefined;
    // Vastaanota slotin kautta — ei blokkaa tyhjällä jonolla.
    const recv_len = port.recvViaSlot(slot_idx, &kbuf) catch |err| return ipc_core.mapPortError(err);
    // Kopioitavien tavujen enimmäismäärä.
    const copy_len = @min(recv_len, @as(usize, @intCast(user_len)));
    // SMAP: salli user-sivujen kirjoitus kernelistä.
    user_access.stac();
    // Kopioi viesti käyttäjän puskuriin tavu kerrallaan.
    var i: usize = 0;
    while (i < copy_len) : (i += 1) {
        // Kirjoita yksi tavu user-muistiin.
        user[i] = kbuf[i];
    }
    // Palauta SMAP-suojaus.
    user_access.clac();
    // Palauta viestin alkuperäinen pituus (kuten read()).
    return @intCast(recv_len);
}

// sys_ipc_flush — tyhjennä capability-slotin portin viestijono.
fn sysIpcFlush(a1: u64, _: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    // Capability-slott indeksi.
    const slot_idx: u32 = @intCast(a1);
    // Tyhjennä jono recv-oikeudella varustetusta slotista.
    const flushed = port.flushViaSlot(slot_idx) catch |err| return ipc_core.mapPortError(err);
    // Palauta poistettujen viestien määrä.
    return @intCast(flushed);
}

// sys_ipc_queue_capacity — palauta capability-slotin portin jonon maksimisyvyys.
fn sysIpcQueueCapacity(a1: u64, _: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    // Capability-slott indeksi.
    const slot_idx: u32 = @intCast(a1);
    // Hae jonon kapasiteetti recv-oikeudella varustetusta slotista.
    const cap_val = port.queueCapacityViaSlot(slot_idx) catch |err| return ipc_core.mapPortError(err);
    // Palauta maksimijonon syvyys (MAX_QUEUE).
    return @intCast(cap_val);
}

// sys_ipc_pending — palauta capability-slotin portin jonossa olevien viestien määrä.
fn sysIpcPending(a1: u64, _: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    // Capability-slott indeksi.
    const slot_idx: u32 = @intCast(a1);
    // Hae jonon pituus recv-oikeudella varustetusta slotista.
    const count = port.pendingViaSlot(slot_idx) catch |err| return ipc_core.mapPortError(err);
    // Palauta odottavien viestien määrä (0..MAX_QUEUE).
    return @intCast(count);
}

// sys_ipc_recv — vastaanota viesti capability-slotin kautta.
fn sysIpcRecv(a1: u64, a2: u64, a3: u64, _: u64, _: u64, _: u64) i64 {
    // Capability-slott indeksi.
    const slot_idx: u32 = @intCast(a1);
    // Käyttäjän puskurin osoite.
    const user: [*]u8 = @ptrFromInt(a2);
    // Puskurin enimmäispituus.
    const user_len = a3;
    // Tyhjä puskuri — ei kopioitavaa.
    if (user_len == 0) return 0;
    // Kernel-puskuri vastaanotolle.
    var kbuf: [port.MAX_MSG_SIZE]u8 = undefined;
    // Vastaanota slotin kautta — blokkaa kunnes viesti saapuu.
    const recv_len = port.recvViaSlotBlocking(slot_idx, &kbuf) catch |err| return ipc_core.mapPortError(err);
    // Kopioitavien tavujen enimmäismäärä.
    const copy_len = @min(recv_len, @as(usize, @intCast(user_len)));
    // SMAP: salli user-sivujen kirjoitus kernelistä.
    user_access.stac();
    // Kopioi viesti käyttäjän puskuriin tavu kerrallaan.
    var i: usize = 0;
    while (i < copy_len) : (i += 1) {
        // Kirjoita yksi tavu user-muistiin.
        user[i] = kbuf[i];
    }
    // Palauta SMAP-suojaus.
    user_access.clac();
    // Palauta viestin alkuperäinen pituus (kuten read()).
    return @intCast(recv_len);
}

// sys_cap_delegate — delegoi osa oikeuksista uuteen capability-slottiin.
fn sysCapDelegate(a1: u64, a2: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    // Lähde capability-slotti.
    const slot_idx: u32 = @intCast(a1);
    // Pyydetyt oikeudet bitmaskina.
    const mask: u32 = @intCast(a2);
    // Dekoodaa maski → Rights (hylkää varatut bitit).
    const new_rights_raw = cap_core.rightsFromMask(mask) orelse return abi.EINVAL;
    // Muunna cap_syscall_core.Rights → capability_core.Rights.
    const new_rights: cap.Rights = @bitCast(new_rights_raw);
    // Hae lähdeslotti — virheellinen indeksi.
    const src = cap.lookupSlot(slot_idx) orelse return abi.EBADF;
    // Delegointi vaatii grant-bitin lähde-slotissa.
    if (!src.rights.grant) return abi.EPERM;
    // Uudet oikeudet ⊆ alkuperäiset oikeudet.
    if (!cap.rightsSubset(src.rights, new_rights)) return abi.EPERM;
    // Asenna uusi slotti samalle objektille.
    const derived = cap.delegateSlot(slot_idx, new_rights) orelse return abi.EINVAL;
    // Palauta uuden slotin indeksi.
    return @intCast(derived);
}

// sys_cap_revoke — peruuta capability-slotti ja taustalla oleva objekti.
fn sysCapRevoke(a1: u64, _: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    // Capability-slotti peruutettavaksi.
    const slot_idx: u32 = @intCast(a1);
    // Yritä peruuttaa slotin objekti.
    if (!cap.revokeSlot(slot_idx)) return abi.EBADF;
    // Onnistui — palauta nolla.
    return 0;
}

// sys_cap_get_rights — palauta capability-slotin oikeusmaski.
fn sysCapGetRights(a1: u64, _: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    // Capability-slotti kyseltäväksi.
    const slot_idx: u32 = @intCast(a1);
    // Hae slotti — virheellinen indeksi tai mitätöity.
    const slot = cap.lookupSlot(slot_idx) orelse return abi.EBADF;
    // Slotti ilman objektiviitettä on mitätöity.
    if (slot.object_id == 0) return abi.EBADF;
    // Muunna capability_core.Rights → cap_syscall_core.Rights.
    const rights_raw: cap_core.Rights = @bitCast(slot.rights);
    // Palauta oikeudet bitmaskina.
    return @intCast(cap_core.rightsToMask(rights_raw));
}

// sys_cap_get_type — palauta capability-slotin objektityyppi.
fn sysCapGetType(a1: u64, _: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    // Capability-slotti kyseltäväksi.
    const slot_idx: u32 = @intCast(a1);
    // Hae slotin objektityyppi — null jos mitätöity.
    const typ = cap.getSlotType(slot_idx) orelse return abi.EBADF;
    // Palauta tyyppi numerona (CapType enum → u32).
    return @intCast(@intFromEnum(typ));
}

// sys_cap_get_resource — palauta capability-slotin resurssitunniste (port_id jne.).
fn sysCapGetResource(a1: u64, _: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    // Capability-slotti kyseltäväksi.
    const slot_idx: u32 = @intCast(a1);
    // Hae slotti — virheellinen indeksi tai mitätöity.
    const slot = cap.lookupSlot(slot_idx) orelse return abi.EBADF;
    // Slotti ilman objektiviitettä on mitätöity.
    if (slot.object_id == 0) return abi.EBADF;
    // Resurssitunnisteen kysely vaatii read-oikeuden slotissa.
    if (!cap.slotHasRights(slot_idx, .{ .read = true })) return abi.EPERM;
    // Hae resurssitunniste — null jos objekti puuttuu.
    const resource = cap.getSlotResource(slot_idx) orelse return abi.EBADF;
    // Palauta port_id tai muu resurssitunniste.
    return @intCast(resource);
}

// sys_cap_create — luo uusi capability (portti tai muisti) annetuilla oikeuksilla.
fn sysCapCreate(a1: u64, a2: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    // Capability-tyyppi (CAP_TYPE_PORT = 1 tai CAP_TYPE_MEMORY = 5).
    const typ: u32 = @intCast(a1);
    // Oikeudet bitmaskina.
    const mask: u32 = @intCast(a2);
    // Tarkista tyyppi tuettu.
    if (!cap_core.typeValid(typ)) return abi.EINVAL;
    // Dekoodaa maski → Rights (hylkää varatut bitit).
    const rights_raw = cap_core.rightsFromMask(mask) orelse return abi.EINVAL;
    // Muunna cap_syscall_core.Rights → capability_core.Rights.
    const rights: cap.Rights = @bitCast(rights_raw);
    // Nykyinen prosessi omistaa uuden capabilityn (Vaihe 23 security S1).
    const owner = process.currentPid();
    // Luo oikean tyyppinen capability-objekti ja asenna se slottiin.
    const slot: ?u32 = switch (typ) {
        cap_core.CAP_TYPE_PORT => blk: {
            const port_id = port.createPort() orelse return abi.EINVAL;
            break :blk cap.createAndInstall(.port, owner, port_id, rights);
        },
        cap_core.CAP_TYPE_MEMORY => blk: {
            // Muisti-capability perustuu tyhjänä (resource = 0), fyysinen kehys allokoitetaan myöhemmin sys_mem_map-kutsussa.
            const resource_id: u64 = 0;
            break :blk cap.createAndInstall(.memory, owner, resource_id, rights);
        },
        else => null, // typeValid on tarkistanut jo.
    };

    if (slot == null) return abi.EINVAL;

    // Palauta uuden capability-slotin indeksi.
    return @intCast(slot.?);
}

// Callback ps_core:lle — pid taulukko-indeksillä.
fn psPidAt(index: usize) ?u64 {
    // Delegoi prosessitaulukon pidAt:lle.
    return process.pidAt(index);
}

// Callback ps_core:lle — onko prosessilla ladattu ELF.
fn psLoadedAt(pid: u64) bool {
    // Delegoi prosessitaulukon isLoaded:lle.
    return process.isLoaded(pid);
}

// sys_ps — täytä käyttäjän puskuri prosessitaulukon listalla (Vaihe 23).
fn sysPs(a1: u64, a2: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    // Käyttäjän puskurin osoite.
    const user: [*]u8 = @ptrFromInt(a1);
    // Puskurin enimmäispituus.
    const user_len = a2;
    // Kernel-puskuri muotoilua varten.
    var kbuf: [256]u8 = undefined;
    // Muotoile prosessilista prosessitaulukosta.
    const klen = ps_core.formatListing(
        process.processCount(),
        psPidAt,
        psLoadedAt,
        &kbuf,
    );
    // Kopioi muotoiltu teksti käyttäjän puskuriin.
    return copyToUser(user, user_len, kbuf[0..klen], klen);
}

// sys_mem_map — Capability memory + mapPageEnsure (Vaihe 28).
pub fn sysMemMap(a1: u64, a2: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    // Kutsu mem_map_core.doMemMap(slot_idx, virt_addr).
    return mem_map_core.doMemMap(@intCast(a1), @intCast(a2));
}

// sys_plugin_load — lataa plugin-ELF manifesti+scope-valvonnalla (Vaihe 30).
fn sysPluginLoad(a1: u64, a2: u64, a3: u64, a4: u64, a5: u64, a6: u64) i64 {
    // Plugin-ELF-tunniste (vaihe 30: vain 0).
    const embedded_id = a1;
    // Manifestin pyydetty cap-tyyppi (ABI: 1=port, 5=memory).
    const req_type: u32 = @intCast(a2);
    // Manifestin pyydetyt oikeudet maskina.
    const req_rights: u32 = @intCast(a3);
    // Scopen sallitut tyypit bittimaskina.
    const scope_types: u32 = @intCast(a4);
    // Scopen sallitut oikeudet bittimaskina.
    const scope_rights: u32 = @intCast(a5);
    // Scopen cap-katto (0 → oletus 8 initScope:ssa).
    const max_caps: u32 = @intCast(a6);
    // Tuntematon plugin-binääri.
    if (!plugin_loader.isValidEmbeddedId(embedded_id)) return abi.EINVAL;
    // Rakenna yhden capin manifesti rekistereistä (BadCapType/BadRights → EINVAL).
    const m = plugin_manifest.buildSingleCapManifest(req_type, req_rights) catch return abi.EINVAL;
    // Nykyinen prosessi on lataaja (unload-oikeus + parent).
    const parent = process.currentPid();
    // Rakenna scope lataajan biteistä (pid sidotaan ladattuun alle).
    var sc = plugin_scope.initScope(parent, scope_types, scope_rights, max_caps);
    // Scope itse kelvoton (tyhjät maskit).
    if (!plugin_scope.validate(sc)) return abi.EINVAL;
    // Manifesti scopen ulkopuolella → EPERM (ei eskalaatiota).
    if (!plugin_manifest.checkScope(sc, m)) return abi.EPERM;
    // Lataa ELF uudelle pid:lle omaan sivutauluun.
    const pid = plugin_loader.loadPlugin(embedded_id) orelse return abi.ENOMEM;
    // Sido scope ladattuun plugin-pidiin.
    sc.plugin_pid = pid;
    // Rekisteröi plugin — täysi rekisteri → siivoa lataus ja ENOMEM.
    if (!plugin_loader.registerPlugin(pid, parent, sc)) {
        // Pura osittainen lataus (capsit + PML4 + pid).
        _ = plugin_loader.unloadPlugin(pid);
        return abi.ENOMEM;
    }
    // Palauta pluginin pid.
    return @intCast(pid);
}

// sys_plugin_transfer — gateway-siirto pluginista toiseen (Vaihe 31).
// ABI: RAX=26, RDI=src_pid, RSI=src_slot, RDX=dest_pid, R10=rights_mask
// (4. argumentti R10:ssä — CPU ylikirjoittaa RCX:n SYSCALL:ssa).
// Kutsuja = currentPid: vain boot/init tai lähdeplugin itse saa avata portin
// (gateway valvoo scopea molemmissa päissä). Suljettu portti → EPERM.
fn sysPluginTransfer(a1: u64, a2: u64, a3: u64, a4: u64, _: u64, _: u64) i64 {
    // Lähdepluginin pid (u64, ei kavennusta).
    const src_pid = a1;
    // Lähdeslotti — @truncate, ei @intCast: ylisuuri rekisteri katkaistaan
    // jolloin lookup epäonnistuu ja portti sulkeutuu EPERM:iin sen sijaan
    // että safety-paniikki kaataisi kernelin (ring 3 hallitsee rekistereitä).
    const src_slot: u32 = @truncate(a2);
    // Kohdepluginin pid (u64, ei kavennusta).
    const dest_pid = a3;
    // Oikeusmaski — katkaistu, gateway hylkää varatut bitit EPERM:llä.
    const rights_mask: u32 = @truncate(a4);
    // Gateway päättää + asentaa, tai null.
    const derived = ns_map.gatewayTransfer(src_pid, src_slot, dest_pid, rights_mask) orelse return abi.EPERM;
    // Palauta kohteen slottinumero.
    return @intCast(derived);
}

// sys_plugin_unload — pura plugin + vapauta resurssit (Vaihe 30).
fn sysPluginUnload(a1: u64, _: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    // Purettavan pluginin pid.
    const pid = a1;
    // Ei rekisteröity plugin.
    if (!plugin_loader.isPlugin(pid)) return abi.ESRCH;
    // Kutsuja + rekisteröity lataaja unload-tarkistukseen.
    const caller = process.currentPid();
    // Lataaja-parent selville.
    const owner = plugin_loader.pluginParent(pid) orelse return abi.ESRCH;
    // Vain lataaja tai boot saa purkaa (ei vieraiden pluginien tappoa).
    if (caller != owner and caller != process.BOOT_PID) return abi.EPERM;
    // Pura: omistetut capsit + slotit + PML4 + pid + rekisteri.
    if (!plugin_loader.unloadPlugin(pid)) return abi.ESRCH;
    // Onnistui.
    return 0;
}

// Dispatch-taulukko — indeksi = syscall-numero (max 31).
const handlers: [32]?SyscallFn = blk: {
    // Alusta kaikki merkinnät tyhjiksi.
    var table: [32]?SyscallFn = .{null} ** 32;
    // Rekisteröi sys_write.
    table[@intCast(abi.SYS_write)] = sysWrite;
    // Rekisteröi sys_read.
    table[@intCast(abi.SYS_read)] = sysRead;
    // Rekisteröi sys_exit.
    table[@intCast(abi.SYS_exit)] = sysExit;
    // Rekisteröi sys_getpid.
    table[@intCast(abi.SYS_getpid)] = sysGetpid;
    // Rekisteröi sys_ipc_send (capability-porttiin lähetys).
    table[@intCast(abi.SYS_ipc_send)] = sysIpcSend;
    // Rekisteröi sys_ipc_recv (capability-portista vastaanotto).
    table[@intCast(abi.SYS_ipc_recv)] = sysIpcRecv;
    // Rekisteröi sys_ipc_try_recv (non-blocking recv, EAGAIN jos tyhjä).
    table[@intCast(abi.SYS_ipc_try_recv)] = sysIpcTryRecv;
    // Rekisteröi sys_ipc_pending (jonossa olevien viestien määrä).
    table[@intCast(abi.SYS_ipc_pending)] = sysIpcPending;
    // Rekisteröi sys_ipc_queue_capacity (portin jonon maksimisyvyys).
    table[@intCast(abi.SYS_ipc_queue_capacity)] = sysIpcQueueCapacity;
    // Rekisteröi sys_spawn (upotettu ELF → uusi prosessi).
    table[@intCast(abi.SYS_spawn)] = sysSpawn;
    // Rekisteröi sys_cap_transfer (capability toiselle prosessille).
    table[@intCast(abi.SYS_cap_transfer)] = sysCapTransfer;
    // Rekisteröi sys_wait (lapsen zombie-tilan odotus).
    table[@intCast(abi.SYS_wait)] = sysWait;
    // Rekisteröi sys_ipc_flush (portin viestijonon tyhjennys).
    table[@intCast(abi.SYS_ipc_flush)] = sysIpcFlush;
    // Rekisteröi sys_cap_delegate (capability-oikeuksien delegointi).
    table[@intCast(abi.SYS_cap_delegate)] = sysCapDelegate;
    // Rekisteröi sys_cap_create (uusi capability-portti).
    table[@intCast(abi.SYS_cap_create)] = sysCapCreate;
    // Rekisteröi sys_cap_revoke (capability-slotti peruutus).
    table[@intCast(abi.SYS_cap_revoke)] = sysCapRevoke;
    // Rekisteröi sys_cap_get_rights (capability-oikeusmaskin kysely).
    table[@intCast(abi.SYS_cap_get_rights)] = sysCapGetRights;
    // Rekisteröi sys_cap_get_type (capability-objektityypin kysely).
    table[@intCast(abi.SYS_cap_get_type)] = sysCapGetType;
    // Rekisteröi sys_cap_get_resource (capability-resurssitunnisteen kysely).
    table[@intCast(abi.SYS_cap_get_resource)] = sysCapGetResource;
    // Rekisteröi sys_test_return (ring 3 boot-paluu).
    table[@intCast(abi.SYS_test_return)] = sysTestReturn;
    // Rekisteröi sys_meminfo (shell meminfo-komento).
    table[@intCast(abi.SYS_meminfo)] = sysMeminfo;
    // Rekisteröi sys_ps (shell ps-komento).
    table[@intCast(abi.SYS_ps)] = sysPs;
    // Rekisteröi sys_mem_map (memory-capability + mapPageEnsure, Vaihe 28).
    table[@intCast(abi.SYS_mem_map)] = sysMemMap;
    // Rekisteröi sys_plugin_load (manifesti+scope-valvottu lataus, Vaihe 30).
    table[@intCast(abi.SYS_plugin_load)] = sysPluginLoad;
    // Rekisteröi sys_plugin_unload (resurssien vapautus, Vaihe 30).
    table[@intCast(abi.SYS_plugin_unload)] = sysPluginUnload;
    // Rekisteröi sys_plugin_transfer (gateway-siirto, Vaihe 31).
    table[@intCast(abi.SYS_plugin_transfer)] = sysPluginTransfer;
    // Palauta valmis taulukko.
    break :blk table;
};

// Pakota linkitys smoke-buildissa — export-funktio ei saa poistua LTO:ssa.
pub fn linkAnchor() void {
    // Ota export-funktion osoite — assembly entry (syscall_entry.S) tarvitsee symbolin.
    const p = @as(*const anyopaque, @ptrCast(@as(*const fn (*SyscallFrame) callconv(.c) i64, &syscallDispatchFromFrame)));
    // Estä optimointi / dead-strip poistamasta export-symbolia.
    asm volatile ("" ::: .{ .memory = true });
    if (@intFromPtr(p) == 0) @trap();
}

// Suorita yksi syscall kehyksen perusteella (C-puoli entry:stä).
pub export fn syscallDispatchFromFrame(frame: *SyscallFrame) i64 {
    // Hae syscall-numero kehyksestä.
    const num = frame.num;
    // Numero taulukon ulkopuolella → ENOSYS.
    if (num >= handlers.len) return abi.ENOSYS;
    // Hae handler tai null.
    const handler = handlers[@intCast(num)] orelse return abi.ENOSYS;
    // Kutsu handler argumenteilla.
    return handler(frame.arg1, frame.arg2, frame.arg3, frame.arg4, frame.arg5, frame.arg6);
}

// Suorita syscall suoraan (boot-testi ilman ring 3).
pub fn invoke(num: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64, a6: u64) i64 {
    // Numero taulukon ulkopuolella → ENOSYS.
    if (num >= handlers.len) return abi.ENOSYS;
    // Hae handler tai null.
    const handler = handlers[@intCast(num)] orelse return abi.ENOSYS;
    // Kutsu handler suoraan.
    return handler(a1, a2, a3, a4, a5, a6);
}

// Boot-testi — kutsu sys_write suoraan dispatchista.
pub fn runBootTest() void {
    // Testiviesti serialiin.
    const msg = "SY";
    // Kutsu sys_write(1, msg, 2).
    const ret = invoke(abi.SYS_write, 1, @intFromPtr(msg), 2, 0, 0, 0);
    // Varmista että 2 tavua kirjoitettiin.
    if (ret != 2) {
        // Virhe boot-testissä.
        log.err("Syscall write test failed");
        // Lopeta testi.
        return;
    }
    // Vahvista dispatch toimii.
    log.info("Syscall dispatch test OK");
}
