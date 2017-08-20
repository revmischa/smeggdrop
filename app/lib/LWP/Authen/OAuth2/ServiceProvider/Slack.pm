package LWP::Authen::OAuth2::ServiceProvider::Slack;

use strict;
use warnings;

use Carp qw(croak);
use JSON qw(decode_json);
use Memoize qw(memoize);
use Module::Load qw(load);
use URI;

our @ISA = qw(LWP::Authen::OAuth2::ServiceProvider);

sub authorization_endpoint {
    return "https://slack.com/oauth/authorize";
}

sub token_endpoint {
    return "https://slack.com/api/oauth.access";
}

sub authorization_required_params {
    my $self = shift;
    return ("client_id", "redirect_uri", "scope", "response_type", $self->SUPER::authorization_required_params());
}

sub authorization_optional_params {
    my $self = shift;
    return ("approval_prompt", "state", $self->SUPER::authorization_optional_params());
}

sub request_default_params {
    my $self = shift;
    return (
        
        "response_type" => "code",
        $self->SUPER::request_default_params()
    );
}


# assume token type

# Attempts to construct tokens, returns the access_token (which may have a
# request token embedded).
sub construct_tokens {
    my ($self, $oauth2, $response) = @_;

    # The information that I need.
    my $content = eval {$response->decoded_content};
    if (not defined($content)) {
        $content = '';
    }
    my $data = eval {decode_json($content)};
    my $parse_error = $@;
    my $token_endpoint = $self->token_endpoint();

    # HACK TO FIX SLACK
    $data->{token_type} = 'bearer';

    # Can this have done wrong?  Let me list the ways...
    if ($parse_error) {
        # "Should not happen", hopefully just network.
        # Tell the programmer everything.
        my $status = $response->status_line;
        return <<"EOT"
Token endpoint gave invalid JSON in response.

Endpoint: $token_endpoint
Status: $status
Parse error: $parse_error
JSON:
$content
EOT
    }
    elsif ($data->{error}) {
        # Assume a valid OAuth 2 error message.
        my $message = "OAuth2 error: $data->{error}";

        # Do we have a mythical service provider that gives us more?
        if ($data->{error_uri}) {
            # They seem to have a web page with detail.
            $message .= "\n$data->{error_uri} may say more.\n";
        }

        if ($data->{error_description}) {
            # Wow!  Thank you!
            $message .= "\n\nDescription: $data->{error_description}\n";
        }
        return $message;
    }
    elsif (not $data->{token_type}) {
        # Someone failed to follow the spec...
        return <<"EOT";
Token endpoint missing expected token_type in successful response.

Endpoint: $token_endpoint
JSON:
$content
EOT
    }

    my $type = $self->access_token_class(lc($data->{token_type}));
    if ($type !~ /^[\w\:]+\z/) {
        # We got an error. :-(
        return $type;
    }

    eval {load($type)};
    if ($@) {
        # MAKE THIS FATAL.  (Clearly Perl code is simply wrong.)
        confess("Loading $type for $data->{token_type} gave error: $@");
    }

    # Try to make an access token.
    my $access_token = $type->from_ref($data);

    if (not ref($access_token)) {
        # This should be an error message of some sort.
        return $access_token;
    }
    else {
        # WE SURVIVED!  EVERYTHING IS GOOD!
        if ($oauth2->access_token) {
            $access_token->copy_refresh_from($oauth2->access_token);
        }
        return $access_token;
    }
}


1;