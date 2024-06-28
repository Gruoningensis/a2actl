#!/usr/bin/perl
use Text::Iconv;
my $iconv = Text::Iconv->new("utf-8","windows-1252");

sub logErr() {
  my($TPE, $ERR, $FLD, $VAL, $DSC, $REF, $CTX) = @_;
  my $guid = $REF->{Source}->{RecordGUID}->{value};
  $guid =~ s/[{}]//g;
  my $url = "'".$REF->{Source}->{SourceDigitalOriginal}->{value} || "Geen specifieke link";
  #$url =~ s/^https?//g;
  $err++;
  #die Dumper($REF->{Source});
  return [ $TPE, $ERR, $DSC, $REF->{Source}->{SourcePlace}->{Place}->{value}||"[LEEG]",
    $REF->{Source}->{SourceDate}->{Year}->{value}||"[LEEG]", $REF->{Source}->{SourceReference}->{DocumentNumber}->{value}||"[LEEG]",
    $FLD, $iconv->convert($VAL)||"[LEEG]", $iconv->convert($CTX), $url,
    $guid, (defined $REF->{Source}->{SourceAvailableScans} ? "Scans aanwezig": "Geen scans aanwezig") ];
}

sub maakNaam($) {
  my $p = shift;
  my $text="";
  map { 
    if( length $_ ) {
      $text.=" " if length $text;
      $text.=$_;
    }
  } $p->{PersonName}->{PersonNameFirstName}->{value}||"", 
    $p->{PersonName}->{PersonNamePatronym}->{value}||"", $
    p->{PersonName}->{PersonNamePrefixLastName}->{value}||"",
    $p->{PersonName}->{PersonNameLastName}->{value}||"";
  return $text;
}
1;
