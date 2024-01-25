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
