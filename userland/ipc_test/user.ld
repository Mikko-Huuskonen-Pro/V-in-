/* userland/ipc_test/user.ld — IPC userland -testin muistikartta @ 0xFFFFFFFF90060000 */

/* Ring 3 IPC-testi — portti-cap slot .capbootissa 0xFFFFFFFF90061000, pino heap-slot 99. */
ENTRY(_start)

SECTIONS
{
    /* IPC-testin virtuaalinen latausosoite — erillään shell/driver-ELF:stä. */
    . = 0xFFFFFFFF90060000;

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

    /* Kernel kirjoittaa IPC capability-slotin ennen ring 3 -hyppyä. */
    . = ALIGN(0x1000);
    .capboot : {
        ipcParentSlot = .;
        LONG(0);
    }
}
