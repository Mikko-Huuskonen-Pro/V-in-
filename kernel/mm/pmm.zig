//! Fyysinen muistinhallinta (PMM) — bitmap-allokaattori.
//!
//! **Vastuu**: 4 KiB kehysten allokointi/vapautus bitmap-perusteella.
//! **Riippuvuudet**: ei (Limine-konversio `boot/mem.zig`:ssä)
//! **Käytetään**: `vmm.zig`, `memtest.zig`, host-testit

// Yhden kehyksen koko tavuina — x86_64 sivukoko.
pub const FRAME_SIZE: usize = 4096;

// Yksinkertaistettu muistikarta-entry (ei riipu Liminestä — host-testit OK).
pub const MapEntry = struct {
    // Fyysinen alkuosoite tälle muistialueelle.
    base: u64,
    // Alueen pituus tavuina.
    length: u64,
    // true = allokointiin kelpaava RAM, false = varattu.
    usable: bool,
};

// Bitmap-tallennus BSS:ssä — 32 KiB = 262144 bittiä = 262144 kehystä max.
var bitmap_storage: [32768]u8 align(4096) linksection(".bss") = undefined;
// Aktiivinen bitmap-puskuri (voi olla osa bitmap_storage:sta).
var bitmap: []u8 = undefined;
// Kehysten kokonaismäärä bitmapin kattamalla alueella.
var frame_count: usize = 0;
// Seuraava kehys josta allokointi aloitetaan (next-fit optimointi).
var next_free: usize = 0;
// Fyysinen base-osoite kehysindeksille 0 (yleensä 0).
var mem_base: u64 = 0;

// Merkitse kehys varatuksi indeksin perusteella.
fn markUsed(frame_index: usize) void {
    // Hylkää indeksit bitmapin ulkopuolella.
    if (frame_index >= frame_count) return;
    // Laske tavun indeksi bitmapissa (8 kehystä per tavu).
    const byte_i = frame_index / 8;
    // Laske bitin sijainti tavussa (0..7).
    const bit_i = frame_index % 8;
    // Aseta bitti 1 = varattu.
    bitmap[byte_i] |= @as(u8, 1) << @intCast(bit_i);
}

// Merkitse kehys vapaaksi indeksin perusteella.
fn markFree(frame_index: usize) void {
    // Hylkää indeksit bitmapin ulkopuolella.
    if (frame_index >= frame_count) return;
    // Laske tavun indeksi bitmapissa.
    const byte_i = frame_index / 8;
    // Laske bitin sijainti tavussa.
    const bit_i = frame_index % 8;
    // Nollaa bitti 0 = vapaa.
    bitmap[byte_i] &= ~(@as(u8, 1) << @intCast(bit_i));
}

// Merkitse fyysinen osoitealue varatuksi (kernel, ACPI, jne.).
fn reservePhysRange(base: u64, length: u64) void {
    // Tyhjä alue — ei mitään varattavaa.
    if (length == 0) return;
    // Ensimmäinen kehysindeksi alueella.
    const start = base / FRAME_SIZE;
    // Viimeinen kehysindeksi (exclusive) pyöristettynä ylös.
    const end = (base + length + FRAME_SIZE - 1) / FRAME_SIZE;
    // Käy jokainen kehys alueella.
    var i = start;
    // Merkitse varatuksi kunnes end tai frame_count.
    while (i < end and i < frame_count) : (i += 1) {
        // Aseta kehys varatuksi bitmapissa.
        markUsed(i);
    }
}

// Merkitse fyysinen osoitealue vapaaksi (usable RAM).
fn freePhysRange(base: u64, length: u64) void {
    // Tyhjä alue — ei mitään vapautettavaa.
    if (length == 0) return;
    // Ensimmäinen kehysindeksi alueella.
    const start = base / FRAME_SIZE;
    // Viimeinen kehysindeksi pyöristettynä ylös.
    const end = (base + length + FRAME_SIZE - 1) / FRAME_SIZE;
    // Käy jokainen kehys alueella.
    var i = start;
    // Merkitse vapaaksi kunnes end tai frame_count.
    while (i < end and i < frame_count) : (i += 1) {
        // Aseta kehys vapaaksi bitmapissa.
        markFree(i);
    }
}

// Alusta PMM muistikartasta (Limine-entryt konvertoidaan boot/mem.zig:ssä).
pub fn initFromMap(entries: []const MapEntry) void {
    // Etsi korkein fyysinen osoite muistikartasta.
    var max_addr: u64 = 0;
    // Käy jokainen kartta-entry.
    for (entries) |entry| {
        // Laske entryn loppuosoite.
        const end = entry.base + entry.length;
        // Päivitä max jos tämä entry ulottuu korkeammalle.
        if (end > max_addr) max_addr = end;
    }
    // Laske kehysten määrä max-osoitteen perusteella.
    frame_count = @intCast((max_addr + FRAME_SIZE - 1) / FRAME_SIZE);
    // Bitmap-tavujen määrä (8 bittiä per tavu).
    const bitmap_bytes = (frame_count + 7) / 8;
    // Rajaa frame_count jos bitmap ei mahdu staattiseen puskuriin.
    if (bitmap_bytes > bitmap_storage.len) {
        // Käytä maksimi kapasiteettia bitmap_storage:sta.
        frame_count = bitmap_storage.len * 8;
    }
    // Aseta bitmap-slice staattiseen puskuriin.
    bitmap = bitmap_storage[0 .. (frame_count + 7) / 8];
    // Kehys 0 vastaa fyysistä osoitetta 0.
    mem_base = 0;
    // Aloita allokointi indeksistä 0.
    next_free = 0;
    // Alusta kaikki varatuiksi — vapautetaan usable-entryistä.
    @memset(bitmap, 0xFF);
    // Käy muistikarta uudelleen ja merkitse usable/v reserved.
    for (entries) |entry| {
        // Usable RAM → merkitse vapaaksi.
        if (entry.usable) {
            // Vapauta koko entry-alue bitmapissa.
            freePhysRange(entry.base, entry.length);
        } else {
            // Varattu alue → pidä merkittynä.
            reservePhysRange(entry.base, entry.length);
        }
    }
    // Varaa bitmapin oma kehys ettei PMM ylikirjoita itseään.
    reservePhysRange(@intFromPtr(&bitmap_storage), bitmap_storage.len);
}

// Fallback ilman muistikarttaa — oletus 256 MiB RAM.
pub fn initFallback(total_bytes: u64) void {
    // Laske kehysten määrä annetusta RAM-koosta.
    frame_count = @intCast((total_bytes + FRAME_SIZE - 1) / FRAME_SIZE);
    // Rajaa bitmap-kapasiteettiin.
    if (frame_count > bitmap_storage.len * 8) {
        // Käytä maksimi kapasiteettia.
        frame_count = bitmap_storage.len * 8;
    }
    // Aseta bitmap-slice.
    bitmap = bitmap_storage[0 .. (frame_count + 7) / 8];
    // Base-osoite 0.
    mem_base = 0;
    // Aloita indeksistä 0.
    next_free = 0;
    // Alusta kaikki vapaaksi (fallback = koko alue usable).
    @memset(bitmap, 0);
    // Varaa bitmapin kehys.
    reservePhysRange(@intFromPtr(&bitmap_storage), bitmap_storage.len);
}

// Allokoi yksi vapaa 4 KiB kehys — palauttaa kehysindeksin tai null.
pub fn allocFrame() ?usize {
    // Ei kehyksiä — allokointi mahdoton.
    if (frame_count == 0) return null;
    // Käy bitmap läpi next-free -alkuindeksistä (modulo wrap).
    var i: usize = 0;
    // Enintään frame_count yritystä.
    while (i < frame_count) : (i += 1) {
        // Laske tarkasteltava indeksi (next-fit kiertävä haku).
        const idx = (next_free + i) % frame_count;
        // Bitmap-tavun indeksi.
        const byte_i = idx / 8;
        // Bitin sijainti tavussa.
        const bit_i = idx % 8;
        // Tarkista onko bitti 0 (vapaa).
        if ((bitmap[byte_i] & (@as(u8, 1) << @intCast(bit_i))) == 0) {
            // Merkitse kehys varatuksi.
            markUsed(idx);
            // Seuraava allokointi alkaa tämän jälkeen.
            next_free = (idx + 1) % frame_count;
            // Palauta allokoitu kehysindeksi.
            return idx;
        }
    }
    // Bitmap täynnä — ei vapaita kehyksiä.
    return null;
}

// Vapauta aiemmin allokattu kehys indeksin perusteella.
pub fn freeFrame(frame_index: usize) void {
    // Merkitse kehys vapaaksi bitmapissa.
    markFree(frame_index);
}

// Muunna kehysindeksi fyysiseksi tavuosoitteeksi.
pub fn frameToPhys(frame_index: usize) u64 {
    // phys = base + index * 4096.
    return mem_base + @as(u64, frame_index) * FRAME_SIZE;
}

// Muunna fyysinen osoite kehysindeksiksi — null jos reunaehto rikki (Vaihe 30 unload).
pub fn physToFrame(phys: u64) ?usize {
    // Osoite ennen basea ei kelpaa.
    if (phys < mem_base) return null;
    // Siirtymä basesta.
    const off = phys - mem_base;
    // Pitää olla kehysrajalla (4 KiB aligned).
    if (off % FRAME_SIZE != 0) return null;
    // Kehysindeksi siirtymästä.
    const idx: usize = @intCast(off / FRAME_SIZE);
    // Indeksi bitmapin ulkopuolella.
    if (idx >= frame_count) return null;
    // Palauta kehysindeksi.
    return idx;
}

// Palauta kehysten kokonaismäärä (bitmapin kattama alue).
pub fn totalFrames() usize {
    // Palauta frame_count.
    return frame_count;
}

// Laske vapaiden kehysten määrä bitmapista (O(n) — riittää boot/debug).
pub fn availableFrames() usize {
    // Ei kehyksiä — ei mitään vapaata.
    if (frame_count == 0) return 0;
    // Vapaiden kehysten laskuri.
    var free_count: usize = 0;
    // Käy jokainen kehysindeksi läpi.
    var i: usize = 0;
    // Toista frame_count kertaa.
    while (i < frame_count) : (i += 1) {
        // Bitmap-tavun indeksi.
        const byte_i = i / 8;
        // Bitin sijainti tavussa.
        const bit_i = i % 8;
        // Bitti 0 tarkoittaa vapaata kehystä.
        if ((bitmap[byte_i] & (@as(u8, 1) << @intCast(bit_i))) == 0) {
            // Kasvata laskuria.
            free_count += 1;
        }
    }
    // Palauta vapaiden kehysten määrä.
    return free_count;
}

// Host-testejä varten: suora bitmap-alustus annetulla puskurilla.
pub fn init(bitmap_buffer: []u8, total: usize) void {
    // Käytä annettua puskuria bitmapina.
    bitmap = bitmap_buffer;
    // Aseta kehysten määrä.
    frame_count = total;
    // Aloita indeksistä 0.
    next_free = 0;
    // Base-osoite 0 testeissä.
    mem_base = 0;
    // Alusta kaikki vapaaksi.
    @memset(bitmap, 0);
}
