package Shittybot::Auth;
use Moose;
use Data::Dump  qw/ddx/;

has ownernick => (is => 'rw', isa => 'Str');
has ownerpass => (is => 'rw', isa => 'Str');
has sessionttl => (is => 'rw', isa => 'Int');

sub Command {
  my ($self, $data) = @_;
  my ($command, @args) = split ' ' => $data;
  ddx($command);
  ddx(@args);
}

1;

package Shittybot::Auth::Session;
use Moose;


1;
