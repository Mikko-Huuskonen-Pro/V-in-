/* userland/cross_spawn_ipc_test/user.ld — cross-spawn IPC -testin muistikartta */

ENTRY(_start)

SECTIONS
{
    /* Cross-spawn-testin virtuaalinen latausosoite. */
    . = 0xFFFFFFFF9008F000;

    /* Suoritettava koodi + merkkijonot. */
    .text : {
        KEEP(*(.text._start))
        *(.text .text.*)
        *(.ltext .ltext.*)
    }

    /* Vain-luku -data. */
    .rodata : {
        *(.rodata .rodata.*)
    }

    /* Alustettu data. */
    .data : {
        *(.data .data.*)
    }

    /* BSS omalle sivulle — loader remap ei saa ylikirjoittaa .text-sivua. */
    . = ALIGN(0x1000);
    .bss : {
        *(COMMON)
        *(.bss .bss.*)
    }
}
