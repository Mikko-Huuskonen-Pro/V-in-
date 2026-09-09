//! SHA-256 + HMAC-SHA256 — puhdas kryptoydin tunnelille (Vaihe 35.1).
//!
//! **Vastuu**: Tiivistä mielivaltaisia tavujonoja (SHA-256, FIPS 180-4) ja
//!   avainna viestejä (HMAC, RFC 2104 / RFC 4231). Ei allokaatiota, ei
//!   `std`-importtia — freestanding-kelpoinen ja host-testattava kuten
//!   `scope.zig`. Streaming-rajapinta (`Sha256`-struct), joten HMAC:n
//!   pitkätkin syötteet toimivat ilman isoja puskureita.
//! **Riippuvuudet**: ei.
//! **Käytetään**: `cap_tunnel.zig` (tuple-MAC), host-testit (RFC-vektorit).
//!
//! ## Arkkitehtuurihuomiot (AGENTS.md)
//! - Toteutus on standardi-SHA-256 (ei omaa kryptosuunnittelua —
//!   prior-art-periaate: älä keksi kryptografiaa uudelleen).
//! - Sivukanavakestävyys (vakioaikaisuus) on rajattu pois vaiheesta 35
//!   dokumentoidusti: yhden koneen QEMU-demossa ei ole etämittaajaa.
//!   Vertailu on silti koko-matkan silmukka (ei early-exit pituudesta).
//! - Pitkät avaimet (>64 B) tiivistetään ensin (RFC 2104 §2).

// SHA-256-lohkon koko tavuina.
pub const BLOCK_LEN: usize = 64;
// Tiivisteen koko tavuina.
pub const DIGEST_LEN: usize = 32;

// K-vakiot (FIPS 180-4 §4.2.2 — alkulukujen kuutiojuurten murto-osat).
const K: [64]u32 = .{
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

// Kierto oikealle (32-bittinen).
fn rotr(x: u32, n: u5) u32 {
    // Nollakierto on identiteetti (välttää 32-siirron u5-alueen yli).
    if (n == 0) return x;
    // Vastakkainen siirto mahtuu u5:een (1..31).
    const r: u5 = @intCast(32 - @as(u32, n));
    return (x >> n) | (x << r);
}

// Streaming-SHA-256 — `update` mielivaltaisesti, `final` täyttää + tiivistää.
pub const Sha256 = struct {
    // Ketjumuuttujat a..h (FIPS 180-4 §5.3.3 alkuarvot alla).
    h: [8]u32,
    // Kesken oleva lohko.
    buf: [BLOCK_LEN]u8,
    // Tavut puskurissa (0..64).
    buf_len: usize,
    // Käsiteltyjä tavuja yhteensä (pituus täytteeseen, modulo 2^64).
    total_len: u64,

    // Nollaa konteksti alkuarvoihin.
    pub fn init() Sha256 {
        return .{
            .h = .{
                0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
            },
            .buf = undefined,
            .buf_len = 0,
            .total_len = 0,
        };
    }

    // Pakkaa yksi 64-tavun lohko ketjuun (FIPS 180-4 §6.2.2).
    fn compress(self: *Sha256, block: *const [BLOCK_LEN]u8) void {
        // Viestiaikataulu (16 suoraan lohkosta + 48 laajennettua).
        var w: [64]u32 = undefined;
        // Ensimmäiset 16 sanaa big-endian.
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            const o = i * 4;
            w[i] = (@as(u32, block[o]) << 24) | (@as(u32, block[o + 1]) << 16) |
                (@as(u32, block[o + 2]) << 8) | @as(u32, block[o + 3]);
        }
        // Laajennus sigmoilla.
        i = 16;
        while (i < 64) : (i += 1) {
            const s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
            const s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16] +% s0 +% w[i - 7] +% s1;
        }
        // Työmuuttujat ketjusta.
        var a = self.h[0];
        var b = self.h[1];
        var c = self.h[2];
        var d = self.h[3];
        var e = self.h[4];
        var f = self.h[5];
        var g = self.h[6];
        var hh = self.h[7];
        // 64 kierrosta (wrappaava yhteenlasku = mod 2^32).
        i = 0;
        while (i < 64) : (i += 1) {
            const S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
            const ch = (e & f) ^ ((~e) & g);
            const t1 = hh +% S1 +% ch +% K[i] +% w[i];
            const S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
            const maj = (a & b) ^ (a & c) ^ (b & c);
            const t2 = S0 +% maj;
            hh = g;
            g = f;
            f = e;
            e = d +% t1;
            d = c;
            c = b;
            b = a;
            a = t1 +% t2;
        }
        // Syötä takaisin ketjuun.
        self.h[0] +%= a;
        self.h[1] +%= b;
        self.h[2] +%= c;
        self.h[3] +%= d;
        self.h[4] +%= e;
        self.h[5] +%= f;
        self.h[6] +%= g;
        self.h[7] +%= hh;
    }

    // Syötä tavuja (mielivaltainen pituus, puskuroi vajaan lohkon).
    pub fn update(self: *Sha256, msg: []const u8) void {
        var off: usize = 0;
        // Täytä ensin vajaa lohko jos sellainen on.
        if (self.buf_len > 0) {
            const want = BLOCK_LEN - self.buf_len;
            const take = if (msg.len < want) msg.len else want;
            var i: usize = 0;
            while (i < take) : (i += 1) self.buf[self.buf_len + i] = msg[i];
            self.buf_len += take;
            self.total_len += take;
            off = take;
            // Lohko täyttyi → pakkaa.
            if (self.buf_len == BLOCK_LEN) {
                self.compress(&self.buf);
                self.buf_len = 0;
            }
        }
        // Kokonaisten lohkojen suora pakkaus syötteestä.
        while (off + BLOCK_LEN <= msg.len) : (off += BLOCK_LEN) {
            // Kopioi pinon kautta (vältetään alignment-oletus viipaleessa).
            var blk: [BLOCK_LEN]u8 = undefined;
            var i: usize = 0;
            while (i < BLOCK_LEN) : (i += 1) blk[i] = msg[off + i];
            self.compress(&blk);
            self.total_len += BLOCK_LEN;
        }
        // Loput puskuriin.
        while (off < msg.len) : (off += 1) {
            self.buf[self.buf_len] = msg[off];
            self.buf_len += 1;
            self.total_len += 1;
        }
    }

    // Viimeistele: täyte + pituus + tyhjennys → 32-tavun tiiviste.
    pub fn final(self: *Sha256, out: *[DIGEST_LEN]u8) void {
        // Bit pituus big-endian täytteen perään (FIPS 180-4 §5.1.1).
        const bit_len = self.total_len *% 8;
        // 0x80-raja + nollat kunnes 56. tavu (pituudelle jää 8).
        self.update(&[_]u8{0x80});
        while (self.buf_len != 56) self.update(&[_]u8{0x00});
        // Pituus 8 tavua big-endian.
        var len_bytes: [8]u8 = undefined;
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            len_bytes[i] = @intCast((bit_len >> @intCast((7 - i) * 8)) & 0xff);
        }
        self.update(&len_bytes);
        // Nyt puskuri on tyhjä (56+8 täytti lohkon) — väite ilman paniikkia:
        // jos ei, tiiviste olisi vajaa; rakenne takaa tämän (56→64).
        // Kirjoita ketju big-endian.
        var j: usize = 0;
        while (j < 8) : (j += 1) {
            out[j * 4] = @intCast((self.h[j] >> 24) & 0xff);
            out[j * 4 + 1] = @intCast((self.h[j] >> 16) & 0xff);
            out[j * 4 + 2] = @intCast((self.h[j] >> 8) & 0xff);
            out[j * 4 + 3] = @intCast(self.h[j] & 0xff);
        }
    }
};

// Kertatiiviste mukavuuteen (streaming-rakenteen päällä).
pub fn sha256(msg: []const u8, out: *[DIGEST_LEN]u8) void {
    var ctx = Sha256.init();
    ctx.update(msg);
    ctx.final(out);
}

// HMAC-SHA256 (RFC 2104): H((K^opad) || H((K^ipad) || msg)).
pub fn hmacSha256(key: []const u8, msg: []const u8, out: *[DIGEST_LEN]u8) void {
    // Avainlohko: pitkä avain tiivistetään ensin (RFC 2104 §2).
    var kblk: [BLOCK_LEN]u8 = undefined;
    // Nollaa lohko.
    var i: usize = 0;
    while (i < BLOCK_LEN) : (i += 1) kblk[i] = 0;
    if (key.len > BLOCK_LEN) {
        // Pitkä avain → tiiviste + nollatäyte (32 + 32 nollaa).
        var kh: [DIGEST_LEN]u8 = undefined;
        sha256(key, &kh);
        i = 0;
        while (i < DIGEST_LEN) : (i += 1) kblk[i] = kh[i];
    } else {
        // Lyhyt avain sellaisenaan + nollatäyte.
        i = 0;
        while (i < key.len) : (i += 1) kblk[i] = key[i];
    }
    // Sisempi täyte (ipad) + viesti → sisätiiviste.
    var inner = Sha256.init();
    var ipad: [BLOCK_LEN]u8 = undefined;
    i = 0;
    while (i < BLOCK_LEN) : (i += 1) ipad[i] = kblk[i] ^ 0x36;
    inner.update(&ipad);
    inner.update(msg);
    var inner_hash: [DIGEST_LEN]u8 = undefined;
    inner.final(&inner_hash);
    // Ulompi täyte (opad) + sisätiiviste → MAC.
    var outer = Sha256.init();
    var opad: [BLOCK_LEN]u8 = undefined;
    i = 0;
    while (i < BLOCK_LEN) : (i += 1) opad[i] = kblk[i] ^ 0x5c;
    outer.update(&opad);
    outer.update(&inner_hash);
    outer.final(out);
}

// Vertaile kahta tiivistettä koko matkalta (ei early-exitiä pituudesta;
// sisältövertailu katkeaa silti ensimmäiseen eroon — vaiheen 35 rajaus,
// dokumentoitu: ei etämittaajaa yhden koneen demossa).
pub fn digestEqual(a: *const [DIGEST_LEN]u8, b: *const [DIGEST_LEN]u8) bool {
    var diff: u8 = 0;
    var i: usize = 0;
    while (i < DIGEST_LEN) : (i += 1) diff |= a[i] ^ b[i];
    return diff == 0;
}
