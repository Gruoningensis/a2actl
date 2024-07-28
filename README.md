# A2ACTL
Deze repository bestaat uit een verzameling Perl-scripts waarmee het mogelijk is om A2A-XML-bestanden van de Burgerlijke Stand te controleren op een aantal veelvoorkomende fouten. De scripts zouden zowel moeten werken voor bestanden afkomstig van opendata.archieven.nl als van opendata.picturae.com. De output bestaat uit een Excel-bestand met een vast aantal kolommen.  
Voor elk van de aktesoorten (geboorte, huwelijk en overlijden) is er een apart script beschikbaar:
```
bsg.pl
bsh.pl
bso.pl
```
## Controles
De scripts voeren een aantal controles uit op de inhoud van elke akte, waaronder:
- aktenummer
  - afwijkende tekens
  - afwijkend stramien
  - gaten in de nummering (verschil tussen opvolgende aktenummers > 1)
- dateringen
  - geldigheid van de datum
  - afwijkingen van begin- of einddatum aktesoort
- leeftijd
  - te oud
  - te jong
- rollen
  - aantal rollen
  - aanwezigheid verplichte/verwachte rollen
  - dubbele rollen
- namen en naamdelen
  - stramien/structuur van een naam(deel)
  - herhalende tekens
  - aantal opvolgende (mede)klinkers
  - afwijkingen tussen naam kind en naam ouder
  - geslacht (op basis van naam)
- beroepen
  - herhalende tekens
## Configuratie
Deze controles kunnen veel *vermoede* fouten opleveren. Om het aantal onnodige foutmeldingen terug te dringen kunnen de controles kunnen middels een configuratiebestand getweaked worden. Dit configuratiebestand vind je hier:
```
include/a2actl.ini
```
Het bestand kent een algemene sectie [ALG] voor instellingen die voor elke aktesoort gelden en daarnaast een secties per aktesoort: [BS_G], [BS_H] en [BS_O].
In het configuratiebestand vind je een nadere uitleg van wat een instelling precies doet. Een voorbeeld:
```
[BS_G]
min_leeftijd=18
```
De instelling *min_leeftijd* wordt gebruikt om te bepalen wat de ondergrens is qua leeftijd voor het genereren van een melding over een te jonge vader of moeder bij een geboorteakte. In dit geval wordt pas een melding gegenereerd wanneer deze personen 17 jaar of jonger zijn.
```
[ALG]
regex_nn=^(N\\.N\\.|NN)$
```
De instelling *regex_nn* bepaalt welk stramien mag worden verwacht voor een *nomen nescio* (naam onbekend) in de akte. In dit specifieke geval wordt er geen melding gegenereerd als een naamdeel de exacte waarde 'NN' of 'N.N.' bevat. De instelling vereist het gebruik van een reguliere expressie, waarbij ge-escapete waarden dubbel ge-escapet moeten worden.
```
[BS_H]
min_jaar=1811
```
De instelling *min_jaar* bepaalt wat het vroegste aktejaar is dat mag voorkomen in de datering van de akte. In de meeste provincies begint de Burgerlijke Stand in 1811, maar er zijn uitzonderingen op deze regel.
## Installatie ##
Clone deze repository naar een lokaal systeem:
```
git clone https://github.com/Gruoningensis/a2actl.git
```
## Gebruik
### Installatievereisten
Een systeem waarop Docker geïnstalleerd is of een systeem waarop Perl en enkele modules geínstalleerd zijn/kunnen worden.
### Bestanden klaarzetten
Download de te controleren A2A-bestanden van de betreffende opendata-server. Plaats deze in een map binnen de geclonede repository:
```
cd a2actl
mkdir data
cd data
<download A2A-bestanden met bv wget>
```
### Docker-image bouwen
Om de scripts systeemafhankelijk te kunnen draaien wordt een Dockerfile meegeleverd die alle benodigde modules installeert op een ubuntu-image. Dit vereist dat Docker op de betreffende machine geinstalleerd is. De image kan als volgt gebouwd worden:
```
sudo docker build . -t a2actl:latest
```
Daarna kan een met deze Docker-image een interactieve shell gestart worden:
```
sudo docker run -it -v $(pwd):/a2actl/ a2actl:latest
cd /a2actl
```
### Script aanroepen
Binnen de interactieve shell kan vervolgens het script aangeroepen worden. Het algemene gebruik daarvoor is:
```
perl <script-naam> <pad naar A2A-bestand> <pad naar logbestand>
```
In onderstaand voorbeeld wordt in een nieuwe map *log* een Excel-bestand weggeschreven voor elk XML-bestand in de map *data*, waarbij het log-bestand dezelfde naam heeft als het data-bestand, maar met de extensie *xlsx*:
```
mkdir log
for x in data/*.xml
do
  file=$(basename $x)
  log="./log/"${file%%.xml}".xlsx"
  perl bsg.pl $x $log
done
```
### Afsluiting
Het script is klaar wanneer er een melding verschijnt over het aantal gecontroleerde akten. Tijdens de uitvoering van het script kunnen er ook andere console-meldingen gegenereerd worden. Deze meldingen kunnen genegeerd worden. 
Verlaat naderhand de interactieve shell:
```
exit
```
### Gebruik zonder Docker
Het is uiteraard ook mogelijk om de scripts zonder Docker te gebruiken op een systeem waarop Perl is geïnstalleerd. Daarvoor moeten enkele modules geïnstalleerd worden:
```
XML::LibXML::Reader
XML::Bare
Text::WagnerFischer
Date::Calc
Excel::Writer::XLSX
Config::Simple
Data::Dumper
Getopt::Long
File::Basename
```
## Nadere toelichting op het gebruik
### Parameters
Het script kent de aanvullende parameter "vanaf" waarmee het startjaar bepaald kan worden voor de controles. Dit komt van pas wanneer de A2A-bestanden in zijn geheel per aktesoort gepubliceerd worden en de controles alleen op de laatst toegevoegde jaren moet worden uitgevoerd, bijvoorbeeld naar aanleiding van openbaarheidsdag:
```
perl bsg.pl --vanaf 1922 <pad naar A2A-bestand> <pad naar logbestand>
```
De verwerking van een bestand wordt hierdoor niet sneller, alle records moeten immers gecontroleerd worden op jaartal. Het scheelt met name in de omvang van de output.
Let op dat het script hierbij alleen records verwerkt waarvan een SourceDate/Year bekend is.
### Aktesoorten
Tijdens de uitvoering van een script wordt alleen de specifieke aktesoort behorende bij een script gecontroleerd. Dit gebeurt aan de hand van het Source/SourceDate-element. Meerdere aanroepen van verschillende scripts zijn dus nodig om alle akten te controleren in een bestand dat meerdere aktesoorten bevat. Dit komt sporadisch voor, met name rond de introductie van de Burgerlijke Stand.
### Verwerking resultaten
Het resultaat van een run van het script is een Excel-spreadsheet, waarmee de (mogelijke) fouten geanalyseerd kunnen worden. Het is van belang om daarbij te realiseren dat het script 'false positives' zal genereren. Er wordt alleen een vermoeden uitgesproken van een fout; of dit daadwerkelijk het geval is zal geverifieerd moeten worden. Ten behoeve daarvan worden de links naar de records meegenomen in de output.[^1]
Om het aantal 'false positives' in te perken kan gebruikgemaakt worden van parameters in het configuratiebestand. Zo bepalen de parameters 'mannen' en 'vrouwen' welke namen respectievelijk niet als man of vrouw moeten worden herkend. Dit onderscheid is veelal regionaal.
```
mannen=Arien,Adrien,Jurrien,Chretien,Sebastien,Esra,Cretien,Bonaventura,Josua,Jozua,Bastien,Juda,Julien,Jurien,Lucien,Martien
vrouwen=Agnes,Angenes,Judik,Margo,Marian,Marjan,Agenes,Cato,Catho,Agnees,Angenees,Agnus,Gertrudes,Gertrudus
```
*Kolommen*
De volgende kolommen zijn aanwezig in het Excel-bestand:
- Type (aktesoort)
- Meldcode (korte aanduiding van het type melding)
- Melding (Specifiekere uitleg van het mogelijke probleem)
- Gemeente (Gemeentenaam uit de akte)
- Jaar (Aktejaar)
- Aktenr (Nummer van de akte)
- Veld (Het A2A-veld waarvoor de melding geldt)
- Waarde (De waarde waarvoor de melding geldt, [LEEG] indien deze waarde leeg is)
- Context (Context waarbinnen de melding is gegenereerd, bv. de akte of een specifieke persoon)
- Link (de URL naar de akte)[^1]
- GUID (De GUID van de akte, bijvoorbeeld om een interne link naar het CBS te kunnen maken tbv correctie)
- Scans (Aanduiding of er scans beschikbaar zijn bij de akte, met het oog op het uitvoeren van de controle)

### Tips ten aanzien van het gebruik van de Excel-rapportage
- Gebruik filters om de meldingen op *meldcode* en *melding* te filteren. Controleer vervolgens aan de hand van het veld *waarde* of het waarschijnlijk is dat het daadwerkelijke fouten betreft. 
- Wanneer het script veel foutmeldingen genereert, prioriteer dan de meldingen die van invloed zijn op de vindbaarheid van een akte, bv. de spelling van namen.
- Gebruik de GUID om linkjes te maken naar het bewerk-scherm in het CBS, zodat fouten meteen gecorrigeerd kunnen worden.[^2]
- Wanneer de gegevens van een gemeente per register (één of meer jaargangen) in een A2A-bestand zijn geplaatst, dan levert het script waarschijnlijk veel Excel-bestanden op met relatief weinig meldingen per bestand. Overweeg in dat geval om meerdere Excel-bestanden samen te voegen (bv. per gemeente). Plaats ze hiervoor in één map en combineer ze in een lege werkmap via Gegevens > Gegevens ophalen > Uit bestand > Uit map > Combineren en laden.
##Noten
[^1]: Vanwege een beperking op het aantal hyperlinks in Excel wordt de URL weggeschreven met een *apostrof* ervoor. Dit kan met zoeken en vervangen in URL gecorrigeerd worden.
[^2]: Indien het CBS dit ondersteunt, zoals bv. Memorix Maior.
