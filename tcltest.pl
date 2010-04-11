#!/usr/bin/perl
use strict;
use Tcl;
use lib 'lib';
use Shittybot::TCL;
use FakeIRC;


my $tcl = Tcl->new();
$tcl->Init();
print $tcl->Eval("proc putlog args {}"),$/;
print $tcl->EvalFile("smeggdrop.tcl"),$/;
print $tcl->Eval("return w"),$/;
print $tcl->Eval("pub:tcl:perform nick mask handle channel  {return what}"),$/;
print $tcl->Eval("pub:tcl:perform nick mask handle channel  {http get http://localhost}"),$/;
print $tcl->Eval("pub:tcl:perform nick mask handle channel  {http post http://localhost a b}"),$/;

print $tcl->Eval("pub:tcl:perform nick mask handle channel  {http post http://localhost [list]}"),$/;
print $tcl->Eval("pub:tcl:perform nick mask handle channel  {http post http://localhost [list a b]}"),$/;
print "Now test head$/";
print $tcl->Eval("pub:tcl:perform nick mask handle channel  {http head http://localhost}"),$/;



use Shittybot::TCL;

my $s = Shittybot::TCL->new("./state-test");
$s->non_poe_start();
$s->{irc} = FakeIRC->new();
#my $res = $s->call("nick","mask","handle","channel","tcl proc . args {join $args}");
my $res = $s->call("nick","mask","handle","channel","proc . args {join \$args}");
#my $res = $s->call("nick","mask","handle","channel","tcl . .");
my $res = $s->call("nick","mask","handle","channel",". .");
die "[$res] not eq to ." unless $res eq ".";
my @names = $s->{irc}->channel_list;
my %names = ();
$names{$_}++ foreach @names;
my $res = $s->call("nick","mask","handle","channel","names");
my @newnames = split(/\s+/, $res);
foreach my $name (@newnames) {
    die "[$name] not found! [$res]" unless $names{$name};
}
