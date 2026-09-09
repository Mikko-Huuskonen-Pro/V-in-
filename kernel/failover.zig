//! Failover — heartbeat-seuranta + replika-päätös (Vaihe 35.4, puhdas ydin).
//!
//! **Vastuu**: Seuraa solmujen elossaoloa heartbeat-tickeillä (`Cluster`) ja
//!   päätä milloin kuollut koti korvataan varasolmulla (`ReplicaPlan`).
//!   Kello on kutsujan antama u64-tick (deterministinen — ei ajastinajoa
//!   ytimessä, sama kaava kuin `decomposer.isExpired`).
//! **Riippuvuudet**: ei (puhdas logiikka — host-testattava).
//! **Käytetään**: `kernel/federate.zig` (boot-orkestraattori), host-testit.
//!
//! ## Arkkitehtuurihuomiot (AGENTS.md)
//! - Havainto vs. päätös: `sweep` havaitsee (merkitsee kuolleet), `ReplicaPlan`
//!   päättää (korvaa vain jos vara elää). Kuollutta ei korvata kuolleella.
//! - Fail-closed: tuntematon solmu → ei-elossa; varasolmu kuollut → ei
//!   ylennystä (palvelu jää orvoksi näkyvästi, ei hiljaa väärään paikkaan).
//! - Yksi koti + yksi vara vaiheessa 35 (ketjureplikaatio on vaiheen 35.x
//!   laajennus, rajattu pois dokumentoidusti).

// Klusteritaulukon koko (pariteetti tunnelin vertaisten kanssa).
pub const MAX_NODES: usize = 8;

// Yksi solmurivi klusterissa.
pub const Node = struct {
    // Onko rivi käytössä.
    used: bool,
    // Solmutunniste (nollasta poikkeava).
    id: u32,
    // Viimeisin heartbeat-tick.
    last_beat: u64,
    // Elossa (sweep voi merkitä kuolleeksi).
    alive: bool,
};

// Klusteri — solmujen elossaolotila (arvotyyppi, ei globaalia tilaa tässä).
pub const Cluster = struct {
    // Kiinteä solmutaulukko.
    nodes: [MAX_NODES]Node,

    // Nollaa klusteri.
    pub fn init() Cluster {
        var c = Cluster{ .nodes = undefined };
        var i: usize = 0;
        while (i < MAX_NODES) : (i += 1) {
            c.nodes[i] = .{ .used = false, .id = 0, .last_beat = 0, .alive = false };
        }
        return c;
    }

    // Etsi rivi tunnisteella — null jos ei liitetty.
    fn find(self: *Cluster, id: u32) ?*Node {
        var i: usize = 0;
        while (i < MAX_NODES) : (i += 1) {
            if (self.nodes[i].used and self.nodes[i].id == id) return &self.nodes[i];
        }
        return null;
    }

    // Liitä solmu klusteriin (idempotentti — kaksoisjoin ei tuplaa).
    pub fn join(self: *Cluster, id: u32, now: u64) bool {
        // Nolla varattu.
        if (id == 0) return false;
        // Jo jäsen → päivitä syke, pysy elossa.
        if (self.find(id)) |n| {
            n.last_beat = now;
            n.alive = true;
            return true;
        }
        // Etsi vapaa rivi.
        var i: usize = 0;
        while (i < MAX_NODES) : (i += 1) {
            if (!self.nodes[i].used) {
                self.nodes[i] = .{ .used = true, .id = id, .last_beat = now, .alive = true };
                return true;
            }
        }
        // Täynnä — fail-closed.
        return false;
    }

    // Heartbeat solmulta (vain jäsenet; vieras ei herätä riviä).
    pub fn heartbeat(self: *Cluster, id: u32, now: u64) bool {
        const n = self.find(id) orelse return false;
        n.last_beat = now;
        n.alive = true;
        return true;
    }

    // Poista solmu klusterista (siisti lähtö — rivi vapautuu).
    pub fn leave(self: *Cluster, id: u32) bool {
        const n = self.find(id) orelse return false;
        n.used = false;
        n.id = 0;
        n.last_beat = 0;
        n.alive = false;
        return true;
    }

    // Pyyhkäise: merkitse kuolleeksi jokainen jonka syke on vanhentunut.
    // Palauttaa kuolleeksi todettujen määrän (elossa→kuollut -siirtymät).
    pub fn sweep(self: *Cluster, now: u64, timeout: u64) usize {
        var dead: usize = 0;
        var i: usize = 0;
        while (i < MAX_NODES) : (i += 1) {
            if (self.nodes[i].used and self.nodes[i].alive) {
                // Vanhentunut syke → kuollut (saturating-vähennys allekirjoitusta vastaan).
                const age = if (now >= self.nodes[i].last_beat) now - self.nodes[i].last_beat else 0;
                if (age >= timeout) {
                    self.nodes[i].alive = false;
                    dead += 1;
                }
            }
        }
        return dead;
    }

    // Onko solmu elossa (tuntematon → false, fail-closed).
    pub fn isAlive(self: *Cluster, id: u32) bool {
        const n = self.find(id) orelse return false;
        return n.alive;
    }

    // Montako elossa (testien apuri).
    pub fn aliveCount(self: *Cluster) usize {
        var n: usize = 0;
        var i: usize = 0;
        while (i < MAX_NODES) : (i += 1) {
            if (self.nodes[i].used and self.nodes[i].alive) n += 1;
        }
        return n;
    }
};

// Replikatila — missä palvelu palvelee nyt.
pub const ReplicaState = enum(u2) {
    // Seuranta, ei korvausta (koti elää).
    primary = 0,
    // Koti kuollut, vara ylentynyt palvelemaan.
    replicated = 1,
    // Koti kuollut eikä vara elä (näkyvä orpous — ei hiljaista sijoitusta).
    orphaned = 2,
};

// Yksi replikasuunnitelma palvelulle (koti + yksi vara).
pub const ReplicaPlan = struct {
    // Koti-solmu (ensisijainen).
    home_node: u32,
    // Vara-solmu (korvaaja).
    spare_node: u32,
    // Palveleva pid (varalla ylentymisen jälkeen).
    serving_pid: u64,
    // Nykyinen tila.
    state: ReplicaState,

    // Rakenna suunnitelma (koti ≠ vara, ei nollia).
    pub fn init(home_node: u32, spare_node: u32) ReplicaPlan {
        return .{
            .home_node = home_node,
            .spare_node = spare_node,
            .serving_pid = 0,
            .state = .primary,
        };
    }

    // Onko suunnitelma rakenteellisesti kelvollinen.
    pub fn valid(self: *const ReplicaPlan) bool {
        if (self.home_node == 0 or self.spare_node == 0) return false;
        if (self.home_node == self.spare_node) return false;
        return true;
    }

    // Merkitse palveleva instanssi (migraation/restoren jälkeen).
    pub fn noteServing(self: *ReplicaPlan, pid: u64) void {
        self.serving_pid = pid;
    }

    // Ylennä varalle: koti kuollut → vara palvelemaan TAI orpous.
    // home_alive/spare_alive lukee kutsuja klusterista (ydin ei koske siihen).
    pub fn promoteOnLoss(self: *ReplicaPlan, dead_node: u32, home_alive: bool, spare_alive: bool) ReplicaState {
        // Väärä vainaja (ei koti) → ei toimenpidettä.
        if (dead_node != self.home_node) return self.state;
        // Koti väittää elävänsä → ei toimenpidettä (sweep ei todennut).
        if (home_alive) return self.state;
        // Vara elää → replikoi (palveleva pid on jo varalla migraatiosta).
        if (spare_alive and self.serving_pid != 0) {
            self.state = .replicated;
            return .replicated;
        }
        // Vara kuollut tai ei palvelevaa → näkyvä orpous.
        self.state = .orphaned;
        return .orphaned;
    }
};
