#!/usr/bin/perl
package Shittybot::TCL;

use strict;

#use POE   qw/Wheel::Run/;
use Data::Dump  qw/ddx/;
use Data::Dumper qw(Dumper);
#use Shittybot::TCL::Child;

use Shittybot::TCL::ForkedTcl;

use Tcl;

use TclEscape;
use POE;

#this is for testing and making a new object without POE
sub new {
  my $class = shift;
  my $state = shift; #statepath!
  my $irc   = shift;

  my $self = {};

  $self->{state}  = $state;
  $self->{irc}    = $irc;

  bless ($self,$class); # this is bad
  return $self;
}

sub spawn {
  my $class = shift;
  my $state = shift;
  my $irc   = shift;
  my $self  = $class->new($state, $irc);

  POE::Session->create(
    object_states => [
      $self => [qw/_start _tcl_in _tcl_out _tcl_chld/],
    ],
  );

  return $self;
}

sub _start {
  my $self  = $_[OBJECT];
  $self->non_poe_start();
  
}

sub non_poe_start {
    my $self = shift;
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
  my $ochannel = $channel;
  ddx(@_);
  ($nick,$mask,$handle,$channel,$code) = map { tcl_escape($_) } ($nick,$mask,$handle,$channel,$code);

  my $tcl = $self->{tcl};
  my @nicks = $self->{irc}->channel_list($ochannel);
  ddx(ref($self->{irc}));
  ddx($self->{irc}->channels);
  my @tcl_nicks = map { tcl_escape($_) } @nicks;
  ddx("$ochannel: @nicks , @tcl_nicks");
  my $chanlist = "[list ".join(' ',@tcl_nicks)."]";
  ddx($chanlist);

  # update the chanlist
  my $update_chanlist = tcl_escape("cache put irc chanlist $chanlist");
  my $chancmd = "pub:tcl:perform $nick $mask $handle $channel $update_chanlist";
  # perform the actual command
  return $tcl->Eval("$chancmd;\npub:tcl:perform $nick $mask $handle $channel $code");
}

#not sure about this
sub tcl_escape {
    return TclEscape::escape($_[0]);
}





1;
