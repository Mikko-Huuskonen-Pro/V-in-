//! Composer-heuristiikka — tehtävä → plugin-vaatimukset (Vaihe 34.2).
//!
//! **Vastuu**: Ehdota jokaiseen `Need`:iin yksi `PluginReq` (upotettu binääri,
//!   kutistamaton scope). Deterministinen sääntötaulu — tulevan AI-composerin
//!   tyhmä sijainen. Ei myönnä mitään: kernel validoi jokaisen vaatimuksen
//!   manifesti+scope-portin läpi ennen latausta.
//! **Riippuvuudet**: `composer_task` (build-moduuli — sama kaava kuin
//!   `plugin_manifest`: suhteellinen cross-root-`@import` on Zig 0.16:ssa
//!   kielletty, joten molemmat verkot (host/kernel) kytkevät saman
//!   `task.zig`-instanssin nimellä; kahta instanssia ei synny).
//! **Käytetään**: `kernel/composer.zig`, host-testit.
//!
//! ## Arkkitehtuurihuomiot (AGENTS.md: AI proposes, kernel decides)
//! - 1:1-minimaalisuus: N tarvetta → N vaatimusta. Ei bonus-plugineja, ei
//!   yhdistelyä (yhdistely jakaisi yhden osoiteavaruuden ja heikentäisi I2:ta).
//! - Ei laajennusta: `scope_rights == req_rights` aina. Tarve ilman `grant`:ia
//!   tuottaa scopen ilman `grant`:ia — eskalaatio on rakenteellisesti mahdoton.
//! - Yksityyppiset scopet: portti-plugin ei voi luoda muisti-capeja eikä
//!   päinvastoin (I3 pidetään pienenä ja eksplisiittisenä).
//! - Katto-ristiriita (`needs_len > max_plugins`) hylätään TooManyPlugins:lla —
//!   kernel kieltäytyy mieluummin kuin pudottaa tarpeita hiljaa.

// Tuo puhdas TDL-ydin (build-moduuli — host + kernel jakavat instanssin).
const task = @import("composer_task");

// Oletus-cap-katto per sävelletty plugin (Phase 30 boot-testin konventio).
pub const DEFAULT_PLUGIN_CAPS: u32 = 4;

// Heuristiikan virheet (TaskError erikseen — nämä ovat ratkaisuvirheitä).
pub const ResolveError = error{
    // Tarpeita enemmän kuin tehtävän plugin-katto sallii (ristiriitainen tehtävä).
    TooManyPlugins,
    // Tuntematon plugin-binääri (vaihe 34: vain upotettu 0).
    UnknownPlugin,
};

// Yksi plugin-vaatimus kernelin compose-portille.
pub const PluginReq = struct {
    // Upotettu binääritunniste (vaihe 34: aina 0).
    embedded_id: u64,
    // Pyydetty ABI-tyyppi (1=port, 5=memory).
    req_type: u32,
    // Pyydetyt oikeudet (kutistamaton kopio tarpeesta).
    req_rights: u32,
    // Ehdotettu scope-tyyppimaski (yksi bitti).
    scope_types: u32,
    // Ehdotettu scope-oikeusmaski (== req_rights, ei laajennusta).
    scope_rights: u32,
    // Ehdotettu cap-katto.
    max_caps: u32,
};

// Kuvaa ABI-tyyppi scope-tyyppibitiksi — 0 jos tuntematon (fail-closed).
pub fn typeToScopeBit(cap_type: u32) u32 {
    // Portti → bitti 1 (scope.TYPE_PORT).
    if (cap_type == task.CAP_TYPE_PORT) return @as(u32, 1) << 1;
    // Muisti → bitti 5 (scope.TYPE_MEMORY).
    if (cap_type == task.CAP_TYPE_MEMORY) return @as(u32, 1) << 5;
    // Tuntematon ei kulje.
    return 0;
}

// Ratkaise tehtävä plugin-vaatimuksiksi puskuriin — palauttaa määrän.
pub fn resolve(spec: task.TaskSpec, out: []PluginReq) ResolveError!usize {
    // Tehtävän pitää olla rakenteellisesti kelvollinen ensin.
    task.validate(spec) catch {
        // Rakennevirhe ei ole ratkaisuvirhe — hylkää kattona (kutsu
        // validate:a erikseen tarkan syyn saamiseksi; resolve ei arvaa).
        return error.TooManyPlugins;
    };
    // Katto-ristiriita: tarpeita enemmän kuin katto → kieltäydy.
    if (spec.needs_len > spec.max_plugins) return error.TooManyPlugins;
    // Puskuriin pitää mahtua kaikki.
    if (out.len < spec.needs_len) return error.TooManyPlugins;
    // Käy tarpeet järjestyksessä (deterministinen, ei uudelleenjärjestelyä).
    var i: usize = 0;
    while (i < spec.needs_len) : (i += 1) {
        // Scope-bitti tarpeen tyypistä (0 → tuntematon, ei pitäisi tapahtua
        // validoidulla specillä — fail-closed silti).
        const bit = typeToScopeBit(spec.needs[i].cap_type);
        if (bit == 0) return error.TooManyPlugins;
        // Yksi vaatimus per tarve, kutistamaton.
        out[i] = .{
            .embedded_id = 0,
            .req_type = spec.needs[i].cap_type,
            .req_rights = spec.needs[i].rights_mask,
            .scope_types = bit,
            .scope_rights = spec.needs[i].rights_mask,
            .max_caps = DEFAULT_PLUGIN_CAPS,
        };
    }
    return spec.needs_len;
}

// Tarkista että vaatimus ei laajenna tarvetta (scope ⊆ need).
pub fn reqNarrowsNeed(need: task.Need, req: PluginReq) bool {
    // Tyyppi sama.
    if (req.req_type != need.cap_type) return false;
    // Oikeudet samat tai osajoukko (heuristiikka tuottaa samat).
    if ((req.req_rights & ~need.rights_mask) != 0) return false;
    if ((req.scope_rights & ~need.rights_mask) != 0) return false;
    // Scope-tyyppi vastaa tarvetta.
    if (req.scope_types != typeToScopeBit(need.cap_type)) return false;
    // Vain tunnettu binääri.
    if (req.embedded_id != 0) return false;
    return true;
}
