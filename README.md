# scz

**This has been abandoned due to it not working after macOS 15.1 update.
Use [_osscz_](https://github.com/kontza/osscz) instead. It works.**

Set Ghostty pane background colour on SSH connection.

## How to Setup
…

## How It Works
1. Get grand parent PID, GPPID.
2. Get GPPID's command line.
3. Check for specific command line pattern that should not be coloured.
4. Change theme.
5. On GPPID exit, restore theme.
