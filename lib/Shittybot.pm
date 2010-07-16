# overload the IRC::Client connect method to let us define a prebinding callback
package Shittybot;

use Moose;
extends 'AnyEvent::IRC::Client';

use AnyEvent::IRC::Connection;

# hash of channel => \@logs
has 'logs' => (
    is => 'rw',
    isa => 'HashRef',
    lazy => 1,
    default => sub { {} },
);

sub connect {
    my ($self, $host, $port, $info, $pre) = @_;

    if (defined $info) {
	$self->{register_cb_guard} = $self->reg_cb (
	    ext_before_connect => sub {
		my ($self, $err) = @_;

		unless ($err) {
              $self->register(
		  $info->{nick}, $info->{user}, $info->{real}, $info->{password}
		  );
		}

		delete $self->{register_cb_guard};
	    }
	    );
    }

    AnyEvent::IRC::Connection::connect($self, $host, $port, $pre);
}


# log channel chat lines 
sub append_chat_line {
    my ($self, $channel, $line) = @_;
    my $log = $self->logs->{$channel} || [];
    push @$log, $line;
    $self->logs->{$channel} = $log;
    return $log;
}

# retrieve channel log chat lines (as an array ref)
sub get_chat_lines {
    my ( $self, $channel ) = @_;
    my $log = $self->logs->{$channel} || [];
    return $log;
}

# clear channel chat lines
# mutation
sub clear_chat_lines {
    my ($self, $channel) = @_;
    $self->logs->{$channel} = [];
}
# retrieve and clear channel chat lines (as an array ref)
# mutation
sub slurp_chat_lines {
    my ($self, $channel) = @_;
    my $log = $self->get_chat_lines( $channel );
    $self->clear_chat_lines( $channel );
    return $log;
}
# This is a data structure that is a chat long message
sub log_line {
    my ($self, $nick, $mask, $message) = @_;
    return [ time(), $nick, $mask, $message ];
}

__PACKAGE__->meta->make_immutable(inline_constructor => 0);
