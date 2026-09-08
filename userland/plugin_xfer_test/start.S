// Käyttäjätilan plugin-siirtotesti — hyppää Zig xferMain:iin.
.global _start
.extern xferMain

_start:
    // Kutsu Zig-siirtotesti (gateway syscall ring 3:ssa).
    call xferMain
    // Ei saavuteta — xferMain kutsuu sys_test_return.
    ud2
