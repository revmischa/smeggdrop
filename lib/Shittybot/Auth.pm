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

has 'ignorelist' => (is => 'rw', isa => 'ArrayRef', default => sub { [] });


sub Command {
  my ($self, $from, $data) = @_;
  my ($command, @args) = split ' ' => $data;
  if($command eq "auth") {
    # todo: auth with sql tables, multiple accs, etc
    if ($args[0] eq $self->ownernick &&
	$args[1] eq $self->ownerpass) {
      $self->{sessions}->{prefix_nick($from)} = Shittybot::Auth::Session->new(accountname => $args[0], host => $from);
      $self->{sessions}->{prefix_nick($from)}->{timer} = AnyEvent->timer(
							       after => $self->sessionttl,
							       cb => sub {
								 #ddx "In timer";
								 delete $self->{sessions}->{$args[0]};
							       }
							      );
      return ('PRIVMSG', prefix_nick($from), "good job");
    } else {
      return ('PRIVMSG', prefix_nick($from), "not authorised");
    }
  } else {
    return ('PRIVMSG', prefix_nick($from), "log in first")   unless (defined $self->{sessions}->{prefix_nick($from)});
    return ('PRIVMSG', prefix_nick($from), "not authorised") unless ($self->{sessions}->{prefix_nick($from)}->host eq $from);
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
}

sub parse_command {
  my ($self, $from, $data) = @_;
  my ($command, @args) = split ' ' => $data;
  given($command) {
    when("dump") {
      ddx $self->ignorelist;
      return;
    }
    when("ping") {
      return ("msg", "ping");
    }
    when("kick") {
      return ("KICK", @args);
    }
    when("ignore") { 
      given($args[0]) {
	when("add") { # ban people from using the bot
	  #$args[1] =~ s/\./\\\./;
	  #$args[1] =~ s///;
	  push @{ $self->ignorelist }, $args[1];
	  return ("msg", "$args[1] added to ignore list");
	}
	when("list") {
	  return ("msg", join " ", @{ $self->ignorelist });
	}
	when("remove") { # unignore
	  delete $self->ignorelist->[grep {$self->ignorelist->[$_] eq $args[1]} 0..$#{$self->ignorelist}];
	  @{$self->ignorelist} = grep { defined $_ } @{$self->ignorelist};
	}
      }
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
