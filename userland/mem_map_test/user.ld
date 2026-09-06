/* userland/mem_map_test/user.ld — sys_mem_map boot-testi muistikartta @ 0xFFFFFFFF90088000 */

ENTRY(_start)

SECTIONS
{
    /* Sys_mem_map testin virtuaalinen latausosoite. */
    . = 0xFFFFFFFF90088000;

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

    /* BSS omalle sivulle. */
    . = ALIGN(0x1000);
    .bss : {
        *(COMMON)
        *(.bss .bss.*)
    }

    /* Boot-info: mmap_virt slot_index target_phys boot-testin aikana. */
    . = ALIGN(0x1000);
    .capboot : {
        mmTestVirtSlot = .;       /* virt_addr boot-infon osoite + 0 */
        LONG(0);                   /* mmap target virt address (8-byte) */
        mmTestSlot = .;            /* capability slot index boot-infon + 8 */
        LONG(0);                   /* slot index */
        mmTestPhysAddr = .;        /* target phys addr boot-infon + 16 */
        LONG(0);                   /* physical address */
    }
}
