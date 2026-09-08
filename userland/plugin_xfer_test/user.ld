/* userland/plugin_xfer_test/user.ld — plugin-siirtotestin muistikartta @ 0xFFFFFFFF90092000 */

/* Ring 3 siirtotesti — parametrit .capbootissa 0xFFFFFFFF90093000, pino heap-slot 117. */
ENTRY(_start)

SECTIONS
{
    /* Siirtotestin virtuaalinen latausosoite — vapaa väli 0x90091000 jälkeen. */
    . = 0xFFFFFFFF90092000;

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

    /* Kernel kirjoittaa siirtoparametrit (src_pid/slot/dest/mask) ennen hyppyä. */
    . = ALIGN(0x1000);
    .capboot : {
        xferBootInfo = .;
        LONG(0);
        LONG(0);
        LONG(0);
        LONG(0);
        LONG(0);
        LONG(0);
        LONG(0);
        LONG(0);
    }
}
