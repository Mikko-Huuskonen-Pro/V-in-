//! Remote-IPC-välittäjä — läpinäkyvä reititys etäsolmuihin (Vaihe 35.2).
//!
//! **Vastuu**: Pidä taulukko etäporteista (`node_id` + etäslotti) ja reititä
//!   lähetys/vastaanotto oikealle solmulle ilman että kutsuja tietää
//!   etäisyyttä. Ehdota — älä myönnä: tämä on userland-kirjasto (pyyntö);
//!   kernelin tunneli (`cap_tunnel`) todentaa ja scope-portti valtuuttaa.
//! **Riippuvuudet**: ei (puhdas logiikka — freestanding + host-testattava).
//! **Käytetään**: `kernel/federate.zig` (boot-reititys), host-testit.
//!
//! ## Arkkitehtuurihuomiot (AGENTS.md)
//! - Välittäjä ei kanna capabilityja eikä koske slotteihin — se kantaa
//!   REITTEJÄ (node_id, slot-numero, oikeusmaski-kopio). Sekoittaminen
//!   olisi ambient-authority (hylätty PLUGIN_MODEL I1:ssä).
//! - Viestikoko pariteetissa `port.MAX_MSG_SIZE`:n (32) kanssa — välittäjä
//!   ei pätki eikä kokoa; liian pitkä hylätään ennen johtoa.
//! - Reitti solmuun jota ei ole rekisteröity → UnknownRoute (fail-closed).

// Etäreittien enimmäismäärä taulukossa (kiinteä, ei allokaatiota).
pub const MAX_REMOTES: usize = 8;
// Välitettävän viestin maksimipituus (port.MAX_MSG_SIZE-pariteetti).
pub const FORWARD_MAX_MSG: usize = 32;

// Välittäjän virheet.
pub const ForwardError = error{
    // Taulukko täynnä (uusi reitti ei mahdu).
    TableFull,
    // Reittiä ei löydy (tuntematon solmu/slotti tai purettu).
    UnknownRoute,
    // Solmutunniste nolla (varattu).
    BadNode,
    // Viesti tyhjä tai liian pitkä johdolle.
    BadLength,
};

// Yksi etäreitti taulukossa.
pub const RemotePort = struct {
    // Onko rivi käytössä.
    active: bool,
    // Etäsolmun tunniste.
    node_id: u32,
    // Etäpään capability-slotti (kohdesolmun nimiavaruudessa).
    remote_slot: u32,
    // Kopio myönnetystä oikeusmaskista (tiedoksi — ei valtuutus).
    rights_mask: u32,
};

// Välittäjätaulukko — arvotyyppi (kopioitava, ei globaalia tilaa tässä).
pub const Forwarder = struct {
    // Kiinteä reittitaulukko.
    routes: [MAX_REMOTES]RemotePort,

    // Nollaa taulukko.
    pub fn init() Forwarder {
        var f = Forwarder{ .routes = undefined };
        // Tyhjennä jokainen rivi.
        var i: usize = 0;
        while (i < MAX_REMOTES) : (i += 1) {
            f.routes[i] = .{ .active = false, .node_id = 0, .remote_slot = 0, .rights_mask = 0 };
        }
        return f;
    }

    // Rekisteröi etäreitti — palauttaa indeksin tai virheen.
    pub fn register(self: *Forwarder, node_id: u32, remote_slot: u32, rights_mask: u32) ForwardError!usize {
        // Nollasolmu varattu.
        if (node_id == 0) return error.BadNode;
        // Jo rekisteröity sama pari → palauta indeksi (idempotentti).
        var i: usize = 0;
        while (i < MAX_REMOTES) : (i += 1) {
            if (self.routes[i].active and self.routes[i].node_id == node_id and
                self.routes[i].remote_slot == remote_slot)
            {
                return i;
            }
        }
        // Etsi vapaa rivi.
        i = 0;
        while (i < MAX_REMOTES) : (i += 1) {
            if (!self.routes[i].active) {
                self.routes[i] = .{
                    .active = true,
                    .node_id = node_id,
                    .remote_slot = remote_slot,
                    .rights_mask = rights_mask,
                };
                return i;
            }
        }
        // Taulukko täynnä — fail-closed.
        return error.TableFull;
    }

    // Poista reitti indeksillä — false jos ei ollut aktiivinen.
    pub fn unregister(self: *Forwarder, index: usize) bool {
        // Indeksi yli taulukon.
        if (index >= MAX_REMOTES) return false;
        // Ei aktiivinen.
        if (!self.routes[index].active) return false;
        // Nollaa rivi.
        self.routes[index] = .{ .active = false, .node_id = 0, .remote_slot = 0, .rights_mask = 0 };
        return true;
    }

    // Hae reitti indeksillä — null jos passiivinen/virheellinen.
    pub fn lookup(self: *const Forwarder, index: usize) ?RemotePort {
        if (index >= MAX_REMOTES) return null;
        if (!self.routes[index].active) return null;
        return self.routes[index];
    }

    // Reititä solmu+slotti → indeksi (saapuvan kehyksen ohjaus).
    pub fn route(self: *const Forwarder, node_id: u32, remote_slot: u32) ?usize {
        var i: usize = 0;
        while (i < MAX_REMOTES) : (i += 1) {
            if (self.routes[i].active and self.routes[i].node_id == node_id and
                self.routes[i].remote_slot == remote_slot)
            {
                return i;
            }
        }
        return null;
    }

    // Tarkista lähetys reitille: reitti auki + pituus johdolle kelvollinen.
    pub fn checkSend(self: *const Forwarder, index: usize, len: usize) ForwardError!void {
        // Reitin pitää olla aktiivinen.
        const r = self.lookup(index) orelse return error.UnknownRoute;
        _ = r;
        // Ei tyhjää viestiä (nollalähetys on ohjelmointivirhe, ei liikenne).
        if (len == 0) return error.BadLength;
        // Ei porttirajaa suurempaa (välittäjä ei pätki).
        if (len > FORWARD_MAX_MSG) return error.BadLength;
    }

    // Montako reittiä aktiivinen (testien apuri).
    pub fn countActive(self: *const Forwarder) usize {
        var n: usize = 0;
        var i: usize = 0;
        while (i < MAX_REMOTES) : (i += 1) {
            if (self.routes[i].active) n += 1;
        }
        return n;
    }
};
