// Plugin-testi ELF — sys_write("plg\n") + SYS_test_return.
.global _start

_start:
    // sys_write(1, msg, 4) — RAX = SYS_write (1).
    mov $1, %rax
    // fd = stdout (UART).
    mov $1, %rdi
    // Merkkijono .rodata:ssa.
    lea msg(%rip), %rsi
    // Neljä tavua "plg\n".
    mov $4, %rdx
    // Siirry kerneliin SYSCALL:lla.
    syscall
    // SYS_test_return (10) — palaa kerneliin (plugin run jatkuu).
    mov $10, %rax
    // Ei argumentteja.
    xor %rdi, %rdi
    // Paluu plugin boot-testiin.
    syscall
    // Ei saavuteta.
    ud2

msg:
    // Odotettu serial-tulos: plugin elossa.
    .ascii "plg\n"
