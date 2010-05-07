package Shittybot::Auth;
use Moose;
use 5.01;
use Data::Dump  qw/ddx/;

has ownernick => (is => 'rw', isa => 'Str');
has ownerpass => (is => 'rw', isa => 'Str');
has sessionttl => (is => 'rw', isa => 'Int');

has from => (is => 'rw', isa => 'Str');

sub Command {
  my ($self, $data) = @_;
  return "err" unless defined $self->from;
  my ($command, @args) = split ' ' => $data;
  given($command) {
    when("auth") {
      if ($args[0] eq $self->ownernick &&
	  $args[1] eq $self->ownerpass) {
	return "good job";
      } else {
	return "error, not authorised";
      }
    }
  }
  $self->from = undef;
}


1;

package Shittybot::Auth::Session;
use Moose;


1;
