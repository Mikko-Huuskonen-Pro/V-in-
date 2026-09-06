// Käyttäjätilan sys_mem_map test — hyppää Zig mmTestMain:in boot-structiin.
.global _start

.extern mmTestMain

_start:
    // Kutsu Zig mmap-ring 3-testi.
    call mmTestMain
    // Ei saavuteta — mmTestMain kutsuu sys_test_return.
    ud2
