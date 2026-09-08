//! Syscall-fuzz-ydin — dispatch-rajojen ja ENOSYS-logiikan testaus (host-testattava).
//!
//! **Vastuu**: Tunnista vaaralliset syscallit, odota ENOSYS tuntemattomille.
//! **Riippuvuudet**: ei
//! **Käytetään**: `syscall_fuzz.zig`, host-testit

// Dispatch-taulukon koko — sama kuin dispatch.zig handlers.len.
pub const TABLE_SIZE: usize = 32;
// ENOSYS paluuarvo (Linux-yhteensopiva negatiivinen).
pub const ENOSYS: i64 = -38;
// EBADF virhe — huono fd sys_write/sys_read -testeissä.
pub const EBADF: i64 = -9;
// Montako satunnaista syscall-numeroa boot-fuzzissa ajetaan.
pub const FUZZ_ROUNDS: usize = 48;
// Vähimmäismäärä ENOSYS-vastauksia fuzz-kierroksilla.
pub const MIN_ENOSYS_HITS: usize = 8;

// Rekisteröidyt syscall-numerot dispatch-taulukossa (Vaihe 4–5).
pub fn isRegistered(num: u64) bool {
    // Tunnetut handler-slotit zinuxabi.zig:stä.
    return switch (num) {
        // sys_write.
        1 => true,
        // sys_exit.
        2 => true,
        // sys_getpid.
        3 => true,
        // sys_ipc_send.
        4 => true,
        // sys_ipc_recv.
        5 => true,
        // sys_cap_delegate.
        6 => true,
        // sys_cap_create.
        7 => true,
        // sys_cap_revoke.
        8 => true,
        // sys_ipc_try_recv.
        9 => true,
        // sys_test_return.
        10 => true,
        // sys_read.
        11 => true,
        // sys_meminfo.
        12 => true,
        // sys_ps.
        13 => true,
        // sys_ipc_pending.
        14 => true,
        // sys_cap_get_rights.
        15 => true,
        // sys_cap_get_type.
        16 => true,
        // sys_ipc_flush.
        17 => true,
        // sys_cap_get_resource.
        18 => true,
        // sys_ipc_queue_capacity.
        19 => true,
        // sys_spawn.
        20 => true,
        // sys_cap_transfer.
        21 => true,
        // sys_wait.
        22 => true,
        // sys_mem_map (Vaihe 28) — kartoittaa sivuja fuzzissa.
        23 => true,
        // sys_plugin_load (Vaihe 30) — lataa ELF:ää fuzzissa.
        24 => true,
        // sys_plugin_unload (Vaihe 30) — purkaa plugineja fuzzissa.
        25 => true,
        // Kaikki muut slotit tyhjät tai taulukon ulkopuolella.
        else => false,
    };
}

// Syscall joka ei saa ajaa fuzzissa (halt, block tai user-osoite).
pub fn isDangerous(num: u64) bool {
    // switch tarkistaa rekisteröidyt vaaralliset.
    return switch (num) {
        // sys_exit — pysäyttää CPU:n.
        2 => true,
        // sys_ipc_send — dereferoi user-osoitteen.
        4 => true,
        // sys_ipc_recv — blokkaa tyhjällä jonolla (timer-wake vaaditaan).
        5 => true,
        // sys_cap_delegate — mutatoi capability-tilaa fuzzissa.
        6 => true,
        // sys_cap_create — luo portteja fuzzissa.
        7 => true,
        // sys_cap_revoke — mutatoi capability-tilaa fuzzissa.
        8 => true,
        // sys_ipc_try_recv — dereferoi user-osoitteen (EAGAIN jos tyhjä).
        9 => true,
        // sys_test_return — hyppää pois boot-kontekstista.
        10 => true,
        // sys_read — blokkaava UART-luku.
        11 => true,
        // sys_meminfo — dereferoi user-osoitteen.
        12 => true,
        // sys_ps — dereferoi user-osoitteen.
        13 => true,
        // sys_ipc_pending — riippuu slot-tilasta.
        14 => true,
        // sys_cap_get_rights — riippuu slot-tilasta.
        15 => true,
        // sys_cap_get_type — riippuu slot-tilasta.
        16 => true,
        // sys_ipc_flush — mutatoi jonoja fuzzissa.
        17 => true,
        // sys_cap_get_resource — riippuu slot-tilasta.
        18 => true,
        // sys_ipc_queue_capacity — riippuu slot-tilasta.
        19 => true,
        // sys_spawn — luo prosesseja ja kartoittaa ELF:ää fuzzissa.
        20 => true,
        // sys_cap_transfer — mutatoi capability-tilaa fuzzissa.
        21 => true,
        // sys_wait — riippuu prosessitaulukon tilasta.
        22 => true,
        // sys_mem_map — allokoi kehyksiä ja kartoittaa sivuja fuzzissa.
        23 => true,
        // sys_plugin_load — lataa plugin-ELF:ää ja varaa pidejä fuzzissa.
        24 => true,
        // sys_plugin_unload — vapauttaa kehyksiä ja pidejä fuzzissa.
        25 => true,
        // Muut numerot turvallisia tai ENOSYS.
        else => false,
    };
}

// Pitäisikö dispatch palauttaa ENOSYS tälle numerolle?
pub fn expectEnosys(num: u64) bool {
    // Taulukon ulkopuolella → aina ENOSYS.
    if (num >= TABLE_SIZE) return true;
    // Tyhjä slotti → ENOSYS.
    if (!isRegistered(num)) return true;
    // Handler on olemassa.
    return false;
}

// Onko paluuarvo ENOSYS?
pub fn isEnosys(ret: i64) bool {
    // Vertaa vakioon.
    return ret == ENOSYS;
}

// LCG-seed seuraavaan arvoon — deterministinen fuzz.
pub fn lcgNext(seed: *u64) u64 {
    // 64-bit LCG vakiot (Numerical Recipes).
    seed.* = seed.* *% 6364136223846793005 +% 1442695040888963407;
    // Palauta sekoitettu arvo.
    return seed.*;
}

// Tuota seuraava fuzzattava syscall-numero (0..127).
pub fn fuzzSyscallNum(seed: *u64) u64 {
    // LCG askel.
    const mixed = lcgNext(seed);
    // Rajaa 0..127 — testaa taulukon ulko- ja sisäpuolta.
    return mixed % 128;
}

// Tuota satunnainen argumentti fuzz-kutsuun.
pub fn fuzzArg(seed: *u64) u64 {
    // LCG askel eri sarjalle.
    return lcgNext(seed);
}

// Hyväksy turvallinen fuzz-paluuarvo rekisteröimättömälle numerolle.
pub fn acceptFuzzResult(num: u64, ret: i64) bool {
    // Pitää olla ENOSYS jos odotettu.
    if (expectEnosys(num)) return isEnosys(ret);
    // Rekisteröity mutta vaarallinen — ei pitäisi ajaa fuzzissa.
    if (isDangerous(num)) return false;
    // sys_getpid — aina 1.
    if (num == 3) return ret == 1;
    // sys_write — fuzzaa vain fd/len=0 tapauksia erikseen bootissa.
    return true;
}

// Boot-fuzz onnistui jos tarpeeksi ENOSYS-osumia.
pub fn bootFuzzOk(enosys_hits: usize) bool {
    // Vähintään MIN_ENOSYS_HITS tuntematonta syscallia hylätty.
    return enosys_hits >= MIN_ENOSYS_HITS;
}
