@echo off

del *.o *.ppu pq_tui paszlib\*.o paszlib\*.ppu

# -vm3005: suppress "Procedure type FAR ignored" — 32-bit calling-convention relic in vendored paszlib
# -vm6018: suppress "unreachable code" — dead branch in vendored paszlib

fpc -O3 -Xs -Fu.\paszlib -vm3005 -vm6018 pq_tui.pas

echo "Built pq_tui successfully"
