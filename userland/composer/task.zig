//! Task Description Language — canonical spec + text parser (Vaihe 34.1/34.2).
//!
//! **Vastuu**: Määrittele tehtävän binäärimuoto (`TaskSpec`) ja laske teksti
//!   siihen ilman allokaatiota. Ehdota — älä myönnä (AGENTS.md: AI proposes,
//!   kernel decides). Kernel (`kernel/composer.zig`) leikkaa tuloksen scopea
//!   vasten ennen kuin yhtäkään pluginia ladataan.
//! **Riippuvuudet**: ei (puhdas logiikka — freestanding + host-testattava,
//!   sama kaava kuin `scope.zig` / `plugin_manifest.zig`).
//! **Käytetään**: `userland/composer/resolve.zig` (heuristiikka),
//!   `kernel/composer.zig` (orkestraattori), host-testit.
//!
//! ## Arkkitehtuurihuomiot (AGENTS.md)
//! - TDL on pyyntö, ei lupa: parseri esikarsii rakenteen, `validate`
//!   semantiikan; kernel päättää jokaisen pluginin erikseen.
//! - Ei JSONia: ei `std.json`:ia freestanding-kernelissä; rivipohjainen
//!   `;`-eroteltu kielioppi parsitaan ilman rekursiota/allokaatiota.
//! - Tyyppi- ja oikeusnumerot ovat ABI-numeroita (1=port, 5=memory;
//!   bit0 read … bit5 grant) — sama layout kuin scope/manifest, jotta
//!   kernel-vertailu on bittitarkka eikä tulkinnanvarainen.
//! - Virhejärjestys on vakaa (BadName → … → BadBounds) kuten manifestissa,
//!   jotta vastalause nimeää aina yhden vian (informative failures).

// TDL-binäärimuodon versio — kernel hylkää muut (yhteensopivuusportti).
pub const TDL_VERSION: u32 = 1;
// Tehtävän nimen maksimipituus tavuina (manifest-pariteetti).
pub const MAX_NAME_LEN: usize = 32;
// Tarpeiden enimmäismäärä (manifest MAX_CAPS + rekisteri MAX_PLUGINS).
pub const MAX_NEEDS: usize = 8;
// Sallitut ABI-tyypit tarpeissa (vaihe 34: port + memory).
pub const CAP_TYPE_PORT: u32 = 1;
// Muisti-capability (Vaihe 28 mmap-perusta).
pub const CAP_TYPE_MEMORY: u32 = 5;
// Sallitut oikeusbitit (bit0..bit5, scope-layout).
pub const MASK_ALL: u32 = 0x3F;
// Timeout-alaraja tickeissä (0 = ei-koskaan ei kelpaa — ei ikuisia tehtäviä).
pub const MIN_TIMEOUT: u32 = 1;
// Timeout-yläraja tickeissä (miljoona riittää boot-demonstraatioon).
pub const MAX_TIMEOUT: u32 = 1000000;
// Oletus-timeout kun teksti ei aseta sitä.
pub const DEFAULT_TIMEOUT: u32 = 1000;
// Plugin-katon yläraja (loader.MAX_PLUGINS — ei luvata enempää kuin mahtuu).
pub const MAX_PLUGINS_CEIL: u32 = 8;

// Yksi capability-tarve tehtävässä.
pub const Need = struct {
    // ABI-tyyppi (1=port, 5=memory).
    cap_type: u32,
    // Pyydetyt oikeudet maskina (read/send/…).
    rights_mask: u32,
};

// Tehtävän kanoninen binäärimuoto — kiinteäkokoinen, ei allokaatiota.
pub const TaskSpec = struct {
    // Nimen tavut.
    name_buf: [MAX_NAME_LEN]u8,
    // Nimen pituus tavuina.
    name_len: usize,
    // Tarvelista.
    needs: [MAX_NEEDS]Need,
    // Montako tarvetta käytössä.
    needs_len: usize,
    // Elinaika tickeissä (deadline = start + timeout).
    timeout_ticks: u32,
    // Plugin-katto (montako pluginia tehtävä saa enintään viedä).
    max_plugins: u32,
    // Binäärimuodon versio (aina TDL_VERSION).
    version: u32,
};

// TDL-virheet vakassa validointijärjestyksessä (+ ParseError syntaksille).
pub const TaskError = error{
    // Tyhjä, liian pitkä tai ei-tulostettava nimi (myös `/`, `\`).
    BadName,
    // Väärä binääriversio.
    BadVersion,
    // Liikaa tarpeita (yli MAX_NEEDS).
    TooManyNeeds,
    // Tuntematon tar vetyyppi (vain port/memory).
    BadNeedType,
    // Varattu bitti tai tyhjä maski oikeuksissa.
    BadRights,
    // Rajavirhe: ei tarpeita, timeout/katto alueen ulkopuolella.
    BadBounds,
    // Tekstin syntaksivirhe (tuntematon lause, puuttuva merkki).
    ParseError,
};

// Onko ABI-tyyppi tarpeessa sallittu (vaihe 34: port + memory).
pub fn typeAllowed(cap_type: u32) bool {
    // Portti aina sallittu rakenne.
    if (cap_type == CAP_TYPE_PORT) return true;
    // Muisti sallittu (Vaihe 28 perusta).
    if (cap_type == CAP_TYPE_MEMORY) return true;
    // Muut (irq/endpoint/tuntematon) hylätään toistaiseksi.
    return false;
}

// Onko oikeusmaski rakenteellisesti kelvollinen (ei varattuja bittejä).
pub fn rightsValid(mask: u32) bool {
    // Kaikkien bittien pitää mahtua MASK_ALL:iin.
    return (mask & ~MASK_ALL) == 0;
}

// Validoi binäärimuotoinen tehtävä (ei scope-vertailua — sen tekee kernel).
pub fn validate(spec: TaskSpec) TaskError!void {
    // Nimi ei tyhjä eikä yli rajan.
    if (spec.name_len == 0 or spec.name_len > MAX_NAME_LEN) return error.BadName;
    // Nimen tavujen pitää olla tulostettavia ASCII-merkkejä.
    var i: usize = 0;
    // Käy nimen tavut.
    while (i < spec.name_len) : (i += 1) {
        // Hae yksi tavu.
        const c = spec.name_buf[i];
        // Hylkää kontrollimerkit ja ei-ASCII.
        if (c < 0x20 or c > 0x7E) return error.BadName;
        // Kauttaviiva erotinmerkkinä kielletty (polkuinjektio, manifest-kaava).
        if (c == '/' or c == '\\') return error.BadName;
    }
    // Version pitää täsmätä.
    if (spec.version != TDL_VERSION) return error.BadVersion;
    // Tarpeita pitää olla vähintään yksi (tyhjä tehtävä ei kokoonnu).
    if (spec.needs_len == 0) return error.BadBounds;
    // Tarpeita enintään MAX_NEEDS.
    if (spec.needs_len > MAX_NEEDS) return error.TooManyNeeds;
    // Käy jokainen tarve.
    var j: usize = 0;
    // Tarkista tyyppi + oikeudet.
    while (j < spec.needs_len) : (j += 1) {
        // Tyyppi sallittujen joukossa.
        if (!typeAllowed(spec.needs[j].cap_type)) return error.BadNeedType;
        // Oikeusmaski ilman varattuja bittejä.
        if (!rightsValid(spec.needs[j].rights_mask)) return error.BadRights;
        // Tyhjä oikeusmaski hyödytön — hylkää.
        if (spec.needs[j].rights_mask == 0) return error.BadRights;
    }
    // Timeout alueella (ei nollaa, ei ääretöntä).
    if (spec.timeout_ticks < MIN_TIMEOUT or spec.timeout_ticks > MAX_TIMEOUT) return error.BadBounds;
    // Plugin-katto alueella.
    if (spec.max_plugins == 0 or spec.max_plugins > MAX_PLUGINS_CEIL) return error.BadBounds;
}

// Onko merkki TDL-tekstin whitespace (merkityksetön nimen ulkopuolella).
fn isWs(c: u8) bool {
    // Väli, tabi, rivinvaihto, CR.
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

// Ohita whitespace tekstissä paikasta p eteenpäin.
fn skipWs(text: []const u8, p: *usize) void {
    // Käy kunnes ei-whitespace tai loppu.
    while (p.* < text.len and isWs(text[p.*])) : (p.* += 1) {}
}

// Täsmääkö sana paikassa p sanarajalla (ei osa pidempää tunnistetta).
fn matchWord(text: []const u8, p: usize, word: []const u8) bool {
    // Sana ei mahdu loppuun.
    if (p + word.len > text.len) return false;
    // Vertaa tavu kerrallaan.
    var i: usize = 0;
    while (i < word.len) : (i += 1) {
        if (text[p + i] != word[i]) return false;
    }
    // Rajamerkki perässä: loppu, whitespace tai erotin.
    if (p + word.len >= text.len) return true;
    const n = text[p + word.len];
    return isWs(n) or n == ':' or n == ';' or n == '{' or n == '}' or n == '+' or n == '"';
}

// Lue pieni kirjain-sana (a-z) — palauttaa pituuden tai 0.
fn readWord(text: []const u8, p: *usize) usize {
    // Sanan alku.
    const start = p.*;
    // Käy pieniä kirjaimia.
    while (p.* < text.len and text[p.*] >= 'a' and text[p.*] <= 'z') : (p.* += 1) {}
    // Palauta pituus.
    return p.* - start;
}

// Kuvaa oikeussana bittimaskiksi — 0 jos tuntematon.
fn rightBit(word: []const u8) u32 {
    // Vertaa jokaista tunnettua sanaa (pituus ensin, sitten tavut).
    if (word.len == 4 and word[0] == 'r' and word[1] == 'e' and word[2] == 'a' and word[3] == 'd') return 1 << 0;
    if (word.len == 5 and word[0] == 'w' and word[1] == 'r' and word[2] == 'i' and word[3] == 't' and word[4] == 'e') return 1 << 1;
    if (word.len == 4 and word[0] == 's' and word[1] == 'e' and word[2] == 'n' and word[3] == 'd') return 1 << 2;
    if (word.len == 4 and word[0] == 'r' and word[1] == 'e' and word[2] == 'c' and word[3] == 'v') return 1 << 3;
    if (word.len == 3 and word[0] == 'm' and word[1] == 'a' and word[2] == 'p') return 1 << 4;
    if (word.len == 5 and word[0] == 'g' and word[1] == 'r' and word[2] == 'a' and word[3] == 'n' and word[4] == 't') return 1 << 5;
    // Tuntematon oikeus.
    return 0;
}

// Onko sana tunnettu oikeus (erota "tyhjä maski" vs "tuntematon sana").
fn isKnownRight(word: []const u8) bool {
    return rightBit(word) != 0;
}

// Lue desimaaliluku — palauttaa arvon tai ParseError.
fn readNumber(text: []const u8, p: *usize) TaskError!u64 {
    // Numeroita pitää olla vähintään yksi.
    if (p.* >= text.len or text[p.*] < '0' or text[p.*] > '9') return error.ParseError;
    // Kertymä (u64 — ylivuoto leikataan, validate hylkää alueen).
    var acc: u64 = 0;
    // Käy numeroita.
    while (p.* < text.len and text[p.*] >= '0' and text[p.*] <= '9') : (p.* += 1) {
        // Saturating-keräys (ei kierrosta — iso luku hylätään rajalla).
        const d: u64 = text[p.*] - '0';
        if (acc > 0xFFFF_FFFF) {
            acc = 0xFFFF_FFFF_FFFF_FFFF;
        } else {
            acc = acc * 10 + d;
        }
    }
    return acc;
}

// Laske TDL-teksti binäärimuotoon (rakenteen esikarsinta + validate).
pub fn parse(text: []const u8) TaskError!TaskSpec {
    // Tyhjä kokoonpano (nollat, validate täydentää/tarkistaa).
    var spec: TaskSpec = .{
        .name_buf = undefined,
        .name_len = 0,
        .needs = undefined,
        .needs_len = 0,
        .timeout_ticks = 0,
        .max_plugins = 0,
        .version = TDL_VERSION,
    };
    // Lukuosoitin.
    var p: usize = 0;
    // Onko timeout/katto asetettu eksplisiittisesti (0 tekstissä = virhe,
    // ei oletus — oletus koskee vain puuttuvaa lausetta).
    var has_timeout = false;
    var has_plugins = false;
    // Ohita alun whitespace.
    skipWs(text, &p);
    // Vaadi avainsana task.
    if (!matchWord(text, p, "task")) return error.ParseError;
    p += 4;
    // Väli ennen nimeä.
    skipWs(text, &p);
    // Vaadi avaava lainausmerkki.
    if (p >= text.len or text[p] != '"') return error.ParseError;
    p += 1;
    // Nimen alku.
    const name_start = p;
    // Etsi sulkeva lainausmerkki.
    while (p < text.len and text[p] != '"') : (p += 1) {}
    // Sulkeva merkki puuttuu.
    if (p >= text.len) return error.ParseError;
    // Nimen pituus.
    const name_len = p - name_start;
    // Tyhjä tai liian pitkä nimi.
    if (name_len == 0 or name_len > MAX_NAME_LEN) return error.BadName;
    // Kopioi + tarkista tavut (tulostettava, ei `/`).
    var ni: usize = 0;
    while (ni < name_len) : (ni += 1) {
        const c = text[name_start + ni];
        if (c < 0x20 or c > 0x7E) return error.BadName;
        if (c == '/' or c == '\\') return error.BadName;
        spec.name_buf[ni] = c;
    }
    // Nollaa loput puskurista (deterministinen tavusisältö).
    while (ni < MAX_NAME_LEN) : (ni += 1) spec.name_buf[ni] = 0;
    spec.name_len = name_len;
    // Sulkevan lainausmerkin yli.
    p += 1;
    // Väli ennen lohkoa.
    skipWs(text, &p);
    // Vaadi avaava aaltosulje.
    if (p >= text.len or text[p] != '{') return error.ParseError;
    p += 1;
    // Käy lauseet sulkevaan sulkeeseen.
    while (true) {
        // Ohita erottimet/whitespace.
        skipWs(text, &p);
        // Loppu ilman suljetta.
        if (p >= text.len) return error.ParseError;
        // Sulkeva sulje päättää listan.
        if (text[p] == '}') {
            p += 1;
            break;
        }
        // Ylimääräinen puolipiste siedetään (idempotentti erotin).
        if (text[p] == ';') {
            p += 1;
            continue;
        }
        // need-lause.
        if (matchWord(text, p, "need")) {
            p += 4;
            skipWs(text, &p);
            // Lue tyyppisana.
            const t0 = p;
            const tlen = readWord(text, &p);
            // Tyyppi puuttuu.
            if (tlen == 0) return error.ParseError;
            const tword = text[t0..][0..tlen];
            // Kuvaa ABI-tyypiksi (tuntematon → BadNeedType, ei ParseError:
            // syy on semanttinen, jotta vastalause nimeää tyypin).
            var cap_type: u32 = 0;
            if (tlen == 4 and tword[0] == 'p' and tword[1] == 'o' and tword[2] == 'r' and tword[3] == 't') {
                cap_type = CAP_TYPE_PORT;
            } else if (tlen == 6 and tword[0] == 'm' and tword[1] == 'e' and tword[2] == 'm' and tword[3] == 'o' and tword[4] == 'r' and tword[5] == 'y') {
                cap_type = CAP_TYPE_MEMORY;
            } else {
                return error.BadNeedType;
            }
            skipWs(text, &p);
            // Vaadi kaksoispiste.
            if (p >= text.len or text[p] != ':') return error.ParseError;
            p += 1;
            skipWs(text, &p);
            // Lue oikeuslista (+-eroteltu, vähintään yksi).
            var mask: u32 = 0;
            var got_any = false;
            while (true) {
                const r0 = p;
                const rlen = readWord(text, &p);
                if (rlen == 0) return error.ParseError;
                const rword = text[r0..][0..rlen];
                if (!isKnownRight(rword)) return error.BadRights;
                mask |= rightBit(rword);
                got_any = true;
                // Kurkista erotinta (whitespacen yli).
                const save = p;
                skipWs(text, &p);
                if (p < text.len and text[p] == '+') {
                    p += 1;
                    skipWs(text, &p);
                    continue;
                }
                p = save;
                break;
            }
            if (!got_any or mask == 0) return error.BadRights;
            // Tarvekatto täynnä.
            if (spec.needs_len >= MAX_NEEDS) return error.TooManyNeeds;
            spec.needs[spec.needs_len] = .{ .cap_type = cap_type, .rights_mask = mask };
            spec.needs_len += 1;
            skipWs(text, &p);
            // Valinnainen puolipiste lauseen perässä.
            if (p < text.len and text[p] == ';') p += 1;
            continue;
        }
        // timeout-lause.
        if (matchWord(text, p, "timeout")) {
            p += 7;
            skipWs(text, &p);
            const v = try readNumber(text, &p);
            // Leikkaa u32-alueelle (validate hylkää ylisuuren BadBounds:lla).
            spec.timeout_ticks = if (v > 0xFFFF_FFFF) 0xFFFF_FFFF else @intCast(v);
            has_timeout = true;
            skipWs(text, &p);
            if (p < text.len and text[p] == ';') p += 1;
            continue;
        }
        // plugins-lause (katto).
        if (matchWord(text, p, "plugins")) {
            p += 7;
            skipWs(text, &p);
            const v = try readNumber(text, &p);
            spec.max_plugins = if (v > 0xFFFF_FFFF) 0xFFFF_FFFF else @intCast(v);
            has_plugins = true;
            skipWs(text, &p);
            if (p < text.len and text[p] == ';') p += 1;
            continue;
        }
        // Tuntematon lause → syntaksivirhe (fail-closed, ei ohitusta).
        return error.ParseError;
    }
    // Loppuroinaa ei sallita (deterministinen kokonaisuus).
    skipWs(text, &p);
    if (p != text.len) return error.ParseError;
    // Oletukset puuttuvalle (EI eksplisiittiselle nollalle): timeout 1000,
    // katto = tarpeiden määrä. Eksplisiittinen 0 kaatuu validate:ssa.
    if (!has_timeout) spec.timeout_ticks = DEFAULT_TIMEOUT;
    if (!has_plugins) spec.max_plugins = @intCast(spec.needs_len);
    // Semanttinen validointi vakaassa järjestyksessä.
    try validate(spec);
    return spec;
}
