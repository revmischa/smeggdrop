package TclEscape;


#assume the tcl is unescaped
sub escape {
    my ($tcl) = @_;
    my $o = $tcl;
    $tcl =~ s/\\/\\\\/g;
    $tcl =~ s/([\[\]}{])/\\$1/g;
    my $interpolated = $tcl;
    return "\"${interpolated}\""
}

sub brace_escape {
    my ($tcl) = @_;
    #$tcl =~ s#\\#\\\\#g;
    #$tcl =~ s#}#\\}#g;
    #$tcl =~ s#{#\\{#g;

    my $balance = not_balanced($tcl);
    if ($balance) {
        #bad
        $tcl =~ s#\\#\\\\#g;
        $tcl =~ s#}#\\}#g;
        $tcl =~ s#{#\\{#g;
        return $tcl;
    } else {
        #good
        $tcl =~ s#\\([^}{\\])#\\\\$1#g;
        $tcl =~ s#\\\\#\\\\\\\\#g;
        $tcl =~ s#^\\$#\\\\#g;
        return $tcl;
    }
}

sub not_balanced {
    my ($tcl) = @_;
    my @chars = split(//,$tcl);
    my $depth = 0;
    my $escape = 0;
    my $tooshallow = 0;
    while (@chars) {
        my $char = shift @chars;
        if (!$escape) {
            if ($char eq "\\") {
                $escape = 1;
            } elsif ($char eq '{') {
                $depth++;
            } elsif ($char eq '}') {
                $depth--;
                if ($depth < 0) {
                    $tooshallow = 1;
                }
            }
        } else {
            $escape = 0;
        }
    }
    my $bool = $tooshallow || $depth != 0;
    return ($bool,$depth,$tooshallow) if wantarray;
    return $bool;
}

sub brace_escape_test {
    my $x1 = 'djksala sldjasl djaldajdklsajdlask jdalsk';
    my $proc = "tcl proc crash {} {string repeat x 2147483644}";
    my $e = "\\";
    my @tests = (
                 ["No escape", $x1, $x1],
                 ["Let a proc through",$proc, $proc],
                 ["Escape brace}", "}", "\\}"],
                 ["Escape brace{", "{", "\\{"],
                 ["Escape braces1", "{}", "{}"],
                 #["Escape braces2", "}{", "}{"], #no clue
                 ["Escaped braces1", "\\}", "\\}"],
                 ["Escaped braces1", "\\{", "\\{"],
                 ["Escaped escape", "$e", "$e$e"],
                 ["Escaped escape2", "$e$e", "$e$e$e$e"],
                 ["Escaped escape3 unbalance", "}$e${e}{", "$e}$e$e$e$e${e}{"],
                 ["Escape fun", "\\{{}\\}","\\{{}\\}"],
                 ["More Escape fun", "\\{", "\\{"],
                 ["Balanced","{{{}}}","{{{}}}"],
                 ["Tricky tcl","{{{\\}}}}","{{{\\}}}}"],
                );
    my $failures = 0;
    foreach my $test (@tests) {
        my ($name, $in,$out) = @$test;
        my $outp = escape($in);
        if ($outp ne $out) {
            print "Test [$name] failed: [$outp] ne expected [$out]  -- input was [$in] $/";
            $failures++;
        }
    }
    die "$failures/".scalar(@tests)." tests failed!" if $failures;
}

1;
