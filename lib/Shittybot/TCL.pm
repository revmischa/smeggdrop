#!/usr/bin/perl

package Shittybot::TCL;

#use POE   qw/Wheel::Run/;
use Data::Dump  qw/ddx/;
#use Shittybot::TCL::Child;

use Shittybot::TCL::ForkedTcl;

use Tcl;

use TclEscape;

sub spawn {
  my $class = shift;
  my $state = shift;
  my $irc   = shift;
  my $self  = {};

  $self->{state}  = $state;
  $self->{irc}    = $irc;

  bless ($self,$class);

  POE::Session->create(
    object_states => [
      $self => [qw/_start _tcl_in _tcl_out _tcl_chld/],
    ],
  );

  return $self;
}

sub _start {
  my $self  = $_[OBJECT];

  $self->{tcl}  = $self->load_state($self->{state});
}

sub _tcl_in {

}

sub _tcl_out {

}

sub _tcl_chld {

}


sub load_state {
  my $self      = shift;
  my $statepath = shift;
  my $tcl = $self->create_tcl($statepath);

  # dangerous call backs
  #$tcl->CreateCommand('chanlist',sub{join(' ',$self->{irc}->channel_list($_[3]))});
  return $tcl;
}

sub create_tcl {
  my ($self,$statepath) = @_;
  my $tcl = Tcl->new();
  $tcl->Init;
  #$tcl->Eval("proc putlog args {}");
  $tcl->CreateCommand('putlog',sub{ddx(@_)});
  $tcl->Eval("proc chanlist args { cache::get irc chanlist }");
  $tcl->Eval("set smeggdrop_state_path $statepath");
  $tcl->EvalFile('smeggdrop.tcl');
  $tcl = Shittybot::TCL::ForkedTcl->new( interp => $tcl );
  $tcl->Init();
  return $tcl;
}


sub call {
  my $self  = shift;
  my ($nick,$mask,$handle,$channel,$code) = @_;

  ddx(@_);
  ($nick,$mask,$handle,$channel,$code) = map { tcl_escape($_) } ($nick,$mask,$handle,$channel,$code);

  my $tcl = $self->{tcl};
  my @nicks = $self->{irc}->channel_list($channel);
  my @tcl_nicks = map { tcl_escape($_) } @nicks;
  my $chanlist = "{".join(' ',@tcl_nicks)."}";
  
  my $chancmd = "cache put irc chanlist $chanlist";
  $chancmd = "pub:tcl:perform {$nick} {$mask} {$handle} {$channel} {$chancmd}";
  return $tcl->Eval("$chancmd;\npub:tcl:perform {$nick} {$mask} {$handle} {$channel} {$code}");
}

#not sure about this
sub tcl_escape {
    return TclEscape::escape($_);
}





1;
