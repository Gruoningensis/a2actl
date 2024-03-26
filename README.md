# A2ACTL
Deze repository bestaat uit een verzameling Perl-scripts waarmee het mogelijk is om A2A-XML-bestanden te controleren op een aantal veelvoorkomende fouten. De output bestaat uit een tekstbestand met een vast aantal kolommen, die middels een in te stellen scheidingsteken zijn gescheiden.  
Op dit moment zijn de volgende scripts publiek beschikbaar:
```
bsg.pl
```
## Configuratie
De controles kunnen middels een configuratiebestand getweaked worden. Dit bestand kent een algemne sectie [ALG] en daarnaast secties per script. In het geval van bovengenoemd script is dit [BS_G].
Het configuratiebestand vind je hier:
```
include/a2actl.ini
```
In het configuratiebestand vind je de uitleg van wat een variabele precies doet. Een voorbeeld:
```
[BS_G]
min_leeftijd=18
```
De variabele *min_leeftijd* wordt gebruikt om in te stellen wat de ondergrens is qua leeftijd voor het genereren van een melding over een te jonge vader of moeder bij een geboorteakte. In dit geval wordt pas een melding gegenereerd wanneer deze 17 jaar of jonger is.
## Gebruik
Plaats de te controleren A2A-bestanden in een map binnen de geclonede repository:
```
cd a2actl
mkdir data
cd data
<download A2A-bestandn met wget>
```
Om de scripts systeemafhankelijk te kunnen draaien wordt een Dockerfile meegeleverd die alle benodigde modules installeert op een ubuntu-image. Deze image kan als volgt gebouwd worden
```
docker build . -t a2actl:latest
```
Daarna kan een interactieve shell met deze image gestart worden:
```
docker run -it -v $(pwd):/a2actl/ a2actl:latest
cd /a2actl
```
Het algemene gebruik voor het script is:
```
perl bsg.pl <pad naar A2A-bestand> <pad naar logbestand>
```
Bijvoorbeeld:
```
mkdir log
for x in data/*.xml
do
  file=$(basename $x)
  log="./log/"${file%%.xml}".xlsx"
  perl bsg.pl $x $log
done
```
## Parameters
Het script kent de aanvullende parameter "vanaf" waarmee het startjaar bepaald kan worden voor de controles. Dit komt van pas wanneer de A2A-bestanden in zijn geheel per aktesoort gepubliceerd worden en de controles alleen op de laatst toegevoegde jaren moet worden uitgevoerd, bijvoorbeeld naar aanleiding van openbaarheidsdag:
```
perl bsg.pl --vanaf 1922 <pad naar A2A-bestand> <pad naar logbestand>
```
De verwerking van een bestand wordt hierdoor niet sneller, alle records moeten immers gecontroleerd worden op jaartal. Het scheelt met name in de omvang van de output.
Let op dat het script hierbij alleen records verwerkt waarvan een SourceDate/Year bekend is.
## Verwerking resultaten
Het resultaat van een run van het script is een Excel-spreadsheet, waarmee de (mogelijke) fouten geanalyseerd kunnen worden. Het is van belang om daarbij te realiseren dat het script 'false positives' zal genereren. Er wordt alleen een vermoeden uitgesproken van een fout; of dit daadwerkelijk het geval is zal geverifieerd moeten worden. Ten behoeve daarvan worden de links naar de records meegenomen in de output.
Om het aantal 'false positives' in te perken kan gebruikgemaakt worden van parameters in het configuratiebestand. Zo bepalen de parameters 'mannen' en 'vrouwen' welke namen respectievelijk niet als man of vrouw moeten worden herkend. Dit onderscheid is veelal regionaal.
```
mannen=Arien,Adrien,Jurrien,Chretien,Sebastien,Esra,Cretien,Bonaventura,Josua,Jozua,Bastien,Juda,Julien,Jurien,Lucien,Martien
vrouwen=Agnes,Angenes,Judik,Margo,Marian,Marjan,Agenes,Cato,Catho,Agnees,Angenees,Agnus,Gertrudes,Gertrudus
```
*Kolommen*
De volgende kolommen zijn aanwezig in de output:
- Type (aktesoort)
- Meldcode (korte aanduiding van het type melding)
- Melding (Specifiekere uitleg van het mogelijke probleem)
- Gemeente (Gemeentenaam uit de akte)
- Jaar (Aktejaar)
- Aktenr (Aktenummer uit de akte)
- Veld (Het A2A-veld waarvoor de melding geldt)
- Waarde (De waarde waarvoor de melding geldt, [LEEG] indien deze waarde leeg is)
- Context (Context waarbinnen de melding is gegenereerd, bv. de akte of een specifieke persoon)
- Link (Een hyperlink naar de akte)
- GUID (De GUID van de akte, bijvoorbeeld om een interne link naar het CBS te kunnen maken tbv correctie)
- Scans (Aanduiding of er scans beschikbaar zijn bij de akte, met het oog op het uitvoeren van de controle)
## Controles
Controles worden uitgevoerd op:
- structuur aktenummer
- geldigheid van datums
- structuur van algemene en specifieke naamdelen (voornaam, patroniem, tussenvoegsel, achternaam)
- tekencombinaties in naamdelen
- overeenkomsten tussen naam kind en naam ouder (moeder in geval geen vader bekend)
- geslacht (op basis van naam)
- gebruikte rollen
- leeftijden
