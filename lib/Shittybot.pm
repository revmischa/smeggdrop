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

has 'config' => (
    is => 'ro',
    isa => 'HashRef',
    required => 1,
);

has 'network_config' => (
    is => 'ro',
    isa => 'HashRef',
    required => 1,
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

sub send_to_channel {
    my ($self, $chan, $msg) = @_;

    return unless $msg;
    utf8::encode($msg);

    $msg =~ s/\001ACTION /\0777ACTION /g;
    $msg =~ s/[\000-\001]/ /g;
    $msg =~ s/\0777ACTION /\001ACTION /g;

    my @lines = split  "\n" => $msg;
    my $limit = $self->network_config->{linelimit} || 20;

    # split lines if they are too long
    @lines = map { chunkby($_, 420) } @lines;

    if (@lines > $limit) {
	my $n = @lines;
	@lines = @lines[0..($limit-1)];
	push @lines, "error: output truncated to ".($limit - 1)." of $n lines total"
    }

    foreach my $line (@lines) {
	$self->send_chan($chan, 'PRIVMSG', $chan, $line);
    }
}

sub chunkby {
    my ($a,$len) = @_;
    my @out = ();
    while (length($a) > $len) {
	push @out,substr($a, 0, $len);
	$a = substr($a,$len);
    }
    push @out, $a if (defined $a);
    return @out;
}

__PACKAGE__->meta->make_immutable(inline_constructor => 0);
