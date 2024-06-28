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
my $dir = dirname(__FILE__);

# gezamenlijke functies uit extern script laden
require $dir.'/include/a2a_utils.pl';
my( $in, $out);

my $cfg = new Config::Simple($dir.'/config/a2actl.ini');
my $bso = $cfg->get_block('BS_O');
our $alg = $cfg->get_block('ALGEMEEN');

my $vanaf = 0;
GetOptions( "vanaf:i" => \$vanaf );
die "Fout: Startjaar (parameter --vanaf) (".$vanaf.") is groter dan configuratieparameter max_jaar ".$bso->{'max_jaar'}
    if $vanaf > $bso->{'max_jaar'}; 

die "Gebruik: perl bso.pl <A2A-bestand> <LOG-bestand>\n" 
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

my %akten;
my $n = 0;
my $c = 0;
our $err = 0;

while ($reader->nextElement("A2A", "http://Mindbus.nl/A2A")) {
    $logs->write_row(0, 0, ["Soort","Meldcode","Melding","Gemeente","Jaar","Aktenr","Veld","Waarde","Context","Link","GUID","Scans"])
        if $n==0;
    $n++;
    my $xml = $reader->readOuterXml();
    $xml =~ s/a2a://g;
    #
    # bestand parsen: telkens een metadata-fragment verwerken en dan in een Perl hash inlezen
    #
    my $ref = XML::Bare->new(text => $xml);
    my $root = $ref->parse();
    my $a2a = $root->{A2A};

    next unless $a2a->{Source}->{SourceType}->{value} eq 'BS Overlijden';
    my $nnescio = qr/$alg->{'regex_nn'}/i;

    no warnings 'numeric';
    my $jaar = $a2a->{Source}->{SourceDate}->{Year}->{value}||0;
    next unless $jaar >= $vanaf;
    $c++;
    use warnings 'numeric';

    # REGEL: het aktenummer mag niet leeg zijn
    if( my $docnr = $a2a->{'Source'}->{SourceReference}->{DocumentNumber}->{value} ) {
        my $re = qr/$bso->{'regex_aknr'}/;
        if( $docnr eq '') {
            $logs->write_row($err, 0, &logErr('BS_O','AKTENUMMER_LEEG','DocumentNumber', "", 
                "Het aktenummer is leeg", $a2a, "AKTE"));
        } elsif( $docnr !~  $re ) {
        # REGEL : het aktenummer bestaat alleen uit getallen gevolgd door een kleine letter of een hoofdletter S (van supplement)
            $logs->write_row($err, 0, &logErr('BS_O','AKTENUMMER_ONBEKEND','DocumentNumber', $docnr, 
                "Het aktenummer lijkt onbekende tekens te bevatten", $a2a, "AKTE"));
        }
    } else {
        # herhaling van controle, omdat de XML-structuur helemaal niet bestaat
        $logs->write_row($err, 0, &logErr('BS_O','AKTENUMMER_LEEG','DocumentNumber', "", 
                "Het aktenummer is leeg", $a2a, "AKTE"));
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
        # REGEL : een akte bevat personen 
        $logs->write_row($err, 0, &logErr('BS_O','GEEN_PERSONEN','','',"Deze akte bevat geen personen", $a2a, "AKTE"));
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
    foreach my $p (@{$persons}) {
        my $rol = $relmap{$p->{pid}->{value}};
        unless($rol) {
            # REGEL : elke persoon heeft een rol
            $logs->write_row($err, 0, &logErr('BS_O',"GEEN_ROL","RelationType", "", 
            "De persoon heeft geen rol", $a2a, "PERSOON: ".&maakNaam($p)." (LEEG)"));
        }
        if( $rol eq 'Relatie' ) {
            push(@{$fam{$rol}},$p);
        } elsif( defined($fam{$rol}) ) {
            # REGEL : Alle rollen behalve Relatie zijn uniek
            $logs->write_row($err, 0, &logErr('BS_O',"DUBBELE_ROL","RelationType", $rol, 
            "De rol komt meer dan 1x voor", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")"));
        } else{
            $fam{$rol} = $p;
        }
        if( not(length($p->{PersonName}->{PersonNameLastName}->{value})) 
                and not(length($p->{PersonName}->{PersonNamePatronym}->{value})) ) {
            # REGEL : achternaam en patroniem zijn niet allebei leeg
            $logs->write_row($err, 0, &logErr('BS_O',"NAAMDEEL_LEEG",'PatroniemOfAchternaam', "", 
            "De achternaam en het patroniem zijn beide leeg", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")"));
        } elsif( not(length($p->{PersonName}->{PersonNameFirstName}->{value})) and lc $p->{PersonName}->{PersonNameLastName}->{value} !~ $nnescio) {
            # REGEL : voornaam is niet leeg 
            $logs->write_row($err, 0, &logErr('BS_O',"NAAMDEEL_LEEG",'Voornaam', "", 
                "De voornaam is leeg", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")"));
        }
        # algemene checks op naamdelen 
        my $re_tv = qr/^($alg->{'regex_tvoeg'}(\s+$alg->{'regex_tvoeg'})*)$/;
        my $re_nd = qr/^($alg->{'regex_naamdeel'}(\s+($alg->{'regex_naamdeel'}|$alg->{'regex_tvoeg'}))*)$/;
        foreach my $w (qw/PersonNameLastName PersonNameFirstName PersonNamePatronym/) {
            if( defined $p->{PersonName}->{$w}->{value} ) {
                if( lc $p->{PersonName}->{$w}->{value} !~ $nnescio and $p->{PersonName}->{$w}->{value} ne "-") {
                        unless(  $p->{PersonName}->{$w}->{value} =~ $re_nd ) {
                        # REGEL : een naamdeel voldoet aan een vast stramien
                            $logs->write_row($err, 0, &logErr('BS_O',"WAARDE_VERDACHT",$w, $p->{PersonName}->{$w}->{value}, 
                                "De achter- of voornaam lijkt onbekende tekens te bevatten", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")"));
                        }
                }
                if( length $p->{PersonName}->{$w}->{value} && $p->{PersonName}->{$w}->{value} =~ qr/[aeiou]{$alg->{'max_klinkers'},}/ ) {
                    # REGEL : een naamdeel bevat niet meer dan een configurabel aantal klinkers achtereen
                    $logs->write_row($err, 0, &logErr('BS_O',"KLINKERS", $w,$p->{PersonName}->{$w}->{value},
                    "Het naamdeel bevat ".$alg->{'max_klinkers'}." of meer klinkers", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")"));
                }
                if( length $p->{PersonName}->{$w}->{value} && $p->{PersonName}->{$w}->{value} =~ qr/[bcdfghklmnpqrstvwx]{$alg->{'max_medeklinkers'},}/ ) {
                    # REGEL : een naamdeel bevat niet een configurabel aantal of meer medeklinkers 
                    $logs->write_row($err, 0, &logErr('BS_O',"MEDEKLINKERS", $w,$p->{PersonName}->{$w}->{value},
                    "Het naamdeel bevat 6 of meer medeklinkers", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")"));
                }
                if( length $p->{PersonName}->{$w}->{value} && $p->{PersonName}->{$w}->{value} =~ /([^\.])\1\1/ ) {
                    # REGEL : een naamdeel bevat nooit 3x hetzelfde teken achtereen
                    $logs->write_row($err, 0, &logErr('BS_O',"HERHALING", $w,$p->{PersonName}->{$w}->{value},
                    "Het naamdeel bevat 3x hetzelfde teken", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")"));
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
                        # REGEL : de naam van een vrouw eindigt niet op een mannelijke uitgang
                        $logs->write_row($err, 0, &logErr('BS_O',"GESLACHT_FOUT", "PersonNameFirstName", $temp[0],
                        "Op basis van de naam zou dit een man kunnen zijn ipv een vrouw", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")"));
                    } elsif( ($bla2 eq 'a' or $bla3 =~ /([bdfgknps]je|.th)/) and $p->{Gender}->{value} eq "Man" and !grep { $temp[0] eq $_ } @{$alg->{mannen}}) {
                        # REGEL :  de naam van een man eindigt niet op een vrouwelijke uitgang
                        $logs->write_row($err, 0, &logErr('BS_O',"GESLACHT_FOUT", "PersonNameFirstName", $temp[0],
                        "Op basis van de naam zou dit een vrouw kunnen zijn ipv een man", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")"));
                    } elsif( ($bla3 =~ /(ien|[wnfb]ke)/ and !grep { $temp[0] eq $_} @{$alg->{mannen}} ) and $p->{Gender}->{value} eq "Man" ) {
                        # REGEL :  de naam van een man eindigt niet op een vrouwelijke uitgang
                        $logs->write_row($err, 0, &logErr('BS_O',"GESLACHT_FOUT", "PersonNameFirstName", $temp[0],
                        "Op basis van de naam zou dit een vrouw kunnen zijn ipv een man", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")"));
                    }
                }
            }
        }
        if( $p->{PersonName}->{PersonNamePrefixLastName}->{value} ) {
            unless( $p->{PersonName}->{PersonNamePrefixLastName}->{value} =~ $re_tv ) {
                # REGEL : tussenvoegsel bestaat uit een vast aantal woorden geschreven met kleine letters
                $logs->write_row($err, 0, &logErr('BS_O',"WAARDE_VERDACHT",'PersonNamePrefixLastName', $p->{PersonName}->{PersonNamePrefixLastName}->{value}, 
                "Het tussenvoegsel lijkt onbekende tekens te bevatten", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")"));
            }
            if( $p->{PersonName}->{PersonNamePrefixLastName}->{value} =~ /(.)\1\1/ ) {
                #REGEL : tussenvoegsel bevat nooit 3x hetzelfde teken achtereen
                $logs->write_row($err, 0, &logErr('BS_O',"WAARDE_VERDACHT",'PersonNamePrefixLastName', $p->{PersonName}->{PersonNamePrefixLastName}->{value}, 
                "Het tussenvoegsel bevat 3x hetzelfde teken", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")"));
            }
        }
        if( $p->{PersonName}->{PersonNamePatronym}->{value} ) {
            my $re_pn = qr($alg->{'regex_patroniem'});
            unless( $p->{PersonName}->{PersonNamePatronym}->{value} =~ $re_pn ) {
                # REGEL : Een patroniem heeft een vast stramien: eindigt op s, zoon of zn
                $logs->write_row($err, 0, &logErr('BS_O',"WAARDE_VERDACHT",'PersonNamePatronym', $p->{PersonName}->{PersonNamePatronym}->{value}, 
                "Het patroniem voldoet niet aan het stramien", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")"));
            }
        }
        if( my $prof = $p->{Profession}->{value} ) {
            unless( $prof eq "" or $prof =~ /^([\p{Ll}\p{Lu}0-9\'\-\(\)\.\/ ,]|&amp;)+$/ ) {
                #REGEL : beroep bestaat uit een vast stramien
                $logs->write_row($err, 0, &logErr('BS_O',"WAARDE_VERDACHT",'Profession', $prof, 
                    "Het beroep lijkt onbekende tekens te bevatten", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")"));
            } #elsif( $prof =~ /\.$/ ) {
            #  $logs->write_row($err, 0, &logErr('BS_O',"WAARDE_AFGEKAPT",'Profession', $prof, 
            #        "Het beroep is misschien afgekapt op een vaste lengte", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")");
            #}
        }
        if( my $pal = $p->{Age}->{PersonAgeLiteral}->{value} ) {
            #REGEL : een leeftijdsaanduiding kan niet 1 jaren of 1 maanden zijn
            $logs->write_row($err, 0, &logErr('BS_O',"1_DAGEN",'PersonAgeLiteral', $pal, 
                "1 dagen/maanden moet 1 dag/maand zijn", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")")) 
                if( $pal eq '1 dagen' or $pal eq '1 maanden' );
        }
        if( my $bplace = $p->{BirthPlace}->{Place}->{value} ) {
            unless( $bplace =~ /^([\p{Ll}\p{Lu}\'\-\., \(\)\/\[\]]|&amp;)+$/ ) {
                #REGEL : een geboorteplaats bevat bepaalde tekens
                $logs->write_row($err, 0, &logErr('BS_O',"WAARDE_VERDACHT",'BirthPlace', $bplace, 
                    "De geboorteplaats lijkt onbekende tekens te bevatten", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")"));
            }
            if( $bplace =~ /(.)\1\1/ ) {
                # REGEL: een geboorteplaats bevat niet 3x hetzelfde teken
                $logs->write_row($err, 0, &logErr('BS_O',"HERHALING",'BirthPlace', $bplace, 
                    "De geboorteplaats bevat 3x hetzelfde teken", $a2a, "PERSOON: ".&maakNaam($p)." (".$rol.")"));
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
    my $achnaov = $fam{'Overledene'}->{PersonName}->{PersonNameLastName}->{value}||"";
    if( length $achnaov and lc $achnaov !~ $nnescio and $achnaov ne '-') {
        # achternaam overledene is gevuld en niet met NN of streepje
        unless( $achvaov eq $achnaov ) {
            # achternaam overledene is niet gelijk aan die van de vader
            my $d = $alg->{'edit_distance'};
            # edit distance kleiner maken als het een korte naam betreft
            $d -= 1 if length $achnaov <= 4;
            if( length $achvaov and $achvaov ne '-' and lc $achvaov !~ $nnescio and  distance( $achnaov, $achvaov ) < $d  ) {
                # REGEL: achternaam vader bevat geen vreemde waardes en ligt dicht bij die van de overledene
                $logs->write_row($err, 0, &logErr('BS_O',"NAAM_MISMATCH",'PersonNameLastName', $fam{'Overledene'}->{PersonName}->{PersonNameLastName}->{value}." <=> ".$fam{'Vader'}->{PersonName}->{PersonNameLastName}->{value},
                        "Naam vader en overledene komen niet overeen, maar liggen dicht bijelkaar. Typefout?", $a2a, "PERSOON: ".&maakNaam($fam{'Overledene'})." (Overledene)"));
            } elsif( $achmoov ne $achnaov ) {
            # achternaam ook niet gelijk aan die van de moeder
                if( length $achmoov and $achmoov ne '-' and lc $achmoov !~ $nnescio and distance( $achmoov, $achnaov ) < $d) {
                    # REGEL: achternaam is niet gelijk, maar ligt dicht bij de naam overledene
                    $logs->write_row($err, 0, &logErr('BS_O',"NAAM_MISMATCH",'PersonNameLastName', $fam{'Overledene'}->{PersonName}->{PersonNameLastName}->{value}." <=> ".$fam{'Moeder'}->{PersonName}->{PersonNameLastName}->{value},
                        "Naam moeder en overledene komen niet overeen, maar liggen dicht bijeelkaar. Typefout?", $a2a, "PERSOON: ".&maakNaam($fam{'Overledene'})." (Overledene)"));
                }
            }
        }
    }
    if( my $yr = $a2a->{Source}->{SourceDate}->{Year}->{value} ) {
        if( $yr < $bso->{min_jaar} or $yr > $bso->{max_jaar} ) {
            # REGEL: Het aktejaar ligt binnen een configurabele bandbreedte
            $logs->write_row($err, 0, &logErr('BS_O',"DATUM_FOUT",'EventDate', $yr,
                "Het akteJjar lijkt niet te kloppen", $a2a, "PERSOON: ".&maakNaam($fam{'Overledene'})." (Overledene)"));
        }
        if( my $mnd = $a2a->{Source}->{SourceDate}->{Month}->{value} and my $dag = $a2a->{Source}->{SourceDate}->{Day}->{value} ) {
            unless( check_date($yr, $mnd, $dag) ) {
                # REGEL: de aktedatum is geldig
                $logs->write_row($err, 0, &logErr('BS_O',"DATUM_FOUT",'EventDate', $yr."-".$mnd."-".$dag,
                    "Datum ongeldig", $a2a, "PERSOON: ".&maakNaam($fam{'Overledene'})." (Overledene)"));

            }
        }
    }
    if( defined $fam{'Overledene'}->{Age}->{PersonAgeLiteral}->{value} && $fam{'Overledene'}->{Age}->{PersonAgeLiteral}->{value} =~ /^(\d)+\s+(jaar|jaren).*/ ) {
        my $age = int($1);
        if( $age < $bso->{'min_leeftijd'} or $age > $bso->{'max_leeftijd'} ) {
            # REGEL: leeftijd overledene ligt tussen configurabele bandbreedte
            $logs->write_row($err, 0, &logErr('BS_O',"LEEFTIJD_FOUT",'PersonAgeLiteral', $age,
                    "Opvallende leeftijd", $a2a, "PERSOON: ".&maakNaam($fam{'Overledene'})." (Overledene)"));
        }
    }
    my $remark;
    if( defined $a2a->{Source}->{SourceRemark} ) {
        if( ref($a2a->{Source}->{SourceRemark}) eq 'ARRAY' ) {
            foreach my $rm (@{$a2a->{Source}->{SourceRemark}}) {
                if( $rm->{Key}->{value} eq 'AkteSoort' ) {
                    $remark = $rm;
                    last;
                }
            }
        } elsif( $a2a->{Source}->{SourceRemark}->{Key}->{value} eq 'AkteSoort' ) {
            $remark = $a2a->{Source}->{SourceRemark};
        }
    }
    if( defined $remark and $remark->{Value}->{value} eq 'levenloos' ) {
        # levenloos geboren
        if( defined $fam{'Relatie'} ) {
        #   REGEL : een levenloos geboren persoon heeft geen relatie
            $logs->write_row($err, 0, &logErr('BS_O',"SOORT_FOUT",'SourceRemark', 'AkteSoort',
                    "Dit levenloos geboren persoon heeft een relatie. Klopt dit wel?", $a2a, 
                    "PERSOON: ".&maakNaam($fam{'Overledene'})." (Overledene)"));
        }
    }
}
foreach my $p (sort keys %akten) {
    foreach my $y (sort keys %{$akten{$p}}) {
        my $counter = 0;
        foreach my $n (sort {$a <=> $b} keys %{$akten{$p}{$y}}) {
            # REGEL: numeriek verschil tussen opeenvolgende aktenummers is niet groter dan 1
            if( ($n-$counter) > 1 or ($n-$counter) < 1 ) {
                $logs->write_row($err, 0, &logErr('BS_O',"AKNUM_FOUT",'DocumentNumber', $p."/".$y."/".$n." ==> ".$counter,
            "Verschil met vorige aktenummer groter dan 1. Ontbreekt er een akte?", undef, "ALLE AKTEN"));
            }
            $counter = $n;
        }
    }
}
warn $c." van ".$n." records gecontroleerd";
$xlsx->close();
