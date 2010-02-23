use Tcl;

my $tcl = Tcl->new();
$tcl->Init();
print $tcl->Eval("proc putlog args {}"),$/;
print $tcl->EvalFile("smeggdrop.tcl"),$/;
print $tcl->Eval("return w"),$/;
print $tcl->Eval("pub:tcl:perform nick mask handle channel  {return what}"),$/;
print $tcl->Eval("pub:tcl:perform nick mask handle channel  {http get http://localhost}"),$/;
