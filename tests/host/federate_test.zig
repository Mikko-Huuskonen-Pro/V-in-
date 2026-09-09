//! Host-testit federaatiolle: HMAC + tunneli + välittäjä + migraatio + failover (Vaihe 35).
//!
//! **Vastuu**: Kryptovektorit (SHA-256 tyhjä/"abc", HMAC RFC 4231 testit 1–2),
//!   tunnelin seal/open + replay/tamper/haamu-hylkäykset, välittäjän reititys,
//!   migraatiotilakoneen siirtymät ja heartbeat/replika-politiikka.
//!   Ring-3-ajo + loader-orkestraatio ovat boot-testissä (`federate.zig`).

// Tuo standardikirjasto testiasserteja varten.
const std = @import("std");
// Tuo puhdas HMAC-ydin (vektorit).
const hmac = @import("fed_hmac");
// Tuo tunneliytdin (seal/open + ikkuna).
const tunnel = @import("fed_tunnel");
// Tuo etävälittäjä (reititys).
const forwarder = @import("remote_forwarder");
// Tuo migraatiotila (tilakone).
const migrate = @import("fed_migrate");
// Tuo klusteri + replika (failover).
const failover = @import("fed_failover");

// SHA-256("") FIPS 180-4 -vektori tavuina.
const SHA_EMPTY: [32]u8 = .{
    0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14,
    0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
    0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
    0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
};

// SHA-256("abc") -vektori.
const SHA_ABC: [32]u8 = .{
    0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea,
    0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
    0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c,
    0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
};

// RFC 4231 testi 1: avain 0x0b×20, data "Hi There".
const HMAC_T1: [32]u8 = .{
    0xb0, 0x34, 0x4c, 0x61, 0xd8, 0xdb, 0x38, 0x53,
    0x5c, 0xa8, 0xaf, 0xce, 0xaf, 0x0b, 0xf1, 0x2b,
    0x88, 0x1d, 0xc2, 0x00, 0xc9, 0x83, 0x3d, 0xa7,
    0x26, 0xe9, 0x37, 0x6c, 0x2e, 0x32, 0xcf, 0xf7,
};

// RFC 4231 testi 2: avain "Jefe", data "what do ya want for nothing?".
const HMAC_T2: [32]u8 = .{
    0x5b, 0xdc, 0xc1, 0x46, 0xbf, 0x60, 0x75, 0x4e,
    0x6a, 0x04, 0x24, 0x26, 0x08, 0x95, 0x75, 0xc7,
    0x5a, 0x00, 0x3f, 0x08, 0x9d, 0x27, 0x39, 0x83,
    0x9d, 0xec, 0x58, 0xb9, 0x64, 0xec, 0x38, 0x43,
};

test "hmac sha256 and rfc4231 vectors" {
    // Tyhjä viesti → FIPS-vektori.
    var d0: [32]u8 = undefined;
    hmac.sha256("", &d0);
    try std.testing.expect(hmac.digestEqual(&d0, &SHA_EMPTY));
    // "abc" → FIPS-vektori (yksiosainen + ositettu syöttö).
    var d1: [32]u8 = undefined;
    hmac.sha256("abc", &d1);
    try std.testing.expect(hmac.digestEqual(&d1, &SHA_ABC));
    var ctx = hmac.Sha256.init();
    ctx.update("a");
    ctx.update("bc");
    var d1s: [32]u8 = undefined;
    ctx.final(&d1s);
    try std.testing.expect(hmac.digestEqual(&d1s, &SHA_ABC));
    // Pitkä syöte yli lohkorajan (112 tavua → kaksi lohkoa täytteellä).
    var long: [112]u8 = undefined;
    var li: usize = 0;
    while (li < long.len) : (li += 1) long[li] = @intCast(li & 0xff);
    var dl: [32]u8 = undefined;
    hmac.sha256(&long, &dl);
    // Ositettu sama syöte → sama tiiviste (streaming-eheys).
    var ctx2 = hmac.Sha256.init();
    ctx2.update(long[0..7]);
    ctx2.update(long[7..100]);
    ctx2.update(long[100..]);
    var dl2: [32]u8 = undefined;
    ctx2.final(&dl2);
    try std.testing.expect(hmac.digestEqual(&dl, &dl2));
    // RFC 4231 testi 1.
    var k1: [20]u8 = undefined;
    var i: usize = 0;
    while (i < k1.len) : (i += 1) k1[i] = 0x0b;
    var m1: [32]u8 = undefined;
    hmac.hmacSha256(&k1, "Hi There", &m1);
    try std.testing.expect(hmac.digestEqual(&m1, &HMAC_T1));
    // RFC 4231 testi 2.
    var m2: [32]u8 = undefined;
    hmac.hmacSha256("Jefe", "what do ya want for nothing?", &m2);
    try std.testing.expect(hmac.digestEqual(&m2, &HMAC_T2));
    // Eri avain → eri MAC (avainherkkyys).
    var m3: [32]u8 = undefined;
    hmac.hmacSha256("Jefa", "what do ya want for nothing?", &m3);
    try std.testing.expect(!hmac.digestEqual(&m2, &m3));
}

test "tunnel seal open replay tamper ghost" {
    // Kiinteä testiavain 1..32.
    var key: [32]u8 = undefined;
    var ki: usize = 0;
    while (ki < key.len) : (ki += 1) key[ki] = @intCast(ki + 1);
    var tun = tunnel.Tunnel.init(key);
    // Liitokset: A=1, B=2 (nolla hylätään, kaksoisjoin OK).
    try tun.addPeer(1);
    try tun.addPeer(2);
    try tun.addPeer(1);
    try std.testing.expectError(error.NoSlot, tun.addPeer(0));
    try std.testing.expectEqual(@as(usize, 2), tun.peerCount());
    // Sulje A→B (nonce alkaa 1:stä — 0 ei koskaan lähde).
    const s1 = tun.sealNext(1, 42, 3, 2, 0x0c);
    try std.testing.expectEqual(@as(u64, 1), s1.grant.nonce);
    // Avaa: kentät palaavat ehjinä.
    const g1 = try tun.open(&s1);
    try std.testing.expectEqual(@as(u32, 1), g1.src_node);
    try std.testing.expectEqual(@as(u64, 42), g1.src_pid);
    try std.testing.expectEqual(@as(u32, 3), g1.src_slot);
    try std.testing.expectEqual(@as(u32, 2), g1.dest_node);
    try std.testing.expectEqual(@as(u32, 0x0c), g1.rights_mask);
    // Uusinta samalla kuorella → Replay (ikkuna ei edennyt hylkäyksellä).
    try std.testing.expectError(error.Replay, tun.open(&s1));
    // Peukaloitu maski tuoreella noncella → BadMac (uusinta tarkistetaan ensin).
    var evil = tun.sealNext(1, 42, 3, 2, 0x0c);
    evil.grant.rights_mask ^= 0x04;
    try std.testing.expectError(error.BadMac, tun.open(&evil));
    // Liittymätön haamu (MAC validi, vertainen ei) → UnknownPeer.
    const ghost = tun.sealNext(9, 7, 0, 2, 0x08);
    var gw = ghost;
    try std.testing.expectError(error.UnknownPeer, tun.open(&gw));
    // Seuraava kelvollinen etenee (nonce 4 — evil+haamu kuluttivat 2:n ja 3:n).
    const s2 = tun.sealNext(1, 42, 3, 2, 0x08);
    try std.testing.expectEqual(@as(u64, 4), s2.grant.nonce);
    _ = try tun.open(&s2);
    // Väärä avain → BadMac (avaimen vaihto hylkää vanhat kuoret).
    tun.key[0] ^= 0xff;
    const s3 = tun.sealNext(1, 42, 3, 2, 0x08);
    tun.key[0] ^= 0xff;
    var w3 = s3;
    try std.testing.expectError(error.BadMac, tun.open(&w3));
    // Vertaisen poisto sulkee portin (lähtö nollaa ikkunan).
    try std.testing.expect(tun.removePeer(2));
    try std.testing.expect(!tun.removePeer(2));
    try std.testing.expectEqual(@as(usize, 1), tun.peerCount());
}

test "forwarder register route send unregister" {
    // Tyhjä välittäjä.
    var fwd = forwarder.Forwarder.init();
    try std.testing.expectEqual(@as(usize, 0), fwd.countActive());
    // Nollasolmu hylätään.
    try std.testing.expectError(error.BadNode, fwd.register(0, 1, 0x0c));
    // Rekisteröi B:hen (idempotentti kaksoisrekisteri → sama indeksi).
    const idx = try fwd.register(2, 5, 0x0c);
    try std.testing.expectEqual(idx, try fwd.register(2, 5, 0x0c));
    try std.testing.expectEqual(@as(usize, 1), fwd.countActive());
    // Haku + reititys täsmäävät.
    const r = fwd.lookup(idx) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u32, 2), r.node_id);
    try std.testing.expectEqual(@as(u32, 5), r.remote_slot);
    try std.testing.expectEqual(@as(?usize, idx), fwd.route(2, 5));
    // Vieras pari ei reitity.
    try std.testing.expectEqual(@as(?usize, null), fwd.route(9, 5));
    try std.testing.expectEqual(@as(?usize, null), fwd.route(2, 6));
    // Lähetystarkistus: pituusrajat (port-pariteetti 32).
    try fwd.checkSend(idx, 4);
    try std.testing.expectError(error.BadLength, fwd.checkSend(idx, 0));
    try std.testing.expectError(error.BadLength, fwd.checkSend(idx, 33));
    try std.testing.expectError(error.UnknownRoute, fwd.checkSend(7, 4));
    // Täytä taulukko (1 käytössä + 7 uutta) → seuraava TableFull.
    var n: u32 = 10;
    while (n < 17) : (n += 1) _ = try fwd.register(n, 0, 0x01);
    try std.testing.expectEqual(@as(usize, 8), fwd.countActive());
    try std.testing.expectError(error.TableFull, fwd.register(99, 0, 0x01));
    // Purku vapauttaa rivin (kaksoispurku false).
    try std.testing.expect(fwd.unregister(idx));
    try std.testing.expect(!fwd.unregister(idx));
    try std.testing.expectEqual(@as(usize, 7), fwd.countActive());
    try std.testing.expectEqual(@as(?usize, null), fwd.route(2, 5));
}

test "migrate staged pushed restored done and aborts" {
    // Onnellinen polku päästä päähän.
    var p = migrate.MigrationPlan.init();
    try p.stage(7, 1, 2);
    try p.notePushed(2, 2);
    try p.noteRestored();
    try p.finish();
    try std.testing.expectEqual(migrate.MigrationState.done, p.state);
    try std.testing.expect(p.isTerminal());
    // Valmis ei abortoidu.
    p.abort();
    try std.testing.expectEqual(migrate.MigrationState.done, p.state);
    // Rakennevirheet: haamu, nolla, itsesilmukka.
    var bad = migrate.MigrationPlan.init();
    try std.testing.expectError(error.BadPlan, bad.stage(0, 1, 2));
    try std.testing.expectError(error.BadPlan, bad.stage(7, 0, 2));
    try std.testing.expectError(error.BadPlan, bad.stage(7, 1, 1));
    // Osittainen työntö ei kelpaa (tila jää staged — abortti erikseen).
    var part = migrate.MigrationPlan.init();
    try part.stage(7, 1, 2);
    try std.testing.expectError(error.PartialPush, part.notePushed(1, 2));
    try std.testing.expectEqual(migrate.MigrationState.staged, part.state);
    part.abort();
    try std.testing.expectEqual(migrate.MigrationState.aborted, part.state);
    // Väärät siirtymät (restored ennen pushia, finish ennen restorea).
    var seq = migrate.MigrationPlan.init();
    try seq.stage(7, 1, 2);
    try std.testing.expectError(error.BadTransition, seq.noteRestored());
    try std.testing.expectError(error.BadTransition, seq.finish());
    // Kaksois-stage kesken olevaan hylätään.
    try std.testing.expectError(error.BadTransition, seq.stage(8, 1, 2));
}

test "failover heartbeat sweep replica" {
    // Klusteri: A + B liittyvät (nolla hylätään).
    var c = failover.Cluster.init();
    try std.testing.expect(c.join(1, 0));
    try std.testing.expect(c.join(2, 0));
    try std.testing.expect(!c.join(0, 0));
    try std.testing.expectEqual(@as(usize, 2), c.aliveCount());
    // Vieras syke ei herätä riviä.
    try std.testing.expect(!c.heartbeat(9, 50));
    // B sykkii tuoreena; sweep vanhentaa vain A:n.
    try std.testing.expect(c.heartbeat(2, 950));
    const dead = c.sweep(1000, 100);
    try std.testing.expectEqual(@as(usize, 1), dead);
    try std.testing.expect(!c.isAlive(1));
    try std.testing.expect(c.isAlive(2));
    try std.testing.expect(!c.isAlive(9));
    // Replika: koti A, vara B, palveleva pid asetettu.
    var rep = failover.ReplicaPlan.init(1, 2);
    try std.testing.expect(rep.valid());
    rep.noteServing(77);
    // Väärä vainaja ei liikuta.
    try std.testing.expectEqual(failover.ReplicaState.primary, rep.promoteOnLoss(2, false, true));
    // Koti elää (sweep-virhe) → ei liikettä.
    try std.testing.expectEqual(failover.ReplicaState.primary, rep.promoteOnLoss(1, true, true));
    // Koti kuollut + vara elää → replikoi.
    try std.testing.expectEqual(failover.ReplicaState.replicated, rep.promoteOnLoss(1, false, true));
    // Vara kuollut → orpous (näkyvä, ei hiljainen sijoitus).
    var rep2 = failover.ReplicaPlan.init(1, 2);
    rep2.noteServing(78);
    try std.testing.expectEqual(failover.ReplicaState.orphaned, rep2.promoteOnLoss(1, false, false));
    // Ei palvelevaa pidiä → orpous vaikka vara eläisi.
    var rep3 = failover.ReplicaPlan.init(1, 2);
    try std.testing.expectEqual(failover.ReplicaState.orphaned, rep3.promoteOnLoss(1, false, true));
    // Rakenne: nolla/kaksoissolmu kelvoton.
    try std.testing.expect(!failover.ReplicaPlan.init(0, 2).valid());
    try std.testing.expect(!failover.ReplicaPlan.init(1, 1).valid());
    // Siisti lähtö vapauttaa rivin.
    try std.testing.expect(c.leave(2));
    try std.testing.expectEqual(@as(usize, 0), c.aliveCount());
}
