use Tcl;

my $tcl = Tcl->new();
$tcl->Init();
print $tcl->Eval("proc putlog args {}"),$/;
print $tcl->EvalFile("smeggdrop.tcl"),$/;
print $tcl->Eval("return w"),$/;
