#!/usr/bin/perl
use strict;
use warnings;
use XML::LibXML::Reader;
use XML::Bare;
use Data::Dumper;
use Text::WagnerFischer qw/distance/;
use Date::Calc qw/check_date Delta_Days/;
use Config::Simple;
use File::Basename;
use Getopt::Long;
use Excel::Writer::XLSX;
#
my $dir = dirname(__FILE__);

# gezamenlijke functies uit extern script laden
require $dir.'/include/a2a_utils.pl';
my( $in, $out);

# waarden uit configuratiebestand laden
my $cfg = new Config::Simple($dir.'/config/a2actl.ini');
my $bsh = $cfg->get_block('BS_H');
our $alg = $cfg->get_block('ALGEMEEN');

my $vanaf = 0;
GetOptions( "vanaf:i" => \$vanaf );
die "Fout: Startjaar (parameter --vanaf) (".$vanaf.") is groter dan configuratieparameter max_jaar ".$bsh->{'max_jaar'}
    if $vanaf > $bsh->{'max_jaar'}; 

die "Gebruik: perl bsh.pl <A2A-bestand> <LOG-bestand>\n" 
    if( scalar @ARGV ) ne 2;
$in = $ARGV[0];
$out = $ARGV[1];
$in eq $out
    and die "Naam van A2A-bestand en LOG-bestand mogen niet gelijk zijn.";

-e $in
    or die "A2A-bestand bestaat niet\n";
my $reader = XML::LibXML::Reader->new(location => $in)
    or die "Kan het A2A bestand niet openen\n";

-e $out
    and die "Logbestand bestaat al\n";
$out =~ /\.xlsx/i
    or die "Het logbestand moet een .XLSX extensie hebben";
open LOG, "> ".$out 
    or die "Kan het logbestand niet openen\n";
close(LOG);
my $xlsx = Excel::Writer::XLSX->new($out);
my $logs = $xlsx->add_worksheet();

local $| = 1; # auto flush
my @vrwrol = ('Bruid','Moeder van de bruid','Moeder van de bruidegom');
my @manrol = ('Bruidegom','Vader van de bruid','Vader van de bruidegom');
my %akten;
my $n = 0;
my $c = 0;
our $err = 0;

while ($reader->nextElement("A2A", "http://Mindbus.nl/A2A")) {
    $logs->write_row(0, 0, ["Soort","Meldcode","Melding","Gemeente","Jaar","Aktenr","Veld","Waarde","Context","Link","GUID","Scans"])
        if $n==0;
    $n++;
    my $xml = $reader->readOuterXml();
    
    $xml =~ s/a2a://ig;
    #
    # bestand parsen: telkens een metadata-fragment verwerken en dan in een Perl hash inlezen
    #
    my $ref = XML::Bare->new(text => $xml);
    my $root = $ref->parse();
    my $a2a = $root->{A2A};
    next unless $a2a->{Source}->{SourceType}->{value} eq 'BS Huwelijk';
    my $nnescio = qr/$alg->{'regex_nn'}/i;
    
    no warnings 'numeric';
    my $jaar = $a2a->{Source}->{SourceDate}->{Year}->{value}||0;
    next unless $jaar >= $vanaf;
    $c++;
    use warnings 'numeric';

    my $rm;
    if( $rm = $a2a->{Source}->{SourceRemark}->{Key}->{Value}->{value} and $a2a->{Source}->{SourceRemark}->{Key}->{value} eq 'Opmerking' ) {
        # doe ff niks met opmerkingen nog
    }
    
    # REGEL: het aktenummer mag niet leeg zijn of ontbreken
    if( my $docnr = $a2a->{'Source'}->{SourceReference}->{DocumentNumber}->{value} ) {
        my $re = qr/$bsh->{'regex_aknr'}/;
        if( $docnr eq '') {
            $logs->write_row($err, 0, &logErr('BS_H','AKTENUMMER_LEEG','DocumentNumber', "", 
                "Het aktenummer is leeg", $a2a, "AKTE"));
        } elsif( $docnr !~  $re ) {
        # REGEL: het aktenummer voldoet aan het stramien zoals vastgelegd in regex_aknr
            $logs->write_row($err, 0, &logErr('BS_H','AKTENUMMER_ONBEKEND','DocumentNumber', $docnr, 
                "Het aktenummer lijkt onbekende tekens te bevatten", $a2a, "AKTE"));
        }
    } else {
        # REGEL: het aktenummer mag niet leeg zijn of ontbreken
        # herhaling van regel 2, omdat de XML-structuur helemaal niet bestaat
        $logs->write_row($err, 0, &logErr('BS_H','AKTENUMMER_LEEG','DocumentNumber', "", 
                "Het aktenummer is leeg", $a2a, "AKTE"));
    }

    no warnings 'numeric';
    $akten{$a2a->{Source}->{SourcePlace}->{Place}->{value}}{$a2a->{Source}->{SourceReference}->{Book}->{value}}{int($a2a->{'Source'}->{SourceReference}->{DocumentNumber}->{value})}++;
    use warnings 'numeric';

    # controles op EventDate
    my( $akyr, $akmnd, $akdag );
    if( $akyr = $a2a->{Event}->{EventDate}->{Year}->{value} ) {
        if( $akyr < $bsh->{min_jaar} or $akyr > $bsh->{max_jaar} ) {
            # REGEL: Het aktejaar moet voldoen aan het in de configuratie ingestelde maximum/minimum
            $logs->write_row($err, 0, &logErr('BS_H',"DATUM_FOUT",'EventDate', $akyr,
                "Het aktejaar is kleiner of groter dan het ingestelde minumum/maximum", $a2a, "[AKTE"));
        }
        if( $akmnd = $a2a->{Event}->{EventDate}->{Month}->{value} and $akdag = $a2a->{Event}->{EventDate}->{Day}->{value} ) {
            unless( check_date($akyr, $akmnd, $akdag) ) {
                # REGEL: De aktedatum mag geen ongeldige datum zijn
                $logs->write_row($err, 0, &logErr('BS_H',"DATUM_FOUT",'EventDate', $akyr."-".$akmnd."-".$akdag,
                    "De aktedatum is ongeldig", $a2a, "[AKTE]"));
            }
        }
    }

    # lijst met personen opbouwen
    my $persons;
    if( ref($root->{A2A}->{Person}) eq 'ARRAY' ) {
        $persons = $root->{A2A}->{Person};
    } elsif( defined $root->{A2A}->{Person} ){
        $persons = [$root->{A2A}->{Person}];
    } else {
        # REGEL: Een akte moet altijd personen bevatten
        $logs->write_row($err, 0, &logErr('BS_H','GEEN_PERSONEN','','',"Deze akte bevat geen personen", $a2a, "AKTE"));
    }
    # lijst met relaties opbouwen als arrays voor eenduidige verwerking
    my $rels;
    if( ref($root->{A2A}->{RelationEP}) eq 'ARRAY' ) {
        $rels = $root->{A2A}->{RelationEP};
    } elsif( defined $root->{A2A}->{RelationEP} )  {
        $rels = [$root->{A2A}->{RelationEP}];
    }
    # ook de Persoon-Persoon relaties
    my $relpps;
    if( ref($root->{A2A}->{RelationPP}) eq 'ARRAY' ) {
        $relpps = $root->{A2A}->{RelationPP};
    } elsif(defined $root->{A2A}->{RelationPP}) {
        $relpps = [$root->{A2A}->{RelationPP}];
    }
    # relatiemap opbouwen
    my %relmap;
    my %revmap;
    foreach my $r (@{$rels}) {
        $relmap{$r->{PersonKeyRef}->{value}} = $r->{RelationType}->{value};
        $revmap{$r->{RelationType}->{value}}++;
    }
    foreach my $r (@{$relpps}) {
        $relmap{$r->{PersonKeyRef}->[1]->{value}} = $r->{RelationType}->{value};
        $revmap{$r->{RelationType}->{value}}++;
    }
    if( defined $persons and scalar @{$persons} < 2  ) {
        # REGEL: een huwelijksakte bestaat uit minimaal 2 personen
        $logs->write_row($err, 0, &logErr('BS_H','WEINIG_PERSONEN','AantalPersonen', scalar @{$persons}, 
            "De huwelijksakte bevat minder dan het reguliere minimmum van 2 personen.", $a2a, "AKTE: ".$rm));
    } elsif( defined $persons and scalar @{$persons} > 6 ) {
        # REGEL: een huwelijksakte bestaat uit maximaal 6 personen
        $logs->write_row($err, 0, &logErr('BS_H','VEEL_PERSONEN','AantalPersonen', scalar @{$persons}, 
            "De huwelijksakte bevat meer dan het reguliere maximum van 6 personen.", $a2a, "AKTE: ".$rm));
    }
    foreach my $rol (qw/Bruid Bruidegom/) {
        if( !defined($revmap{$rol}) ) {
            # REGEL: Een huwelijksakte moet een bruid of bruidegom bevatten
            $logs->write_row($err, 0, &logErr('BS_H','ROL_ONTBREEKT', $rol, "[LEEG]"    , 
                "De huwelijksakte bevat geen ".$rol, $a2a, "AKTE: ".$rm));
        } elsif( $revmap{$rol} > 1 ) {
            # REGEL: Een huwelijksakte bevat maximaal maar 1 bruid of bruidegom
            $logs->write_row($err, 0, &logErr('BS_H','ROL_DUBBEL','Aantal'.$rol, $revmap{$rol}, 
                "De huwelijksakte bevat meer dan 1 ".$rol, $a2a, "AKTE: ".$rm));
        }
    }
    foreach my $rol ('Vader van de bruidegom','Moeder van de bruidegom','Vader van de bruid','Moeder van de bruid') {
        if( defined($revmap{$rol}) && $revmap{$rol} > 1 ) {
            # REGEL: De overige rollen mogen ook maar 1x voorkomen
            $logs->write_row($err, 0, &logErr('BS_H','ROL_DUBBEL','Aantal'.$rol, $revmap{$rol}, 
                "Een huwelijksakte bevat doorgaans maar 1 ".$rol, $a2a, "AKTE: ".$rm));
        }
    }
    my %fam;
    # alle personen bijlangs
    foreach my $p (@{$persons}) {
        my $rol = $relmap{$p->{pid}->{value}};
        unless($rol) {
            # REGEL: Elke persoon heeft een rol.
            $logs->write_row($err, 0, &logErr('BS_H',"GEEN_ROL","RelationType", "", 
            "De persoon heeft geen rol", $a2a, "PERSOON: ".&maakNaam($p)." (LEEG)"));
        }
        # Relaties kunnen meer dan 1x voorkomen, dus deze vastleggen als array. De unieke relaties vastleggen als waarde
        if( $rol eq 'Relatie' ) {
            push(@{$fam{$rol}},$p);
        } else{
            $fam{$rol} = $p;
        }
        if( not(length($p->{PersonName}->{PersonNameLastName}->{value})) and not(length($p->{PersonName}->{PersonNamePatronym}->{value})) ) {
            # REGEL: Achternaam en patroniem mogen niet beide leeg zijn
            $logs->write_row($err, 0, &logErr('BS_H',"NAAMDEEL_LEEG",'PatroniemOfAchternaam', "", 
            "De achternaam en het patroniem zijn beide leeg", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")"));
        } elsif( not(length($p->{PersonName}->{PersonNameFirstName}->{value})) and lc $p->{PersonName}->{PersonNameLastName}->{value} ne lc $nnescio) {
            # REGEL: Voornaam moet gevuld zijn wanneer Achternaam of Patroniem gevuld is.
            $logs->write_row($err, 0, &logErr('BS_H',"NAAMDEEL_LEEG",'Voornaam', "", 
                "De voornaam is leeg", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")"));
        }
        # naamdelen van de persoon afhandelen
        foreach my $w (qw/PersonNameLastName PersonNameFirstName PersonNamePatronym PersonNamePrefixLastName/) {
            if( defined $p->{PersonName}->{$w}->{value} ) {
                if( length $p->{PersonName}->{$w}->{value} && $p->{PersonName}->{$w}->{value} =~ /\s{2,}/ ) {
                    # REGEL: Het voorkomen van 2 of meer opvolgende spaties is verdacht
                    $logs->write_row($err, 0, &logErr('BS_H',"SPATIES", $w,$p->{PersonName}->{$w}->{value},
                    "Het naamdeel bevat 2 of meer spaties", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")"));
                }
                if( length $p->{PersonName}->{$w}->{value} && $p->{PersonName}->{$w}->{value} =~ qr/[aeiou]{$alg->{'max_klinkers'},}/ ) {
                    # REGEL: Een naamdeel mag niet meer dan een geconfigureerd aantal opeenvolgende klinkers bevatten
                    $logs->write_row($err, 0, &logErr('BS_H',"KLINKERS", $w,$p->{PersonName}->{$w}->{value},
                    "Het naamdeel bevat ".$alg->{'max_klinkers'}." of meer klinkers", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")"));
                }
                if( length $p->{PersonName}->{$w}->{value} && $p->{PersonName}->{$w}->{value} =~ qr/[bcdfghjklmnpqrstvwx]{$alg->{'max_medeklinkers'},}/ ) {
                    # REGEL: Een naamdeel mag niet meer dan een geconfigureerd aantal opeenvolgende medeklinkers bevatten
                    $logs->write_row($err, 0, &logErr('BS_H',"MEDEKLINKERS", $w,$p->{PersonName}->{$w}->{value},
                    "Het naamdeel bevat ".$alg->{'max_medeklinkers'}." of meer medeklinkers", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")"));
                }
                # REGEL: een naamdeel mag niet 3x hetzelfde teken achtereen bevatten, met uitzondering van 3 puntjes
                if( length $p->{PersonName}->{$w}->{value} && $p->{PersonName}->{$w}->{value} =~ /([^\.])\1\1/ ) {
                    $logs->write_row($err, 0, &logErr('BS_H',"HERHALING", $w,$p->{PersonName}->{$w}->{value},
                    "Het naamdeel bevat 3x hetzelfde teken", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")"));
                }
            }
        }
        my $re_tv = qr/^($alg->{'regex_tvoeg'}(\s+$alg->{'regex_tvoeg'})*)$/;
        my $re_nd = qr/^($alg->{'regex_naamdeel'}(\s+($alg->{'regex_naamdeel'}|$alg->{'regex_tvoeg'}))*)$/;
        if( my $an = $p->{PersonName}->{PersonNameLastName}->{value} ) {
            unless( (lc $an eq lc $nnescio or $an eq "-" or $an =~ $re_nd) ) {
                    # REGEL: Een achternaam voldoet aan een geconfigureerd stramien
                    $logs->write_row($err, 0, &logErr('BS_H',"WAARDE_VERDACHT","PersonNameLastName", $an, 
                "De achternaam lijkt onbekende tekens te bevatten", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")"));
                }
        }
        if( my $pn = $p->{PersonName}->{PersonNamePatronym}->{value} ) {
            #unless( $pn =~ /^(([A-Z]|IJ)\p{Ll}*)(\'s|\.)?$/ ) {
            my $re_pn = qr/$alg->{'regex_patroniem'}/;
            unless( $pn =~ $re_pn ) {
                # REGEL: Patroniem moet voldoen aan een bepaald stramien)
                $logs->write_row($err, 0, &logErr('BS_H',"WAARDE_VERDACHT","PersonNamePatronym", $pn, 
                "Het patroniem lijkt onbekende tekens te bevatten", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")"));
            }
        }
        if( my $fn = $p->{PersonName}->{PersonNameFirstName}->{value} ) {
            my @temp = split / +/, $fn;
            foreach my $part (@temp) {
                unless ($part =~ /^(((([A-Z]|IJ)\.)+|([A-Z]|IJ)\p{Ll}+\.?))$/) {
                    # REGEL: Voornaam moet voldoen aan een stramien
                    $logs->write_row($err, 0, &logErr('BS_H',"WAARDE_VERDACHT","PersonNameFirstName", $fn, 
                "De voornaam lijkt onbekende tekens te bevatten", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")"));
                    last;
                }
            }
            my $bla1 = substr($temp[0], -2);
            my $bla2 = substr($temp[0], -1);
            my $bla3 = substr($temp[0], -3);
            if( ($bla1 =~ /(us|rt|rd|an|ik|of|as|ob|em|es|nd|zo)/  or $bla2 eq 'o') and grep { $rol eq $_ } @vrwrol and !grep { $temp[0] eq $_ } @{$alg->{vrouwen}}) {
                # REGEL: verdacht als de naam van een vrouw op een "mannelijke" uitgang eindigt
                $logs->write_row($err, 0, &logErr('BS_H',"GESLACHT_FOUT", "PersonNameFirstName", $temp[0],
                "Op basis van de naam zou dit een man kunnen zijn ipv een vrouw", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")"));
            } elsif( ($bla2 eq 'a' or $bla3 =~ /([bdfgknps]je|.th)/) and grep { $rol eq $_ } @manrol and !grep { $temp[0] eq $_ } @{$alg->{mannen}}) {
                # REGEL: verdacht als de naam van een man op een "vrouwelijke" uitgang eindigt
                $logs->write_row($err, 0, &logErr('BS_H',"GESLACHT_FOUT", "PersonNameFirstName", $temp[0],
                "Op basis van de naam zou dit een vrouw kunnen zijn ipv een man", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")"));
            } elsif( ($bla3 =~ /(ien|[wnfb]ke)/ and !grep { $temp[0] eq $_} @{$alg->{mannen}} ) and grep { $rol eq $_ } @manrol ) {
                # REGEL: verdacht als de naam van een man op een "vrouwelijke" uitgang eindigt
                $logs->write_row($err, 0, &logErr('BS_H',"GESLACHT_FOUT", "PersonNameFirstName", $temp[0],
                "Op basis van de naam zou dit een vrouw kunnen zijn ipv een man", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")"));
            }
        }
        if( $p->{PersonName}->{PersonNamePrefixLastName}->{value} ) {
            unless( $p->{PersonName}->{PersonNamePrefixLastName}->{value} =~ $re_tv ) {
                # REGEL: Het tussenvoegsel moet aan het geconfigureerde stramien voldoen
                $logs->write_row($err, 0, &logErr('BS_H',"WAARDE_VERDACHT",'PersonNamePrefixLastName', $p->{PersonName}->{PersonNamePrefixLastName}->{value}, 
            "Het tussenvoegsel lijkt onbekende tekens te bevatten", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")"));
            }
        }
         # check beroep op vreemde tekens
        if( my $prof = $p->{Profession}->{value} ) {
            unless( $prof eq "" or $prof =~ /^([\p{Ll}\p{Lu}0-9\'\-\(\)\.\/ ,]|&amp;)+$/ ) {
                # REGEL: Het beroep voldoet aan een bepaald stramien
                $logs->write_row($err, 0, &logErr('BS_H',"WAARDE_VERDACHT",'Profession', $prof, 
                    "Het beroep lijkt onbekende tekens te bevatten", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")"));
                #} elsif( $prof =~ /\.$/ ) {
                #$logs->write_row($err, 0, &logErr('BS_H',"WAARDE_AFGEKAPT",'Profession', $prof, 
                #    "Het beroep is misschien afgekapt op een vaste lengte", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")");
            }
            if( $prof =~ /(.)\1\1/ ) {
                # REGEL: Het beroep bevat nooit 3x hetzelde opeenvolgende teken
                $logs->write_row($err, 0, &logErr('BS_H',"WAARDE_VERDACHT",'Profession', $prof, 
                    "Het beroep bevat 3x hetzelfde teken", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")"));
            }
        }
        if( my $bplace = $p->{BirthPlace}->{Place}->{value} ) {
            unless( $bplace =~ /^([\p{Ll}\p{Lu}\'\-\., \(\)\/\[\]]|&amp;)+$/ ) {
                # REGEL: De geboorteplaats moet voldoen aan een stramien
                $logs->write_row($err, 0, &logErr('BS_H',"WAARDE_VERDACHT",'BirthPlace', $bplace, 
                    "De geboorteplaats lijkt onbekende tekens te bevatten", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")"));
            }
            if( $bplace =~ /(.)\1\1/ ) {
                # REGEL: De geboorteplaats bevat nooit 3x hetzelde opeenvolgende teken
                $logs->write_row($err, 0, &logErr('BS_H',"HERHALING",'BirthPlace', $bplace, 
                    "De geboorteplaats bevat 3x hetzelfde teken", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")"));
            } 
        }
        
        if( my $byr = $p->{BirthDate}->{Year}->{value} ) {
            if( ($akyr - $byr) <= $bsh->{min_leeftijd} ) {
                # REGEL: Leeftijd mag niet kleiner zijn dan min_age
                $logs->write_row($err, 0, &logErr('BS_H',"TE_JONG",'BirthDate', $akyr-$byr, 
                    "Verschil tussen aktejaar en geboortejaar is kleiner dan min_leeftijd", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")"));
            } elsif( ($akyr - $byr) > $bsh->{max_leeftijd} ) {
                # REGEL 30 Leeftijd mag niet groter zijn dan max_age
                $logs->write_row($err, 0, &logErr('BS_H',"TE_OUD",'BirthDate', $akyr-$byr, 
                    "Verschil tussen aktejaar en geboortejaar is groter dan max_leeftijd", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")"));
            }
            my $bmd = $p->{BirthDate}->{Month}->{value};
            my $bdg = $p->{BirthDate}->{Day}->{value};
            unless( check_date($akyr, $akmnd, $akdag) ) {
                # REGEL: Geboortedatum moet een geldige datum zijn
                $logs->write_row($err, 0, &logErr('BS_H',"DATUM_FOUT",'BirthDate', $byr."-".$bmd."-".$bdg,
                    "Geboortedatum ongeldig", $a2a, "PERSOON: ".&maakNaam($fam{'Bruidegom'})." (Bruidegom)"));
            }
        }
        
        if( my $age = $p->{PersonAgeLiteral}->{value} ) {
            # REGEL: Leeftijd moet een getal zijn
            $logs->write_row($err, 0, &logErr('BS_H','GEEN_GETAL','PersonAgeLiteral', $age,
                "Leeftijd is niet uitsluitend een getal", $a2a, "PERSOON: ".&maaknaam($p)." (".$rol.")")) unless $age =~ /^\d+$/;
            unless( int($age) < $bsh->{min_age} ) {
                # REGEL 29a: Leeftijd mag niet kleiner zijn dan min_age
                $logs->write_row($err, 0, &logErr('BS_H',"TE_JONG",'PersonAgeLiteral', $age, 
                    "Leeftijd lager dan ".$bsh->{'min_age'}, $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")"));    
            } elsif( int($age) > $bsh->{max_age} ) {
                # REGEL 30a Leeftijd mag niet groter zijn dan max_age
                $logs->write_row($err, 0, &logErr('BS_H',"TE_OUD",'PersonAgeLiteral', $age, 
                    "Leeftijd groter dan ".$bsh->{'max_age'}, $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")"));                    
            }
        }
                
        #if( my $rm = $p->{PersonRemark}->{Key}->{Value}->{value} and $p->{PersonRemark}->{Key}->{value} eq 'diversen' ) {
        #    if( $rm =~ /van van/ ) {
        #        $logs->write_row($err, 0, &logErr('BS_H',"VAN_VAN",'PersonRemark', $rm, 
        #            "Van van in opmerkingen", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")");    
        #    }
        #}
    }
    for my $r (qw/Bruid Bruidegom/) {
        # gekopieerd van controle overlijdensakten, vandaar naamgeving variabelen
        my $achvaov = $fam{'Vader van de '.lc $r}->{PersonName}->{PersonNameLastName}->{value}||"";
        my $achmoov = $fam{'Moeder van de '.lc $r}->{PersonName}->{PersonNameLastName}->{value}||"";
        my $achnaov = $fam{$r}->{PersonName}->{PersonNameLastName}->{value}||"";
        if( length $achnaov and lc $achnaov ne lc $nnescio and $achnaov ne '-') {
            # achternaam persoon is gevuld en niet bepaalde waardes
            unless( $achvaov eq $achnaov ) {
                # achternaam persoon is niet gelijk aan die van de vader
                # bij kortere namen (<=4 tekens) mag het verschil maar 1 wijziging zijn
                # bij langere namen max 2 wijzigingen
                # volgens de Wagner-Fischer methode
                my $d = $alg->{'edit_distance'};
                # edit distance kleiner maken als het een korte naam betreft
                $d -= 1 if length $achnaov <= 4;
                if( length $achvaov and $achvaov ne '-' and lc $achvaov ne 'n.n.' and  distance( $achnaov, $achvaov ) < $d  ) {
                    # REGEL: achternaam vader bevat geen vreemde waardes en ligt dicht bij die van de overledene
                    $logs->write_row($err, 0, &logErr('BS_H',"NAAM_MISMATCH",'PersonNameLastName', $fam{$r}->{PersonName}->{PersonNameLastName}->{value}." <=> ".$fam{'Vader van de '.lc $r}->{PersonName}->{PersonNameLastName}->{value},
                            "Naam vader en ".$r." komen niet overeen, maar liggen dicht bijelkaar. Typefout?", $a2a, "PERSOON: ".&maakNaam($fam{$r})." (".$r.")"));
                } elsif( $achmoov ne $achnaov ) {
                # achternaam ook niet gelijk aan die van de moeder
                    if( length $achmoov and $achmoov ne '-' and lc $achmoov ne 'n.n.' and distance( $achmoov, $achnaov ) < $d) {
                        # REGEL: achternaam is niet gelijk, maar ligt dicht bij de naam overledene
                        $logs->write_row($err, 0, &logErr('BS_H',"NAAM_MISMATCH",'PersonNameLastName', $fam{$r}->{PersonName}->{PersonNameLastName}->{value}." <=> ".$fam{'Moeder van de '.lc $r}->{PersonName}->{PersonNameLastName}->{value},
                            "Naam moeder en ".$r." komen niet overeen, maar liggen dicht bijeelkaar. Typefout?", $a2a, "PERSOON: ".&maakNaam($fam{$r})." (".$r.")"));
                    }
                }
            }
        }
    }
}
foreach my $p (sort keys %akten) {
    foreach my $y (sort keys %{$akten{$p}}) {
        my $counter = 0;
        foreach my $n (sort {$a <=> $b} keys %{$akten{$p}{$y}}) {
            if( ($n-$counter) > 1 or ($n-$counter) < 1 ) {
                $logs->write_row($err, 0, &logErr('BS_H',"AKNUM_FOUT",'DocumentNumber', $p."/".$y."/".$n." ==> ".$counter,
            "Verschil met vorige aktenummer meer dan 1. Ontbreekt er wat?", undef, "ALLE AKTEN"));
            }
            $counter = $n;
        }
    }
}
$xlsx->close();
warn $c." van ".$n." records gecontroleerd";
