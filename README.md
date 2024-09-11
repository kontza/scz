# scz
Set Ghostty pane background colour on SSH connection.

## The Plan
1. Get parent PID, PPID.
2. Get PPID's command line.
3. Check for specific command line pattern, that should not be coloured.
4. Change theme.
5. On PPID exit, restore theme.
