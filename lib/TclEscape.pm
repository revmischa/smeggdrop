package TclEscape;

sub escape {
    my ($tcl) = @_;
    $tcl =~ s#\\#\\\\#g;
    $tcl =~ s#}#\\}#g;
    $tcl =~ s#{#\\{#g;
    return $tcl;
}

sub escape_test {
    my $x1 = 'djksala sldjasl djaldajdklsajdlask jdalsk';
    my @tests = (
                 ["No escape", $x1, $x1],
                 ["Escape brace}", "}", "\\}"],
                 ["Escape brace{", "{", "\\{"],
                 ["Escape braces1", "{}", "\\{\\}"],
                 ["Escape braces2", "}{", "\\}\\{"],
                 ["Escaped braces1", "\\{", "\\\\\\{"],
                 ["Escaped braces1", "\\}", "\\\\\\}"],
                 ["Escaped escape", "\\", "\\\\"],
                 ["Escaped escape2", "\\\\", "\\\\\\\\"],
                 ["Escape fun", "\\{{}\\}", "\\\\\\{\\{\\}\\\\\\}"],
                 ["More Escape fun", "\\\\{", "\\\\\\\\\\{"],
                );
    my $failures = 0;
    foreach my $test (@tests) {
        my ($name, $in,$out) = @$test;
        my $outp = escape($in);
        if ($outp ne $out) {
            print "Test [$name] failed: [$outp] ne expected [$out] $/";
            $failures++;
        }
    }
    die "$failures/".scalar(@tests)." tests failed!" if $failures;
}

1;
