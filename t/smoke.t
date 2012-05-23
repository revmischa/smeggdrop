use strict;
use Test::More tests => 26;
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
use_ok('Digest::SHA1');

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
ok($tcl->can("safe_eval"),"Can safe_eval the TCL");

# look this smells bad
sub make_command {
    my $command = shift;
    my $cmd_ctx = Shittybot::Command::Context->new(
        nick => "frigga",
        mask => "*@*",
        channel => "#channel",
        command => $command,
        loglines => []
    );
    return $cmd_ctx;
}
# basic tcl
my $command = make_command("return what");
warn $tcl->safe_eval($command);
ok($tcl->safe_eval($command) eq "what","eval return what -- TCL");

# make a proc
my $dotproc = 'proc . args {lappend args; return [join ${args}]}';
$command = make_command($dotproc);
ok(defined($tcl->safe_eval($command)),"Make a Proc");

# call that proc -- test if it saved the proc
$command = make_command(". what");
ok($tcl->safe_eval($command) eq "what","test dot proc -- is the proc saved?");

my $procs = $tcl->safe_eval(make_command("info proc *"));
my $vars = $tcl->safe_eval(make_command("info var *"));
warn "VARS: $vars PROCS: $procs";
my @procs = split(/\s+/, $procs);
ok(scalar(grep { $_ eq '.' } @procs), "has dot defined?");


$command = make_command("string repeat XXXX 4000000000");
ok(!$tcl->safe_eval($command),"String repeat too much");

$command = make_command(". what");
ok($tcl->safe_eval($command) eq "what","Proc Persistentence after failure");

#this test makes sure that we don't lose our old procs
$command = make_command("proc toolong {} { set x 0; while {1} { incr x } }");
ok(!$tcl->safe_eval($command),"Set proc");
$command = make_command("toolong");
my $v = $tcl->safe_eval($command);
warn $v;
ok($v =~ /Error/,"proc runs too long");
$command = make_command(". what");
my $res = $tcl->safe_eval($command);
#warn $res;
ok($res eq "what","Proc Persistentence after failure");

# missing tests:
# * is context set?
