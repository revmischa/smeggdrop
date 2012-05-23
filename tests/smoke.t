use strict;
use Test::More tests => 19;
use_ok('Data::Dumper');
use_ok('AnyEvent::IRC::Connection');
use_ok('AnyEvent::IRC::Client');
use_ok('AnyEvent::IRC::Util');
use_ok('AnyEvent::Socket');
use_ok('Shittybot::Auth');
use_ok('Data::Dump');
use_ok('Moose');
use_ok('Shittybot');
use_ok('Shittybot::TCL');
use_ok('TclEscape');

use TclEscape;
TclEscape::escape_test();
ok(!$@,"Escape Test");

#fake irc?
use_ok('FakeIRC');
my $irc = FakeIRC->new();
ok(defined($irc), "IRC Made");

#make a shittybot
my $shittybot = Shittybot->new(config=>{state_directory=>"./state"},network_config=>{channels=>["#channels"]});
ok($shittybot->isa("Shittybot"),"Shittybot");


# try some tcl stuff out
my $tcl = $shittybot->tcl();
ok($tcl->can("call"),"Can Call the TCL");
ok($tcl->call("frigga",'*@*',"handle","#channel","return what","") eq "what","Return TCL");
my $dotproc = 'proc . args {lappend args; return [join ${args}]}';
ok(defined($tcl->call("frigga",'*@*',"handle","#channel",$dotproc,"")),"Proc");
ok($tcl->call("frigga",'*@*',"handle","#channel",". what") eq "what","test proc");

