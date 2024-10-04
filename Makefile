./zig-out/bin/scz: ./src/main.zig
	zig build -freference-trace --release=small

.PHONY=debug
debug: ./src/main.zig
	zig build -freference-trace
