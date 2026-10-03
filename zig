https://www.infoworld.com/article/3689648/meet-the-zig-programming-language.html
https://dev.yorhel.nl/doc/ncdu2
https://code.blicky.net/yorhel/ncdu
https://zig.guide/
https://github.com/ziglang/zig/wiki/Community-Projects

https://ziglang.org/learn/why_zig_rust_d_cpp/
https://ziglang.org/documentation/master/
https://ziglang.org/learn/
https://ziglang.org/learn/tools/
https://ziglang.org/learn/build-system/

https://github.com/ziglang/vscode-zig
https://marketplace.visualstudio.com/items?itemName=ziglang.vscode-zig

https://github.com/ziglang/zig.vim

https://learnxinyminutes.com/docs/zig/
https://gist.github.com/ityonemo/769532c2017ed9143f3571e5ac104e50

https://dev.to/michidk/after-a-day-of-programming-in-zig-463f
https://dev.to/arpitsr/writing-a-local-password-generator-in-zig-and-storing-it-in-a-config-file-1llc

# build invocations (checked Oct 2026, zig 0.17.0)

# --release= is the short form, but it only works if build.zig calls
# standardOptimizeOption. not every project does.
zig build --release=fast
zig build --release=small

# -Doptimize= is the explicit form and always works.
zig build -Doptimize=ReleaseFast

# -Dcpu=native tunes for THIS machine — faster, but the binary may not run
# elsewhere. drop it for anything you ship.
zig build -Doptimize=ReleaseFast -Dcpu=native

# NOTE: an earlier version of this line ended in -j$(nproc). nproc is GNU
# coreutils and is NOT on macOS, so that silently failed here. zig build
# already parallelizes by default, so -j is rarely worth setting; if you do
# need it on macOS:
zig build -Doptimize=ReleaseFast -j$(sysctl -n hw.ncpu)

# incremental rebuilds (0.17+, best supported on x86_64-linux)
zig build -fincremental --watch
