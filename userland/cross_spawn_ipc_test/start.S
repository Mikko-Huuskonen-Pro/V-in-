// Käyttäjätilan cross-spawn IPC-testi — hyppää Zig main:iin.
.global _start
.extern crossSpawnMain

_start:
    // Kutsu Zig cross-spawn-IPC-testi.
    call crossSpawnMain
    // Ei saavuteta — crossSpawnMain kutsuu sys_test_return.
    ud2
