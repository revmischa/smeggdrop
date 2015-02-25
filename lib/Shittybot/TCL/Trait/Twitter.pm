package Shittybot::TCL::Trait::Twitter;

use Moose::Role;
use feature 'say';
use AnyEvent;
use AnyEvent::Twitter;

has 'twitter_client' => (
    is => 'ro',
    isa => 'AnyEvent::Twitter',
    builder => '_build_twitter_client',
);

has 'twitter_screen_name' => (
    is => 'rw',
    isa => 'Str',
);

has 'config' => (
    is => 'rw',
    isa => 'HashRef',
);

sub _build_twitter_client {
    my ($self) = @_;

    my $config = $self->config->{twitter}
        or die "Trying to use Twitter trait but twitter config is missing";
    
    my $client = AnyEvent::Twitter->new(%$config);

    $client->get('account/verify_credentials', sub {
	my ($header, $response, $reason) = @_;

	my $acct = $response->{screen_name};
	$self->twitter_screen_name($acct);
	print "Authenticated to twitter as $acct\n";
    });

    return $client;
}

after 'init_interp' => sub {
    my ($self) = @_;

    $self->export_procs_to_slave(twitter => {
	'post' => \&post_to_twitter,
    });

    say "Twitter trait initialized";
};

sub post_to_twitter {
    my ($self, @args) = @_;

    my $acct = $self->twitter_screen_name
	or return "Not authenticated to twitter";

    my $ctx = $self->context;
    my $nick = $ctx->nick;

    my $post = "@args";

    warn "$nick posting to twitter: '$post'\n";

    $self->twitter_client->post('statuses/update', {
	status => $post,
    }, sub {
	my ($header, $response, $reason) = @_; 

	$self->reply("Posting '@args' to \@$acct: $reason");
    });
    
    return;
}

1;
