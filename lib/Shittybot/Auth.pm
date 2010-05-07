package Shittybot::Auth;
use 5.01;
use strict;
use warnings;
use Moose;
use AnyEvent;
use AnyEvent::IRC::Util qw/prefix_nick prefix_user prefix_host/;
use Data::Dump  qw/ddx/;


has ownernick => (is => 'rw', isa => 'Str');
has ownerpass => (is => 'rw', isa => 'Str');
has sessionttl => (is => 'rw', isa => 'Int');
#has from => (is => 'rw', isa => 'Str');

sub Command {
  my ($self, $from, $data) = @_;
  my @out = $self->parse_command($from, $data);
  given ($out[0]) {
    when("msg") { # send PRIVMSG
      return ("PRIVMSG", prefix_nick($from), $out[1]);
    }
    default {
      return @out;
    }
  }
}

sub parse_command {
  my ($self, $from, $data) = @_;
  my ($command, @args) = split ' ' => $data;
  given($command) {
    when("auth") {
      # todo: auth with sql tables, multiple accs, etc
      if ($args[0] eq $self->ownernick &&
	  $args[1] eq $self->ownerpass) {
	$self->{sessions}->{$args[0]} = Shittybot::Auth::Session->new(accountname => $args[0], host => $from);
	$self->{sessions}->{$args[0]}->{timer} = AnyEvent->timer(
		  after => $self->sessionttl,
		  cb => sub {
		    #ddx "In timer";
		    delete $self->{sessions}->{$args[0]};
		  }
            );
	return ("msg", "good job");
      } else {
	return ("msg", "error, not authorised");
      }
    }
    when("dump") {
      ddx $self->{sessions};
      return;
    }
  }
#  $self->from = undef;
}


1;

package Shittybot::Auth::Session;
use Moose;
has accountname => (is => 'rw', isa => 'Str');
has host => (is => 'rw', isa => 'Str');

# TODO:
#   CODE MORE

1;
