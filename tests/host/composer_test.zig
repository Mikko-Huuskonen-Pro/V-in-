//! Host-testit TDL-parserille + composer-heuristiikalle + decomposerille (Vaihe 34).
//!
//! **Vastuu**: TDL-tekstin laskenta binäärimuotoon, ratkaisun 1:1-minimaalisuus
//!   ja kaventamattomuus, katto-ristiriidan hylkäys sekä LIFO/timeout-politiikka.
//!   Ring 3 -ajo + hot-load ovat boot-testissä (`kernel/composer.zig`).

// Tuo standardikirjasto testiasserteja varten.
const std = @import("std");
// Tuo puhdas TDL-ydin (parse + validate).
const task = @import("composer_task");
// Tuo ratkaisuheuristiikka (tarve → PluginReq).
const resolve = @import("composer_resolve");
// Tuo purkupolitiikka (LIFO + timeout, riippuvuudeton).
const decomposer = @import("decomposer_core");

test "tdl parse demo task and validate" {
    // Demo-tehtävä (sama kuin boot-testi).
    const demo = "task \"http+uptime\" { need port:send+recv; need port:recv; timeout 1000; plugins 2; }";
    // Laske binäärimuotoon.
    const spec = try task.parse(demo);
    // Nimi täsmää.
    try std.testing.expectEqual(@as(usize, 11), spec.name_len);
    try std.testing.expectEqualSlices(u8, "http+uptime", spec.name_buf[0..spec.name_len]);
    // Kaksi tarvetta.
    try std.testing.expectEqual(@as(usize, 2), spec.needs_len);
    // Ensimmäinen: portti send+recv.
    try std.testing.expectEqual(task.CAP_TYPE_PORT, spec.needs[0].cap_type);
    try std.testing.expectEqual(@as(u32, (1 << 2) | (1 << 3)), spec.needs[0].rights_mask);
    // Toinen: portti recv.
    try std.testing.expectEqual(task.CAP_TYPE_PORT, spec.needs[1].cap_type);
    try std.testing.expectEqual(@as(u32, 1 << 3), spec.needs[1].rights_mask);
    // Rajat tekstistä.
    try std.testing.expectEqual(@as(u32, 1000), spec.timeout_ticks);
    try std.testing.expectEqual(@as(u32, 2), spec.max_plugins);
    // Versio lukittu.
    try std.testing.expectEqual(task.TDL_VERSION, spec.version);
    // Validointi läpi.
    try task.validate(spec);
}

test "tdl parse rejects bad syntax and bad values" {
    // Tuntematon lause → ParseError (fail-closed, ei ohitusta).
    try std.testing.expectError(error.ParseError, task.parse("task \"x\" { frobnicate; }"));
    // Sulkematon lohko → ParseError.
    try std.testing.expectError(error.ParseError, task.parse("task \"x\" { need port:send;"));
    // Tyhjä nimi → BadName.
    try std.testing.expectError(error.BadName, task.parse("task \"\" { need port:send; }"));
    // Kauttaviiva nimessä → BadName (polkuinjektio).
    try std.testing.expectError(error.BadName, task.parse("task \"a/b\" { need port:send; }"));
    // Tuntematon tar vetyyppi → BadNeedType.
    try std.testing.expectError(error.BadNeedType, task.parse("task \"x\" { need irq:read; }"));
    // Tuntematon oikeus → BadRights.
    try std.testing.expectError(error.BadRights, task.parse("task \"x\" { need port:execute; }"));
    // Nolla tarvetta → BadBounds (tyhjä tehtävä ei kokoonnu).
    try std.testing.expectError(error.BadBounds, task.parse("task \"x\" { timeout 10; plugins 1; }"));
    // Eksplisiittinen timeout 0 → BadBounds (ei hiljaista oletusta).
    try std.testing.expectError(error.BadBounds, task.parse("task \"x\" { need port:send; timeout 0; }"));
    // Plugin-katto yli rekisterin → BadBounds.
    try std.testing.expectError(error.BadBounds, task.parse("task \"x\" { need port:send; plugins 9; }"));
    // Yhdeksän tarvetta → TooManyNeeds.
    try std.testing.expectError(
        error.TooManyNeeds,
        task.parse("task \"x\" { need port:send; need port:send; need port:send; need port:send; need port:send; need port:send; need port:send; need port:send; need port:send; }"),
    );
    // Väärä versio binäärissä → BadVersion.
    var spec = try task.parse("task \"x\" { need port:send; }");
    spec.version = 2;
    try std.testing.expectError(error.BadVersion, task.validate(spec));
    // Oletukset: ilman timeout/kattoa timeout=1000, katto=tarpeet.
    const bare = try task.parse("task \"solo\" { need memory:read+map; }");
    try std.testing.expectEqual(task.DEFAULT_TIMEOUT, bare.timeout_ticks);
    try std.testing.expectEqual(@as(u32, 1), bare.max_plugins);
    try std.testing.expectEqual(task.CAP_TYPE_MEMORY, bare.needs[0].cap_type);
}

test "resolve maps needs one to one without broadening" {
    // Demo-spec.
    const spec = try task.parse("task \"http+uptime\" { need port:send+recv; need port:recv; timeout 1000; plugins 2; }");
    // Ratkaise puskuriin.
    var buf: [8]resolve.PluginReq = undefined;
    const n = try resolve.resolve(spec, &buf);
    // 1:1-minimaalisuus: kaksi tarvetta → kaksi vaatimusta.
    try std.testing.expectEqual(@as(usize, 2), n);
    // Vain tunnettu binääri.
    try std.testing.expectEqual(@as(u64, 0), buf[0].embedded_id);
    // Tyypit kopioitu kutistamatta.
    try std.testing.expectEqual(spec.needs[0].cap_type, buf[0].req_type);
    try std.testing.expectEqual(spec.needs[1].cap_type, buf[1].req_type);
    // Scope-oikeudet == tarve (ei laajennusta).
    try std.testing.expectEqual(spec.needs[0].rights_mask, buf[0].scope_rights);
    try std.testing.expectEqual(spec.needs[1].rights_mask, buf[1].scope_rights);
    // Scope-tyyppi yksibittinen portti (bitti 1).
    try std.testing.expectEqual(@as(u32, 1 << 1), buf[0].scope_types);
    // Kaventamattomuus molemmille.
    try std.testing.expect(resolve.reqNarrowsNeed(spec.needs[0], buf[0]));
    try std.testing.expect(resolve.reqNarrowsNeed(spec.needs[1], buf[1]));
    // Eskaloitu vaatimus (grant ilman tarvetta) ei kavenna.
    var evil = buf[1];
    evil.req_rights |= 1 << 5;
    evil.scope_rights |= 1 << 5;
    try std.testing.expect(!resolve.reqNarrowsNeed(spec.needs[1], evil));
    // Väärä tyyppi ei kavenna.
    var wrong = buf[0];
    wrong.req_type = task.CAP_TYPE_MEMORY;
    try std.testing.expect(!resolve.reqNarrowsNeed(spec.needs[0], wrong));
}

test "resolve rejects ceiling contradiction" {
    // Kaksi tarvetta, katto 1 → ristiriitainen tehtävä hylätään.
    const tight = try task.parse("task \"tight\" { need port:send; need port:recv; timeout 100; plugins 1; }");
    var buf: [8]resolve.PluginReq = undefined;
    try std.testing.expectError(error.TooManyPlugins, resolve.resolve(tight, &buf));
    // Liian pieni puskuri → sama hylkäys (ei osittaista suunnitelmaa).
    const roomy = try task.parse("task \"pair\" { need port:send; need port:recv; }");
    var small: [1]resolve.PluginReq = undefined;
    try std.testing.expectError(error.TooManyPlugins, resolve.resolve(roomy, &small));
}

test "decomposer lifo order and expiry" {
    // Kolmen pluginin purkujärjestys: uusin ensin (2,1,0).
    var order: [3]usize = undefined;
    const n = decomposer.lifoOrder(3, &order);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(usize, 2), order[0]);
    try std.testing.expectEqual(@as(usize, 1), order[1]);
    try std.testing.expectEqual(@as(usize, 0), order[2]);
    // Yksi askel kerrallaan.
    try std.testing.expectEqual(@as(usize, 2), decomposer.lifoAt(3, 0));
    try std.testing.expectEqual(@as(usize, 0), decomposer.lifoAt(3, 2));
    // Tyhjä koostumus on triviaalisti purettu.
    try std.testing.expect(decomposer.isEmpty(0));
    try std.testing.expect(!decomposer.isEmpty(2));
    // Timeout: alussa ei erääntynyt, rajalla erääntynyt.
    try std.testing.expect(!decomposer.isExpired(0, 1000));
    try std.testing.expect(!decomposer.isExpired(999, 1000));
    try std.testing.expect(decomposer.isExpired(1000, 1000));
    try std.testing.expect(decomposer.isExpired(5000, 1000));
    // Purkupäätös: valmis TAI erääntynyt TAI vika.
    try std.testing.expect(decomposer.shouldDecompose(true, false, false));
    try std.testing.expect(decomposer.shouldDecompose(false, true, false));
    try std.testing.expect(decomposer.shouldDecompose(false, false, true));
    try std.testing.expect(!decomposer.shouldDecompose(false, false, false));
    // Tietue kantaa nimen + deadlinen.
    const comp = decomposer.initComposition("http+uptime", 0, 1000);
    try std.testing.expectEqual(@as(usize, 11), comp.name_len);
    try std.testing.expectEqual(@as(u64, 1000), comp.deadline_ticks);
    try std.testing.expect(!comp.active);
}
