package Shittybot::TCL::Trait::Twitter;

use Moose::Role;

use AnyEvent::Twitter;

has 'twitter_client' => (
    is => 'ro',
    isa => 'AnyEvent::Twitter',
    lazy_build => 1,
);

sub _build_twitter_client {
    my ($self) = @_;

    my $config = $self->irc->config->{twitter}
        or die "Trying to use Twitter trait but twitter config is missing";
    
    my $client = AnyEvent::Twitter->new(%$config);

    $client->get('account/verify_credentials', sub {
	my ($header, $response, $reason) = @_;
 
	print "Authenticated to twitter as $response->{screen_name}\n";
    });

    return $client;
}

sub BUILD{}; after 'BUILD' => sub {
    my ($self) = @_;

    $self->register_callbacks(
	post_twat => \&post_to_twitter,
    );
};

sub post_to_twitter {
    my ($self, $nick, $mask, $handle, $channel, $proc, $args, $loglines) = @_;

    my $twit = $self->twitter_client;

    warn "$nick posting to twitter: '$args'\n";

    $twit->post('statuses/update', {
	status => $args,
    }, sub {
	my ($header, $response, $reason) = @_; 
	$self->irc->send_to_channel($channel, "posted to twitter: $response/$reason");
    });
}

1;
