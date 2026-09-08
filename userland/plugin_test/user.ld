/* userland/plugin_test/user.ld — plugin-testi @ 0xFFFFFFFF9008D000 */

/* Ring 3 plugin — oma LOAD-alue (vapaa väli 0x...C000 ja 0x...E000 välissä). */
ENTRY(_start)

SECTIONS
{
    /* Plugin-testin virtuaalinen latausosoite — higher-half 4K-sivut. */
    . = 0xFFFFFFFF9008D000;

    /* Suoritettava koodi (_start start.S:stä). */
    .text : {
        KEEP(*(.text._start))
        *(.text .text.*)
    }

    /* Vain-luku -data (plugin-viesti). */
    .rodata : {
        *(.rodata .rodata.*)
    }

    /* Alustettu data. */
    .data : {
        *(.data .data.*)
    }

    /* Nollattu BSS. */
    .bss : {
        *(COMMON)
        *(.bss .bss.*)
    }
}
