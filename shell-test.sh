#!/bin/sh
echo "Script PID = $$"
echo "This should print the numbers one to four in order:"
echo 1
./zig-out/bin/scz otsonkolo
echo "Script going to sleep"
sleep 1
echo 3
exit 0
