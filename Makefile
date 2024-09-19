./zig-out/bin/scz: ./src/main.zig
	zig build -freference-trace
