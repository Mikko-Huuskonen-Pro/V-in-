// Ring 3 siirtym ja paluu - iretq + ret.
// Vaihe 26: di=entry, si=user_stack_top, dx=user_cs, cx=user_ss,
//           r8=rflags, r9 cr3 (kohde-prosessin PML4 fysinen osoite).
.global usermodeEnterIret
.global usermodeReturnToKernel
.global usermode_saved_kernel_rsp
.global saved_kernel_cr3

usermodeEnterIret:
    // Tallenna kernel RSP ennen iretq-kehyksen rakentamista.
    mov %rsp, usermode_saved_kernel_rsp(%rip)
    // Vaihe 26: aseta CR3 = kohde-prosessin PML4 ennen iretq --
    //            varmistaa per-prosessi muisti-isolaatio user-tilassa.
    // r9:ss on cr3 (functioargumentti). Aseta aina CR3:han.
    mov %r9, %cr3
    // iretq pinon kehys (viimeinen push = RIP, popataan ensin).
    push %rcx
    push %rsi
    push %r8
    push %rdx
    push %rdi
    // Siirry ring 3:een.
    iretq

usermodeReturnToKernel:
    // Vaihe 26: palauta kernel CR3 ennen pinon vaihtoa, jotta kaik-
    // ki kernel-globalit (log, vmm...) ovat oikeilla osoitteilla.
    mov saved_kernel_cr3(%rip), %rax
    test %rax, %rax
    jz .skip_cr3_restore
    mov %rax, %cr3
.skip_cr3_restore:
    // Palauta boot-pino ja hyppa runBootTest-jatkoon.
    mov usermode_saved_kernel_rsp(%rip), %rsp
    ret
