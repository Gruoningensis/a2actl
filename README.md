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
[ALG]
separator=#
```
De variable *separator* wordt hier ingesteld op een #-teken, wat betekent dat de kolommen in de output middels dit #-teken van elkaar gescheiden worden. Het is verstandig om een teken te kiezen dat niet voorkomt in de verschillende tekstvelden die worden weggeschreven.
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
  log="./log/"${file%%.xml}".csv"
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
Het resultaat van een run van het script is een logfile die middels Excel kan worden omgezet in een spreadsheet, alwaar de (mogelijke) fouten geanalyseerd kunnen worden. Het is van belang om daarbij te realiseren dat het script 'false positives' zal genereren. Er wordt alleen een vermoeden uitgesproken van een fout; of dit daadwerkelijk het geval is zal geverifieerd moeten worden. Ten behoeve daarvan worden de links naar de records meegenomen in de output.
Om het aantal 'false positives' in te perken kan gebruikgemaakt worden van parameters in het configuratiebestand. Zo bepalen de parameters 'mannen' en 'vrouwen' welke namen respectievelijk niet als man of vrouw worden herkend. Dit onderscheid is veelal regionaal.
```
mannen=Arien,Adrien,Jurrien,Chretien,Sebastien,Esra,Cretien,Bonaventura,Josua,Jozua,Bastien,Juda,Julien,Jurien,Lucien,Martien
vrouwen=Agnes,Angenes,Judik,Margo,Marian,Marjan,Agenes,Cato,Catho,Agnees,Angenees,Agnus,Gertrudes,Gertrudus
```
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
