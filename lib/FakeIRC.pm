package FakeIRC;

sub new {
	return bless({},"FakeIRC");
}

sub channel_list {
    return qw(Clint Eli);
}

sub AUTOLOAD {
	return 1;
}

1;

