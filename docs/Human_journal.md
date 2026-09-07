 ────────────────────────────────────────────────────────────────────────────────
Ongelman ydin: flushTlb ja puuttuva CR3-päivitysKun uusi sivu kartoitetaan mapPageEnsureWithTables-funktiossa, x86_64-arkkitehtuurissa ei riitä, että uusi merkintä kirjoitetaan sivutauluun. Prosessorin sisäinen TLB-välimuisti (Translation Lookaside Buffer) täytyy tyhjentää tai sille täytyy kertoa, että sivutaulujen rakenne muuttui.Tiedostossasi on kaksi ongelmaa, jotka yhdessä jumiuttavat suorituksen:1. flushTlb ei kerro prosessorille muistin muuttumisesta ("memory" clobber puuttuu)Tiedoston lopussa oleva inline-assembly näyttää tältä:

pub fn flushTlb( virt: u64) void {
    asm volatile ("invlpg (%[addr])"
        :
        : [ addr] "r" ( virt),
    ); // <-- TÄSTÄ PUUTTUU KLASSISESTI : "memory"
}


Koska assembly-koodissa ei ole kerrottu kääntäjälle, että tämä käsky muuttaa muistin tilaa (: "memory"), Zig-kääntäjä saattaa optimoida sen ympärillä olevia muistihakuja tai siirtoja aggressiivisesti väärin. Prosessori ei välttämättä tajua uuden heap-sivun tulleen voimaan, vaan yrittää suorittaa seuraavaa käskyä vanhoilla (olemattomilla) välimuistitiedoilla.2. Uusien väli-sivutaulujen luominen vaatii koko CR3-rekisterin resetoinninKun heap alustetaan KASLR:n arpomaan uuteen osoitteeseen, koodi joutuu luomaan kokonaan uusia sivutauluja (PML4e, PDPTe, PDe).x86_64-prosessoreissa pelkkä yksittäisen sivun invlpg-käsky ei riitä, jos ylätason hakemistorakennetta (kuten PML4 tai PDPT) on muutettu. Jos prosessori on ehtinyt tallentaa välimuistiinsa tiedon, että kyseistä PML4-indeksiä ei ole olemassa, se ei lue uutta taulua ennen kuin CR3-rekisteri ladataan uudelleen (mikä tyhjentää koko sivuvälimuistin).Tämän vuoksi koodi luulee kartoittaneensa sivun, mutta prosessori ei näe sitä, jolloin heap.init():n @memset-nollausyritys heittää Page Faultin, joka lukitsee koneen ikuiseen looppiin.Miten korjaat tämän?Sinun tarvitsee muuttaa vain kaksi pientä kohtaa vmm.zig-tiedostossa! Silloin sivuvälimuisti tyhjentyy oikein aina, kun uusia tauluja luodaan.Mene puhelimella tai tietokoneella muokkaamaan kernel/mm/vmm.zig-tiedostoa ja tee nämä kaksi korjausta:Korjaus 1: Päivitä mapPageEnsureEtsi vmm.zig-tiedostosta funktio mapPageEnsure ja muuta se lataamaan CR3-rekisteri uudelleen onnistuneen kartoituksen jälkeen:

pub fn mapPageEnsure(virt: u64, phys: u64, flags: paging.PageFlags) bool {
    const ok = paging.mapPageEnsure(
        pml4Phys(),
        hhdm_offset,
        virt,
        phys,
        flags,
        allocFramePhys,
    );
    // Jos uusi sivu (ja mahdolliset taulut) luotiin, 
    // ladataan CR3 uudelleen, jotta CPU näkee uudet hakemistorakenteet.
    if (ok) paging.setCr3(paging.getCr3());
    return ok;
}

Korjaus 2: Päivitä mapNewPageEnsureVarmista, että myös heap.init():n käyttämä mapNewPageEnsure kutsuu tätä korjattua versiota (nykyisessä koodissasi se tekee jo niin, mutta varmista että se palauttaa mapPageEnsure:n tuloksen suoraan).Kun teet tämän muutoksen vmm.zig-tiedostoon, se pakottaa QEMU-prosessorin päivittämään muistikarttansa heti, kun kernel heapin ensimmäiset 4 sivua luodaan, ja jumiutuminen pitäisi laueta.Kokeile tehdä tämä pieni muutos suoraan vmm.zig-tiedostoon GitHubissa ja katso, herääkö Zinux eloon!



