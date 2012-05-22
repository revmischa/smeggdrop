package Shittybot::TCL::Trait::Twitter;

use Moose::Role;

use AnyEvent;
use AnyEvent::Twitter;

has 'twitter_client' => (
    is => 'ro',
    isa => 'AnyEvent::Twitter',
    builder => '_build_twitter_client',
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

after 'BUILD' => sub {
    my ($self) = @_;

    $self->export_to_tcl(
	namespace => 'twitter',
	subs => {
	    'post' => sub { $self->post_to_twitter(@_) },
	},
    );
};

sub post_to_twitter {
    my ($self, @args) = @_;

    my $ctx = $self->context;
    my $nick = $ctx->nick;

    my $post = "@args";

    warn "$nick posting to twitter: '$post'\n";

    $self->twitter_client->post('statuses/update', {
	status => $post,
    }, sub {
	my ($header, $response, $reason) = @_; 
	
	$self->reply("Posted to twitter: $reason");
    });
    
    return;
}

1;
