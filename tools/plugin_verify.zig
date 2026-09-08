//! Plugin-asennuksen varmennin — host-työkalu vaiheeseen 32.4.
//!
//! **Vastuu**: Lue `zig build plugin-install` -askeleen kirjoittama pyyntö,
//!   varmenna paketin Ed25519-allekirjoitus luotetulla julkisella avaimella,
//!   kopioi kelvollinen paketti paikalliseen rekisterihakemistoon.
//! **Riippuvuudet**: `../userland/plugin_registry/package.zig`, std (host)
//! **Käytetään**: `build.zig` (`plugin-install`-askel ajaa tämän)
//!
//! ## Arkkitehtuurihuomiot
//! - Ei CLI-argumentteja: pyyntötiedosto kiinteässä polussa
//!   (`zig-out/plugin-install/request`, 4 riviä: paketti, pubkey-hex,
//!   kohdehakemisto, kohdenimi). Koneajettu askel ei tarvitse argv-parseria.
//! - Poistumiskoodi 0 = asennettu; muu = hylätty (syy serialissa).
//!   Build-askel kaatuu nollasta poikkeavaan — allekirjoittamaton paketti
//!   ei koskaan päädy rekisteriin.
//! - Luottamus tulee KUTSujan avaimesta (-Dplugin-key), ei paketista:
//!   paketti kantaa vain manifestin + allekirjoituksen (ei pubkeytä).

// Tuo Zig std — host-työkalu (Io-tiedostot, Ed25519, fmt).
const std = @import("std");
// Tuo pakettiformaatti — kehys + kanonisointi (build.zig-moduuli).
const pkg = @import("registry_package");

// Pyyntötiedoston polku (build-askel kirjoittaa).
const REQUEST_PATH = "zig-out/plugin-install/request";
// Pyyntörivien määrä.
const REQUEST_LINES = 4;

// Varmentimen virheet — selkeä syy ennen nollasta poikkeavaa poistumista.
const VerifyError = error{
    // Pyyntötiedosto puuttuu tai vajaat rivit.
    BadRequest,
    // Pakettitiedostoa ei luettu.
    BadPackageFile,
    // Pubkey-hex väärä pituus tai ei-hex.
    BadPubkey,
    // Pakettikehys rikki.
    BadFraming,
    // Manifesti ei kelpaa.
    BadManifestContent,
    // Allekirjoitus ei täsmää (tai avain väärä).
    BadSignature,
    // Kohdekirjoitus epäonnistui.
    InstallFailed,
};

// Hex-merkin arvo (0-15) tai null.
fn hexVal(c: u8) ?u4 {
    // Numerot.
    if (c >= '0' and c <= '9') return @intCast(c - '0');
    // Pienet.
    if (c >= 'a' and c <= 'f') return @intCast(10 + (c - 'a'));
    // Isot.
    if (c >= 'A' and c <= 'F') return @intCast(10 + (c - 'A'));
    // Ei hex.
    return null;
}

// Pura rivit pyynnöstä (4 riviä, \n-erotin, \r siedetään).
fn splitRequest(text: []const u8, out: *[REQUEST_LINES][]const u8) VerifyError!void {
    // Rivin alku.
    var start: usize = 0;
    // Rivimäärä.
    var n: usize = 0;
    // Käy teksti + terminaattori.
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        // Rivinvaihto tai loppu.
        if (i == text.len or text[i] == '\n') {
            // Riviviipale.
            var line = text[start..i];
            // Seuraava alkaa.
            start = i + 1;
            // Poista \r.
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            // Tyhjä lopputeksti ohitetaan (viimeinen \n).
            if (line.len == 0 and i == text.len) break;
            // Liikaa rivejä.
            if (n >= REQUEST_LINES) return error.BadRequest;
            // Tallenna.
            out[n] = line;
            n += 1;
        }
    }
    // Tasan 4 riviä vaaditaan.
    if (n != REQUEST_LINES) return error.BadRequest;
}

// Pura 64 hex-merkkiä 32 tavuksi.
fn parsePubkey(hex: []const u8, out: *[32]u8) VerifyError!void {
    // Tasan 64 merkkiä.
    if (hex.len != 64) return error.BadPubkey;
    // Käy tavut.
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        // Ylä- ja alanibble.
        const hi = hexVal(hex[i * 2]) orelse return error.BadPubkey;
        const lo = hexVal(hex[i * 2 + 1]) orelse return error.BadPubkey;
        // Yhdistä (levennys ensin — u4 ei pidä kerrointa 16).
        out[i] = hi * @as(u8, 16) + lo;
    }
}

// Pääohjelma — lue pyyntö, varmenna, asenna.
pub fn main() !void {
    // Io-alusta (single-threaded riittää työkalulle).
    var threaded = std.Io.Threaded.init_single_threaded;
    // Io-kahva.
    const io: std.Io = threaded.io();
    // Allokaattori (sivut, ei seurantaa).
    const alloc = std.heap.page_allocator;
    // Työhakemisto = projektin juuri (build-askel ajaa sieltä).
    const cwd = std.Io.Dir.cwd();
    // Lue pyyntö (max 1 KiB).
    const req_text = std.Io.Dir.readFileAlloc(cwd, io, REQUEST_PATH, alloc, .limited(1024)) catch {
        // Pyyntö puuttuu.
        std.debug.print("plugin-verify: missing request {s}\n", .{REQUEST_PATH});
        // Hylkää.
        return error.BadRequest;
    };
    // Pilko 4 riviin.
    var lines: [REQUEST_LINES][]const u8 = undefined;
    // Väärä rivimäärä.
    splitRequest(req_text, &lines) catch {
        // Rakenne rikki.
        std.debug.print("plugin-verify: bad request format\n", .{});
        // Hylkää.
        return error.BadRequest;
    };
    // Rivi 0: paketin polku. Rivi 1: luotettu pubkey-hex.
    // Rivi 2: kohdehakemisto. Rivi 3: kohdenimi.
    const pkg_path = lines[0];
    const key_hex = lines[1];
    const dest_dir = lines[2];
    const dest_name = lines[3];
    // Pura pubkey.
    var pubkey: [32]u8 = undefined;
    // Väärä avainmuoto.
    parsePubkey(key_hex, &pubkey) catch {
        // Avain rikki.
        std.debug.print("plugin-verify: bad pubkey hex\n", .{});
        // Hylkää.
        return error.BadPubkey;
    };
    // Lue paketti (max 1 KiB — formaatti on 182 tavua).
    const pkg_bytes = std.Io.Dir.readFileAlloc(cwd, io, pkg_path, alloc, .limited(1024)) catch {
        // Tiedosto puuttuu.
        std.debug.print("plugin-verify: cannot read {s}\n", .{pkg_path});
        // Hylkää.
        return error.BadPackageFile;
    };
    // Pura kehys (magia + pituus).
    const unframed = pkg.unframePackage(pkg_bytes) catch {
        // Kehys rikki.
        std.debug.print("plugin-verify: bad package framing\n", .{});
        // Hylkää.
        return error.BadFraming;
    };
    // Dekoodaa + validoi manifesti.
    const m = pkg.decodeCanonical(unframed.canonical) catch {
        // Sisältö ei kelpaa.
        std.debug.print("plugin-verify: bad manifest content\n", .{});
        // Hylkää.
        return error.BadManifestContent;
    };
    // Kokoa avain + allekirjoitus std-tyypeiksi.
    const pk = std.crypto.sign.Ed25519.PublicKey.fromBytes(pubkey) catch {
        // Avain ei-käypä (ei-kanoninen).
        std.debug.print("plugin-verify: non-canonical pubkey\n", .{});
        // Hylkää.
        return error.BadPubkey;
    };
    // Allekirjoitus tavuista.
    const sig = std.crypto.sign.Ed25519.Signature.fromBytes(unframed.signature.*);
    // Varmenna kanoniset tavut avaimella.
    sig.verify(unframed.canonical, pk) catch {
        // Allekirjoitus ei täsmää — paketti EI asennu.
        std.debug.print("plugin-verify: SIGNATURE REJECTED for '{s}'\n", .{m.name_buf[0..m.name_len]});
        // Hylkää.
        return error.BadSignature;
    };
    // Kohdepolku: hakemisto + nimi (puskuri pinossa).
    var dest_path: [256]u8 = undefined;
    // Rakenna polku.
    const dest_full = std.fmt.bufPrint(&dest_path, "{s}/{s}", .{ dest_dir, dest_name }) catch {
        // Polku liian pitkä.
        std.debug.print("plugin-verify: dest path too long\n", .{});
        // Hylkää.
        return error.InstallFailed;
    };
    // Kopioi varmennettu paketti rekisteriin.
    std.Io.Dir.writeFile(cwd, io, .{ .sub_path = dest_full, .data = pkg_bytes }) catch {
        // Kirjoitus epäonnistui.
        std.debug.print("plugin-verify: install write failed\n", .{});
        // Hylkää.
        return error.InstallFailed;
    };
    // Yhteenveto serialiin (nimi + versio + cap-määrä).
    std.debug.print("plugin-verify: INSTALLED '{s}' v{} ({} caps) -> {s}\n", .{ m.name_buf[0..m.name_len], m.version, m.caps_len, dest_full });
}
