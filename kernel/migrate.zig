//! Plugin-migraatio — tilasiirtymät lähteestä kohteeseen (Vaihe 35.3, puhdas ydin).
//!
//! **Vastuu**: Aja migraatiosuunnitelma vaiheiden läpi
//!   `staged → pushed → restored → done` (tai `aborted` mistä tahansa).
//!   Vaiheiden SISÄLTÖ (cap-siltojen kopiointi, ELF-lataus kohteessa) elää
//!   `federate.zig`:ssä — tämä on päätöslogiikka: mikä siirtymä on laillinen,
//!   milloin migraatio on valmis, milloin se on keskeytettävä.
//! **Riippuvuudet**: ei (puhdas logiikka — host-testattava kuten scope.zig).
//! **Käytetään**: `kernel/federate.zig` (orkestraattori), host-testit.
//!
//! ## Arkkitehtuurihuomiot (AGENTS.md)
//! - Kaikki-tai-ei-mitään: `pushed`-vaihe vaatii että KAIKKI sillattavat
//!   capit siirtyivät (`bridged == total`). Osittainen silta → `aborted`,
//!   ei "melkein migroitunutta" pluginia (vrt. swapin `fail_bridge` 33:ssa).
//! - Omistetun tilan migraatio odottaa vaiheen 31.5 snapshotteja (sama
//!   dokumentoitu rajoite kuin 33-swapissa): vaiheessa 35 migroidaan
//!   stateless-plugin + jaetut portit; omistettu tila ei kulje hiljaa.
//! - Lähde ≠ kohde ja pid ≠ 0 tarkistetaan `stage`:ssa (itsesilmukka ja
//!   haamuplugin hylätään ennen kuin mitään ladataan).

// Migraatiosuunnitelman tila — yksi kerrallaan, eteenpäin tai aborttiin.
pub const MigrationState = enum(u3) {
    // Ei aktiivista migraatiota.
    idle = 0,
    // Kohde varattu + skooppi tarkistettu (valmis työntöön).
    staged = 1,
    // Capit työnnetty kohteeseen (kaikki tai abortti).
    pushed = 2,
    // Kohdeinstanssi käy kohteessa (jatkuvuus todistettu).
    restored = 3,
    // Valmis: lähde purettu, kohde palvelee.
    done = 4,
    // Keskeytetty: mikään ei palvele tämän suunnitelman nimissä.
    aborted = 5,
};

// Migraatiovirheet (laittomat siirtymät + rakennevirheet).
pub const MigrateError = error{
    // Laiton siirtymä nykyisestä tilasta.
    BadTransition,
    // Haamuplugin (pid 0), nollasolmu tai lähde == kohde.
    BadPlan,
    // Osittainen cap-työntö (bridged != total).
    PartialPush,
};

// Yksi migraatiosuunnitelma (arvotyyppi — ei globaalia tilaa tässä).
pub const MigrationPlan = struct {
    // Nykyinen tila.
    state: MigrationState,
    // Migroitavan pluginin pid lähteessä.
    plugin_pid: u64,
    // Lähdesolmu.
    src_node: u32,
    // Kohdesolmu.
    dest_node: u32,
    // Sillattuja capeja työnnössä.
    caps_bridged: u32,
    // Sillattavia capeja yhteensä.
    caps_total: u32,

    // Passiivinen suunnitelma.
    pub fn init() MigrationPlan {
        return .{
            .state = .idle,
            .plugin_pid = 0,
            .src_node = 0,
            .dest_node = 0,
            .caps_bridged = 0,
            .caps_total = 0,
        };
    }

    // Onko tila pääte (ei enää siirtymiä).
    pub fn isTerminal(self: *const MigrationPlan) bool {
        return self.state == .done or self.state == .aborted;
    }

    // Aloita: varaa kohde + tarkista rakenne (lataus tapahtuu orkestraattorissa).
    pub fn stage(self: *MigrationPlan, plugin_pid: u64, src_node: u32, dest_node: u32) MigrateError!void {
        // Vain idle-tilasta (kesken olevaa ei ylikirjoiteta).
        if (self.state != .idle) return error.BadTransition;
        // Haamuplugin, nollasolmu tai itsesilmukka hylätään heti.
        if (plugin_pid == 0 or src_node == 0 or dest_node == 0) return error.BadPlan;
        if (src_node == dest_node) return error.BadPlan;
        // Kirjaa suunnitelma.
        self.plugin_pid = plugin_pid;
        self.src_node = src_node;
        self.dest_node = dest_node;
        self.caps_bridged = 0;
        self.caps_total = 0;
        self.state = .staged;
    }

    // Kirjaa työntö: kaikkien siltojen on onnistuttava (muuten abortti).
    pub fn notePushed(self: *MigrationPlan, bridged: u32, total: u32) MigrateError!void {
        // Vain staged-tilasta.
        if (self.state != .staged) return error.BadTransition;
        // Osittainen työntö ei kelpaa — suunnitelma aborttiin, ei pushed:iin.
        if (bridged != total) return error.PartialPush;
        self.caps_bridged = bridged;
        self.caps_total = total;
        self.state = .pushed;
    }

    // Kirjaa palautus kohteessa (jatkuvuusviesti kulki).
    pub fn noteRestored(self: *MigrationPlan) MigrateError!void {
        // Vain pushed-tilasta.
        if (self.state != .pushed) return error.BadTransition;
        self.state = .restored;
    }

    // Viimeistele: lähde purettu, kohde palvelee.
    pub fn finish(self: *MigrationPlan) MigrateError!void {
        // Vain restored-tilasta.
        if (self.state != .restored) return error.BadTransition;
        self.state = .done;
    }

    // Keskeytä mistä tahansa ei-päätetilasta.
    pub fn abort(self: *MigrationPlan) void {
        // Pääte säilyy (done/aborted ei muutu).
        if (self.isTerminal()) return;
        self.state = .aborted;
    }
};
