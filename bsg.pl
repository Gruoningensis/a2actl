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
#
my $dir = dirname(__FILE__);

# gezamenlijke functies uit extern script laden
require $dir.'/include/a2a_utils.pl';
my( $in, $out);

# waarden uit configuratiebestand laden
my $cfg = new Config::Simple($dir.'/config/a2actl.ini');
my $bsg = $cfg->get_block('BS_G');
our $alg = $cfg->get_block('ALGEMEEN');

my $vanaf = 0;
GetOptions( "vanaf:i" => \$vanaf );
die "Fout: Startjaar (parameter --vanaf) (".$vanaf.") is groter dan configuratieparameter max_jaar ".$bsg->{'max_jaar'}
    if $vanaf > $bsg->{'max_jaar'}; 

die "Gebruik: perl bsg.pl <A2A-bestand> <LOG-bestand>\n" 
    if( scalar @ARGV ) ne 2;
$in = $ARGV[0];
$out = $ARGV[1];

-e $in
    or die "A2A-bestand bestaat niet\n";
my $reader = XML::LibXML::Reader->new(location => $in)
    or die "Kan het A2A bestand niet openen\n";

-e $out
    and die "Logbestand bestaat al\n";
open LOG, "> ".$out 
    or die "Kan het logbestand niet openen\n";

local $| = 1; # auto flush

my %akten;
my $n = 0;
my $c = 0;

while ($reader->nextElement("A2A", "http://Mindbus.nl/A2A")) {
    print LOG join($alg->{'separator'},"Soort","Meldcode","Melding","Gemeente","Jaar","Aktenr","Veld","Waarde","Context","Link","GUID","Scans")."\n"
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
    my $nnescio = qr/$alg->{'regex_nn'}/i;

    no warnings 'numeric';
    my $jaar = $a2a->{Source}->{SourceDate}->{Year}->{value}||0;
    next unless $jaar >= $vanaf;
    $c++;
    use warnings 'numeric';
    
    # REGEL 1: het aktenummer mag niet leeg zijn
    if( my $docnr = $a2a->{'Source'}->{SourceReference}->{DocumentNumber}->{value} ) {
        my $re = qr/$bsg->{'regex_aknr'}/;
        if( $docnr eq '') {
            &logErr('BS_G','AKTENUMMER_LEEG','DocumentNumber', "", 
                "Het aktenummer is leeg", $a2a, "AKTE");
        } elsif( $docnr !~  $re ) {
        # REGEL 2: het aktenummer bestaat alleen uit getallen gevolgd door een kleine letter of een hoofdletter S (van supplement)
            &logErr('BS_G','AKTENUMMER_ONBEKEND','DocumentNumber', $docnr, 
                "Het aktenummer lijkt onbekende tekens te bevatten", $a2a, "AKTE");
        }
    } else {
        # herhaling van regel 2, omdat de XML-structuur helemaal niet bestaat
        &logErr('BS_G','AKTENUMMER_LEEG','DocumentNumber', "", 
                "Het aktenummer is leeg", $a2a, "AKTE");
    }
    no warnings 'numeric';
    $akten{$a2a->{Source}->{SourcePlace}->{Place}->{value}}{$a2a->{Source}->{SourceReference}->{Book}->{value}}{int($a2a->{'Source'}->{SourceReference}->{DocumentNumber}->{value})}++;
    use warnings 'numeric';

    my $persons;
    if( ref($root->{A2A}->{Person}) eq 'ARRAY' ) {
        $persons = $root->{A2A}->{Person};
    } elsif( defined $root->{A2A}->{Person} ){
        $persons = [$root->{A2A}->{Person}];
    } else {
        # REGEL 3: een akte hoort personen te bevatten
        &logErr('BS_G','GEEN_PERSONEN','','',"Deze akte bevat geen personen", $a2a, "AKTE");
    }
    # zorgen dat er netjes arrays worden opgebouwd van relaties
    my $rels;
    if( ref($root->{A2A}->{RelationEP}) eq 'ARRAY' ) {
        $rels = $root->{A2A}->{RelationEP};
    } elsif( defined $root->{A2A}->{RelationEP} )  {
        $rels = [$root->{A2A}->{RelationEP}];
    }
    my $relpps;
    if( ref($root->{A2A}->{RelationPP}) eq 'ARRAY' ) {
        $relpps = $root->{A2A}->{RelationPP};
    } elsif(defined $root->{A2A}->{RelationPP}) {
        $relpps = [$root->{A2A}->{RelationPP}];
    }
    my %relmap;
    foreach my $r (@{$rels}) {
        $relmap{$r->{PersonKeyRef}->{value}} = $r->{RelationType}->{value};
    }
    foreach my $r (@{$relpps}) {
        $relmap{$r->{PersonKeyRef}->[1]->{value}} = $r->{RelationType}->{value};
    }
    my %fam;
    # REGEL 4: een geboorteakte bestaat uit maximaal 3 personen (vader, moeder, kind)
    if( defined $persons and scalar @{$persons} > 3 ) {
        &logErr('BS_G','TEVEEL_PERSONEN','AantalPersonen', scalar @{$persons}, 
            "Een geboorteakte bevat doorgaans maximaal 3 personen.", $a2a, "AKTE");
    }
    # alle personen bij langs
    foreach my $p (@{$persons}) {
        my $rol;
        unless($rol = $relmap{$p->{pid}->{value}}) {
            # REGEL 5: elke persoon heeft een rol
            &logErr('BS_G',"GEEN_ROL","RelationType", "", 
            "De persoon heeft geen rol", $a2a, "PERSOON: ".&maakNaam($p)." (LEEG)");
        }
        if( $rol eq 'Relatie' ) {
            push(@{$fam{$rol}},$p);
        } elsif( defined($fam{$rol}) ) {
            # REGEL 6: Alle rollen behalve Relatie zijn uniek
            # wellicht dat dit bij tweeling niet goed uitpakt?
            &logErr('BS_G',"DUBBELE_ROL","RelationType", $rol, 
            "De rol komt meer dan 1x voor", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")");            
        } else {
            $fam{$rol} = $p;
        }
        if( not(length($p->{PersonName}->{PersonNameLastName}->{value})) 
                and not(length($p->{PersonName}->{PersonNamePatronym}->{value})) ) {
            # REGEL 7: achternaam en patroniem mogen niet allebei leeg zijn
            # 
            &logErr('BS_G',"NAAMDEEL_LEEG",'PatroniemOfAchternaam', "", 
            "De achternaam en het patroniem zijn beide leeg", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")");
        } elsif( not(length($p->{PersonName}->{PersonNameFirstName}->{value})) and lc $p->{PersonName}->{PersonNameLastName}->{value} !~ $nnescio) {
            # REGEL 8: voornaam mag niet leeg zijn
            &logErr('BS_G',"NAAMDEEL_LEEG",'Voornaam', "", 
                "De voornaam is leeg", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")");
        }
        # algemene checks op naamdelen 
        my $re_tv = qr/^($alg->{'regex_tvoeg'}(\s+$alg->{'regex_tvoeg'})*)$/;
        my $re_nd = qr/^($alg->{'regex_naamdeel'}(\s+($alg->{'regex_naamdeel'}|$alg->{'regex_tvoeg'}))*)$/;
        #die Dumper($re_nd);
        foreach my $w (qw/PersonNameLastName PersonNameFirstName PersonNamePatronym/) {
            if( defined($p->{PersonName}->{$w}->{value}) ) {
                if( lc $p->{PersonName}->{$w}->{value} !~ $nnescio and $p->{PersonName}->{$w}->{value} ne "-") {
                        unless(  $p->{PersonName}->{$w}->{value} =~ $re_nd ) {
                        # REGEL 9: een naamdeel bestaat in principe uit een woord beginnende met een hoofdletter,
                        # gevolg door kleine letters, eventueel gevolgd door een tussenvoegsel
                        &logErr('BS_G',"WAARDE_VERDACHT",$w, $p->{PersonName}->{$w}->{value}, 
                        "De achter- of voornaam of het patroniem lijkt onbekende tekens te bevatten", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")");
                        }
                }
                    # REGEL 10: een naamdeel bevat niet vaak meer dan X klinkers achtereen
                    # aantal is configurabel via parameter max_klinkers
                if( length $p->{PersonName}->{$w}->{value} && $p->{PersonName}->{$w}->{value} =~ qr/[aeiou]{$alg->{'max_klinkers'},}/ ) {
                    &logErr('BS_G',"KLINKERS", $w, $p->{PersonName}->{$w}->{value},
                    "Het naamdeel bevat ".$alg->{'max_klinkers'}." of meer klinkers", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")");
                }
                    # REGEL 11: een naamdeel bevat niet vaak 6 of meer medeklinkers
                if( length $p->{PersonName}->{$w}->{value} && $p->{PersonName}->{$w}->{value} =~ qr/[bcdfghklmnpqrstvwx]{$alg->{'max_medeklinkers'},}/ ) {
                    &logErr('BS_G',"MEDEKLINKERS", $w, $p->{PersonName}->{$w}->{value},
                    "Het naamdeel bevat ".$alg->{'max_medeklinkers'}." of meer medeklinkers", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")");
                }
                    # REGEL 12: een naamdeel bevat nooit 3x hetzelfde teken achtereen
                if( length $p->{PersonName}->{$w}->{value} && $p->{PersonName}->{$w}->{value} =~ /([^\.])\1\1/ ) {
                    &logErr('BS_G',"HERHALING", $w, $p->{PersonName}->{$w}->{value},
                    "Het naamdeel bevat 3x hetzelfde teken", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")");
                }
            }
        }
        if( my $fn = $p->{PersonName}->{PersonNameFirstName}->{value} ) {
             if( my $gr = $p->{Gender}->{value} ) {
                if( $gr eq "Man" or $gr eq "Vrouw" ) {
                   my @temp = split / +/, $fn;
                   my $bla1 = substr($temp[0], -2)||"";
                   my $bla2 = substr($temp[0], -1)||"";
                   my $bla3 = substr($temp[0], -3)||"";
                   if( ($bla1 =~ /(us|rt|rd|an|ik|of|as|ob|em|es|nd|zo)/  or $bla2 eq 'o') and $p->{Gender}->{value} eq "Vrouw" and !grep { $temp[0] eq $_ } @{$alg->{vrouwen}}) {
                  # REGEL 13: verdacht als de naam van een vrouw op een mannelijke uitgang eindigt
                  &logErr('BS_G',"GESLACHT_FOUT", "PersonNameFirstName", $temp[0],
                  "Op basis van de naam zou dit een man kunnen zijn ipv een vrouw", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")");
                   } elsif( ($bla2 eq 'a' or $bla3 =~ /([bdfgknps]je|.th)/) and $p->{Gender}->{value} eq "Man" and !grep { $temp[0] eq $_ } @{$alg->{mannen}}) {
                   # REGEL 14a:  verdacht als de naam van een man op een vrouwelijke uitgang eindigt
                  &logErr('BS_G',"GESLACHT_FOUT", "PersonNameFirstName", $temp[0],
                  "Op basis van de naam zou dit een vrouw kunnen zijn ipv een man", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")");
                   } elsif( ($bla3 =~ /(ien|[wnfb]ke)/ and !grep { $temp[0] eq $_} @{$alg->{mannen}} ) and $p->{Gender}->{value} eq "Man" ) {
                  # REGEL 14b:  verdacht als de naam van een man op een vrouwelijke uitgang eindigt
                  &logErr('BS_G',"GESLACHT_FOUT", "PersonNameFirstName", $temp[0],
                  "Op basis van de naam zou dit een vrouw kunnen zijn ipv een man", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")");
                   }
                } else {
                   # REGEL 14c: een geslacht moet Man of Vrouw zijn
                   #   &logErr('BS_G',"GESLACHT_FOUT", "Gender", $gr,
                   #   "Geslacht moet Man of Vrouw zijn", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")");
                   #  REGEL uitgeschakeld ivm te veel vermeldingen
                }
             }
        }
        if( $p->{PersonName}->{PersonNamePrefixLastName}->{value} ) {
            unless( $p->{PersonName}->{PersonNamePrefixLastName}->{value} =~ $re_tv ) {
                # REGEL 15: tussenvoegsel bestaat uit een vast aantal woorden geschreven met kleine letters
                &logErr('BS_G',"WAARDE_VERDACHT",'PersonNamePrefixLastName', $p->{PersonName}->{PersonNamePrefixLastName}->{value}, 
                "Het tussenvoegsel lijkt onbekende tekens te bevatten", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")");
            }
            #REGEL 16: tussenvoegsel bevat nooit 3x hetzelfde teken
            if( $p->{PersonName}->{PersonNamePrefixLastName}->{value} =~ /(.)\1\1/ ) {
                &logErr('BS_G',"WAARDE_VERDACHT",'PersonNamePrefixLastName', $p->{PersonName}->{PersonNamePrefixLastName}->{value}, 
                "Het tussenvoegsel lijkt onbekende tekens te bevatten", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")");
            }
        }
        if( $p->{PersonName}->{PersonNamePatronym}->{value} ) {
            my $re_pn = qr($alg->{'regex_patroniem'});
            unless( $p->{PersonName}->{PersonNamePatronym}->{value} =~ $re_pn ) {
                # REGEL 26: Een patroniem heeft een vast stramien: eindigt op s, zoon of zn
                &logErr('BS_G',"WAARDE_VERDACHT",'PersonNamePatronym', $p->{PersonName}->{PersonNamePatronym}->{value}, 
                "Het patroniem voldoet niet aan het stramien", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")");
            }
        }
        if( my $prof = $p->{Profession}->{value} ) {
            unless( $prof eq "" or $prof =~ /^([\p{Ll}\p{Lu}0-9\'\-\(\)\.\/ ,]|&amp;)+$/ ) {
                #REGEL 17: beroep bestaat uit een vast stramien
                &logErr('BS_G',"WAARDE_VERDACHT",'Profession', $prof, 
                    "Het beroep lijkt onbekende tekens te bevatten", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")");
            } #elsif( $prof =~ /\.$/ ) {
            #  &logErr('BS_O',"WAARDE_AFGEKAPT",'Profession', $prof, 
            #    "Het beroep is misschien afgekapt op een vaste lengte", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")");
                #}
        }
        if( my $pal = $p->{Age}->{PersonAgeLiteral}->{value} ) {
            if( $pal =~ /^(\d+)( (jaar|jaren))?$/ ) {
                my $age = int($1);
                if( $age < $bsg->{min_leeftijd} or $age > $bsg->{max_leeftijd} ) {
                    #REGEL 18: jonger dan 18 of ouder dan 60 is verdacht
                    &logErr('BS_G',"LEEFTIJD",'PersonAgeLiteral', $age, 
                        "De persoon is erg jong of erg oud", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")");
                }
            }
        }
        if( my $bplace = $p->{BirthPlace}->{Place}->{value} ) {
                #REGEL 19: een geboorteplaats bevat bepaalde tekens
            unless( $bplace =~ /^([\p{Ll}\p{Lu}\'\-\., \(\)\/\[\]]|&amp;)+$/ ) {
                &logErr('BS_G',"WAARDE_VERDACHT",'BirthPlace', $bplace, 
                    "De geboorteplaats lijkt onbekende tekens te bevatten", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")");
            }
                #REGEL 20: een geboorteplaats bevat nooit 3x hetzelfde teken
            if( $bplace =~ /(.)\1\1/ ) {
                &logErr('BS_G',"WAARDE_VERDACHT",'BirthPlace', $bplace, 
                    "De geboorteplaats bevat 3x hetzelfde teken", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")");
            } 
        }
    }
    # als de naam van het kind gelijk is aan die van de vader, dan is dat normaal
    # als er geen vader is, dan is de achternaam vermoedelijk gelijk aan die van de moeder
    # als de naam van het kind maar een klein beetje verschilt van de naam van de naamgevende
    # ouder, dan is er waarschijnlijk sprake van een typefout
    # deze controle levert minder 'false positives' op dan een exacte controle van achternamen
    my $achvaov = $fam{'Vader'}->{PersonName}->{PersonNameLastName}->{value}||"";
    my $achmoov = $fam{'Moeder'}->{PersonName}->{PersonNameLastName}->{value}||"";
    my $achnaov = $fam{'Kind'}->{PersonName}->{PersonNameLastName}->{value}||"";
    if( length $achnaov and lc $achnaov ne 'n.n.' and $achnaov ne '-') {
        # achternaam overledene is gevuld en niet bepaalde waardes
        unless( $achvaov eq $achnaov ) {
            # achternaam overledene is niet gelijk aan die van de vader
            my $d = $alg->{'edit_distance'};
            # edit distance kleiner maken als het een korte naam betreft
            $d -= 1 if length $achnaov <= 4;
            if( length $achvaov and $achvaov ne '-' and lc $achvaov !~ $nnescio and  distance( $achnaov, $achvaov ) <= $d  ) {
                # REGEL 21: achternaam vader bevat geen vreemde waardes en ligt dicht bij die van de overledene
                &logErr('BS_G',"NAAM_MISMATCH",'PersonNameLastName', $fam{'Kind'}->{PersonName}->{PersonNameLastName}->{value}." <=> ".$fam{'Vader'}->{PersonName}->{PersonNameLastName}->{value},
                        "Naam vader en kind komen niet overeen, maar liggen dicht bijelkaar. Typefout?", $a2a, "PERSOON: ".&maakNaam($fam{'Kind'})." (Kind)");
            } elsif( $achmoov ne $achnaov ) {
            # achternaam ook niet gelijk aan die van de moeder
                if( length $achmoov and $achmoov ne '-' and lc $achmoov !~ $nnescio and distance( $achmoov, $achnaov ) <= $d) {
                    # REGEL 22: achternaam moeder is niet gelijk, maar ligt dicht bij de naam overledene
                    &logErr('BS_G',"NAAM_MISMATCH",'PersonNameLastName', $fam{'Kind'}->{PersonName}->{PersonNameLastName}->{value}." <=> ".$fam{'Moeder'}->{PersonName}->{PersonNameLastName}->{value},
                        "Naam moeder en kind komen niet overeen, maar liggen dicht bijeelkaar. Typefout?", $a2a, "PERSOON: ".&maakNaam($fam{'Kind'})." (Kind)");
                }
            }
        }
    }
    
    if( my $yr = $a2a->{Source}->{SourceDate}->{Year}->{value} ) {
        if( $yr < $bsg->{min_jaar} or $yr > $bsg->{max_jaar} ) {
            #REGEL 23: Het aktejaar ligt binnen een bandbreedte
            &logErr('BS_G',"DATUM_FOUT",'SourceDate', $yr,
                "Het aktejaar lijkt niet te kloppen", $a2a, "PERSOON: ".&maakNaam($fam{'Kind'})." (Kind)");
        }
        if( my $mnd = $a2a->{Source}->{SourceDate}->{Month}->{value} and my $dag = $a2a->{Source}->{SourceDate}->{Day}->{value} ) {
            unless( check_date($yr, $mnd, $dag) ) {
            #REGEL 24: de datum moet geldig zijn
                &logErr('BS_G',"DATUM_FOUT",'EventDate', $yr."-".$mnd."-".$dag,
                    "De aktedatum is ongeldig", $a2a, "PERSOON: ".&maakNaam($fam{'Kind'})." (Kind)");
            }
        }
    }
    my $remark;
    if( ref($a2a->{Source}->{SourceRemark}) eq 'ARRAY' ) {
        foreach my $rm (@{$a2a->{Source}->{SourceRemark}}) {
            if( $rm->{Key}->{value} eq 'AkteSoort' ) {
                $remark = $rm;
                last;
            }
        }
    } elsif( defined($a2a->{Source}->{SourceRemark}->{Key}->{value}) && $a2a->{Source}->{SourceRemark}->{Key}->{value} eq 'AkteSoort' ) {
        $remark = $a2a->{Source}->{SourceRemark};
    }
    if( defined $remark and $remark->{Value}->{value} eq $bsg->{'levenloos'} ) {
        # levenloos geboren
        if( defined $fam{'Relatie'} ) {
        # die heeft dan geen relaties
            #REGEL 25: Levenloos geboren personen hebben geen relaties
            &logErr('BS_G',"SOORT_FOUT",'SourceRemark', 'AkteSoort',
                    "Dit levenloos geboren persoon heeft een relatie. Klopt dit wel?", $a2a, "PERSOON: ".&maakNaam($fam{'Kind'})." (Kind)");
        }
    }
}
foreach my $p (sort keys %akten) {
    foreach my $y (sort keys %{$akten{$p}}) {
        my $counter = 0;
        foreach my $n (sort {$a <=> $b} keys %{$akten{$p}{$y}}) {
            # REGEL: numeriek verschil tussen opeenvolgende aktenummers is niet groter dan 1
            if( ($n-$counter) > 1 or ($n-$counter) < 1 ) {
                &logErr('BS_O',"AKNUM_FOUT",'DocumentNumber', $p."/".$y."/".$n." ==> ".$counter,
                "Verschil met vorige aktenummer meer dan 1. Ontbreekt er wat?", undef, "ALLE AKTEN");
            }
            $counter = $n;
        }
    }
}
warn $c." van ".$n." records gecontroleerd";
close(LOG);
