//! Capability-tunneli — todennettu cap-siirto solmujen välillä (Vaihe 35.1).
//!
//! **Vastuu**: Sulje capability-siirto HMAC-SHA256-kuoreen (`seal`) ja avaa +
//!   todenna se vastaanotossa (`open`): versio, tunnettu vertainen, MAC ja
//!   nonce-järjestys (replay-ikkuna). Ei verkkoa — "johto" on kutsujan
//!   kuljettama tavujono (boot-testissä loopback-puskuri, vaiheessa 35.x TCP).
//! **Riippuvuudet**: `fed_hmac` (build-moduuli — sama kaava kuin
//!   `composer_task`: suhteellinen kaksoisinstanssi on Zig 0.16:ssa
//!   moduulivirhe, joten molemmat verkot (host/kernel) jakavat saman
//!   `hmac.zig`-instanssin nimellä).
//! **Käytetään**: `kernel/federate.zig` (boot-orkestraattori), host-testit.
//!
//! ## Arkkitehtuurihuomiot (AGENTS.md)
//! - Todennus vs. valtuutus erotettu: tämä moduli todentaa (kuka lähetti,
//!   onko tuore, onko ehjä). VALTUUTUKSEN (saako cap asentaa) päättää
//!   vastaanottava kernel scope-portilla (`allowsGatewayTransfer`) —
//!   MAC ei ole capability, se on vain kirjekuori.
//! - Fail-closed: tuntematon vertainen, väärä MAC, uusinta-nonce tai väärä
//!   versio hylätään; hylkäys ei muuta tilaa (replay-ikkuna etenee vain
//!   hyväksytyllä avauksella).
//! - Nonce 0 on varattu (ei-kelvollinen): tuore tunneli alkaa noncesta 1,
//!   joten nollattu muisti ei koskaan kelpaa viestinä.

// Tuo puhdas HMAC-ydin (build-moduuli — host + kernel jakavat instanssin).
const hmac = @import("fed_hmac");

// Tunneliprotokollan versio — vastaanottaja hylkää muut (yhteensopivuusportti).
pub const TUNNEL_VERSION: u8 = 1;
// Montako vertaissolmua ikkunataulukkoon mahtuu (kiinteä, ei allokaatiota).
pub const MAX_PEERS: usize = 8;
// Avaimen pituus tavuina (HMAC-SHA256, 256-bittinen).
pub const KEY_LEN: usize = 32;
// Kanonisen tuple-koodauksen pituus (1+4+8+4+4+4+8, little-endian).
pub const GRANT_ENC_LEN: usize = 33;

// Tunnelivirheet — yksi syy kerrallaan (vastalause nimeää vian).
pub const TunnelError = error{
    // Väärä protokollaversio.
    BadVersion,
    // Lähettäjää ei ole liitetty (`addPeer` puuttuu).
    UnknownPeer,
    // MAC ei täsmää (väärä avain tai peukaloitu tavu).
    BadMac,
    // Nonce ei etene (uusinta tai järjestysvirhe).
    Replay,
    // Vertainen nolla / taulukko täynnä (liitosvirhe).
    NoSlot,
};

// Capability-siirto selväkielisenä (allekirjoitettava tuple).
pub const CapGrant = struct {
    // Lähettäjäsolmu (nollasta poikkeava).
    src_node: u32,
    // Lähettäjäprosessi.
    src_pid: u64,
    // Lähettäjän capability-slotti.
    src_slot: u32,
    // Vastaanottajasolmu.
    dest_node: u32,
    // Pyydetty oikeusmaski (scope-layout, kuten gateway).
    rights_mask: u32,
    // Uusintasuoja (tiukasti kasvava per lähettäjä).
    nonce: u64,
};

// Suljettu kuori johdolle (tuple + MAC).
pub const SealedGrant = struct {
    // Allekirjoitettava sisältö.
    grant: CapGrant,
    // HMAC-SHA256(koodattu tuple).
    mac: [hmac.DIGEST_LEN]u8,
};

// Koodaa tuple kanonisiin tavuihin (little-endian, ei täytevaraa).
pub fn encodeGrant(g: CapGrant, out: *[GRANT_ENC_LEN]u8) void {
    out[0] = TUNNEL_VERSION;
    // Apu: u32 LE kohdasta o.
    out[1] = @intCast(g.src_node & 0xff);
    out[2] = @intCast((g.src_node >> 8) & 0xff);
    out[3] = @intCast((g.src_node >> 16) & 0xff);
    out[4] = @intCast((g.src_node >> 24) & 0xff);
    // u64 LE kohdasta 5.
    var i: usize = 0;
    while (i < 8) : (i += 1) out[5 + i] = @intCast((g.src_pid >> @intCast(i * 8)) & 0xff);
    // u32 LE kohdasta 13.
    out[13] = @intCast(g.src_slot & 0xff);
    out[14] = @intCast((g.src_slot >> 8) & 0xff);
    out[15] = @intCast((g.src_slot >> 16) & 0xff);
    out[16] = @intCast((g.src_slot >> 24) & 0xff);
    // u32 LE kohdasta 17.
    out[17] = @intCast(g.dest_node & 0xff);
    out[18] = @intCast((g.dest_node >> 8) & 0xff);
    out[19] = @intCast((g.dest_node >> 16) & 0xff);
    out[20] = @intCast((g.dest_node >> 24) & 0xff);
    // u32 LE kohdasta 21.
    out[21] = @intCast(g.rights_mask & 0xff);
    out[22] = @intCast((g.rights_mask >> 8) & 0xff);
    out[23] = @intCast((g.rights_mask >> 16) & 0xff);
    out[24] = @intCast((g.rights_mask >> 24) & 0xff);
    // u64 LE kohdasta 25.
    i = 0;
    while (i < 8) : (i += 1) out[25 + i] = @intCast((g.nonce >> @intCast(i * 8)) & 0xff);
}

// Yksi replay-ikkunarivi vertaista kohti.
pub const PeerWindow = struct {
    // Onko rivi käytössä.
    used: bool,
    // Vertaisen solmutunniste.
    node_id: u32,
    // Viimeksi hyväksytty nonce (seuraavan pitää olla suurempi).
    last_nonce: u64,
};

// Tunneli — avain + nonce-laskuri + replay-ikkuna (ei heap-allokaatiota).
pub const Tunnel = struct {
    // Jaettu salaisuus (ei koskaan johdolle; TEST-avain bootissa).
    key: [KEY_LEN]u8,
    // Seuraava lähtevä nonce (alkaa 1:stä — 0 varattu).
    next_nonce: u64,
    // Vastaanoton replay-ikkuna per vertainen.
    peers: [MAX_PEERS]PeerWindow,

    // Alusta tunneli avaimella (ikkuna tyhjä — vertaiset liitetään erikseen).
    pub fn init(key: [KEY_LEN]u8) Tunnel {
        var t = Tunnel{
            .key = key,
            .next_nonce = 1,
            .peers = undefined,
        };
        // Tyhjennä ikkunataulukko.
        var i: usize = 0;
        while (i < MAX_PEERS) : (i += 1) {
            t.peers[i] = .{ .used = false, .node_id = 0, .last_nonce = 0 };
        }
        return t;
    }

    // Liitä vertainen (solmu-liitos — kernelin päätös, idempotentti).
    pub fn addPeer(self: *Tunnel, node_id: u32) TunnelError!void {
        // Nolla ei kelpaa solmutunnisteeksi.
        if (node_id == 0) return error.NoSlot;
        // Jo liitetty → OK (idempotentti).
        var i: usize = 0;
        while (i < MAX_PEERS) : (i += 1) {
            if (self.peers[i].used and self.peers[i].node_id == node_id) return;
        }
        // Etsi vapaa rivi.
        i = 0;
        while (i < MAX_PEERS) : (i += 1) {
            if (!self.peers[i].used) {
                self.peers[i] = .{ .used = true, .node_id = node_id, .last_nonce = 0 };
                return;
            }
        }
        // Taulukko täynnä — fail-closed.
        return error.NoSlot;
    }

    // Poista vertainen (solmu lähti — ikkuna nollataan).
    pub fn removePeer(self: *Tunnel, node_id: u32) bool {
        var i: usize = 0;
        while (i < MAX_PEERS) : (i += 1) {
            if (self.peers[i].used and self.peers[i].node_id == node_id) {
                self.peers[i] = .{ .used = false, .node_id = 0, .last_nonce = 0 };
                return true;
            }
        }
        return false;
    }

    // Montako vertaista liitetty (testien apuri).
    pub fn peerCount(self: *const Tunnel) usize {
        var n: usize = 0;
        var i: usize = 0;
        while (i < MAX_PEERS) : (i += 1) {
            if (self.peers[i].used) n += 1;
        }
        return n;
    }

    // Sulje tuple johdolle (nonce annetaan laskurista — 0 ei koskaan lähde).
    pub fn sealNext(
        self: *Tunnel,
        src_node: u32,
        src_pid: u64,
        src_slot: u32,
        dest_node: u32,
        rights_mask: u32,
    ) SealedGrant {
        // Rakenna tuple laskurin noncella.
        const g = CapGrant{
            .src_node = src_node,
            .src_pid = src_pid,
            .src_slot = src_slot,
            .dest_node = dest_node,
            .rights_mask = rights_mask,
            .nonce = self.next_nonce,
        };
        // Laskuri eteenpäin (saturating — kietoutuminen pysähtyy, ei nollaudu).
        if (self.next_nonce < 0xFFFF_FFFF_FFFF_FFFF) self.next_nonce += 1;
        // Koodaa + MAC.
        var enc: [GRANT_ENC_LEN]u8 = undefined;
        encodeGrant(g, &enc);
        var sealed = SealedGrant{ .grant = g, .mac = undefined };
        hmac.hmacSha256(&self.key, &enc, &sealed.mac);
        return sealed;
    }

    // Avaa + todenna johdolta saapunut kuori (tila muuttuu vain hyväksynnällä).
    pub fn open(self: *Tunnel, sealed: *const SealedGrant) TunnelError!CapGrant {
        // Lähettäjän pitää olla liitetty vertainen (liitos on kernelin päätös).
        var slot: ?*PeerWindow = null;
        var i: usize = 0;
        while (i < MAX_PEERS) : (i += 1) {
            if (self.peers[i].used and self.peers[i].node_id == sealed.grant.src_node) {
                slot = &self.peers[i];
            }
        }
        const win = slot orelse return error.UnknownPeer;
        // Nonce 0 ei koskaan kelpaa (varattu — nollattu muisti ei kulje).
        if (sealed.grant.nonce == 0) return error.Replay;
        // Noncen pitää aidosti edetä (uusinta/pois-järjestyksestä hylätään).
        if (sealed.grant.nonce <= win.last_nonce) return error.Replay;
        // MAC koodatusta tuplesta (peukalointi → BadMac).
        var enc: [GRANT_ENC_LEN]u8 = undefined;
        encodeGrant(sealed.grant, &enc);
        var expect: [hmac.DIGEST_LEN]u8 = undefined;
        hmac.hmacSha256(&self.key, &enc, &expect);
        if (!hmac.digestEqual(&expect, &sealed.mac)) return error.BadMac;
        // Hyväksytty — ikkuna etenee (vasta nyt, ei hylkäyksillä).
        win.last_nonce = sealed.grant.nonce;
        return sealed.grant;
    }
};
