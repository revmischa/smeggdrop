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

use Shittybot::TCL;

my $s = Shittybot::TCL->new("./state-test");
$s->non_poe_start();
$s->{irc} = FakeIRC->new();
#my $res = $s->call("nick","mask","handle","channel","tcl proc . args {join $args}");
my $res = $s->call("nick","mask","handle","channel","proc . args {join \$args}");
print $res,$/;
#my $res = $s->call("nick","mask","handle","channel","tcl . .");
my $res = $s->call("nick","mask","handle","channel",". .");
print $res,$/;

