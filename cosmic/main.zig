const std = @import("std");
const process = std.process;
const stdx = @import("stdx");
const string = stdx.string;
const ds = stdx.ds;
const graphics = @import("graphics");
const Color = graphics.Color;
const sdl = @import("sdl");

const v8 = @import("v8.zig");
const js_env = @import("js_env.zig");
const runtime = @import("runtime.zig");
const RuntimeContext = runtime.RuntimeContext;
const printFmt = runtime.printFmt;
const log = stdx.log.scoped(.main);

const VersionText = "0.1 Alpha";

// Cosmic main. Common entry point for cli and gui.
pub fn main() !void {
    // Fast temporary memory allocator.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try process.argsAlloc(alloc);
    defer process.argsFree(alloc, args);

    if (args.len == 1) {
        replAndExit();
    }

    // Skip exe path arg.
    var arg_idx: usize = 1;

    const cmd = nextArg(args, &arg_idx).?;
    if (string.eq(cmd, "cli")) {
        replAndExit();
    } else if (string.eq(cmd, "run")) {
        const src_path = nextArg(args, &arg_idx) orelse {
            abortFmt("Expected path to main source file.", .{});
        };
        try runAndExit(src_path);
    } else if (string.eq(cmd, "help")) {
        usage();
        process.exit(0);
    } else if (string.eq(cmd, "version")) {
        version();
        process.exit(0);
    } else {
        usage();
        abortFmt("unsupported command {s}", .{cmd});
    }
}

fn runAndExit(src_path: []const u8) !void {
    const alloc = stdx.heap.getDefaultAllocator();
    defer stdx.heap.deinitDefaultAllocator();

    const src = try std.fs.cwd().readFileAlloc(alloc, src_path, 1e9);
    defer alloc.free(src);

    const platform = v8.Platform.initDefault(0, true);
    defer platform.deinit();

    v8.initV8Platform(platform);
    v8.initV8();
    defer {
        _ = v8.deinitV8();
        v8.deinitV8Platform();
    }

    var params = v8.initCreateParams();
    params.array_buffer_allocator = v8.createDefaultArrayBufferAllocator();
    defer v8.destroyArrayBufferAllocator(params.array_buffer_allocator.?);
    var isolate = v8.Isolate.init(&params);
    defer isolate.deinit();

    rt.init(alloc, isolate);
    defer rt.deinit();

    isolate.enter();
    defer isolate.exit();

    var hscope: v8.HandleScope = undefined;
    hscope.init(isolate);
    defer hscope.deinit();

    var context = js_env.init(&rt, isolate);
    context.enter();
    defer context.exit();

    const origin = v8.String.initUtf8(isolate, src_path);

    var res: v8.ExecuteResult = undefined;
    defer res.deinit();
    v8.executeString(alloc, isolate, src, origin, &res);

    while (platform.pumpMessageLoop(isolate, false)) {
        log.info("What does this do?", .{});
        unreachable;
    }

    if (!res.success) {
        printFmt("{s}", .{res.err.?});
        process.exit(1);
    }

    // Check if we need to enter an app loop.
    if (rt.num_windows > 0) {
        runtime.runUserLoop(&rt);
    }

    process.exit(0);
}

fn replAndExit() void {
    const alloc = stdx.heap.getDefaultAllocator();
    defer stdx.heap.deinitDefaultAllocator();

    var input_buf = std.ArrayList(u8).init(alloc);
    defer input_buf.deinit();

    const platform = v8.Platform.initDefault(0, true);
    defer platform.deinit();

    v8.initV8Platform(platform);
    v8.initV8();
    defer {
        _ = v8.deinitV8();
        v8.deinitV8Platform();
    }

    var params = v8.initCreateParams();
    params.array_buffer_allocator = v8.createDefaultArrayBufferAllocator();
    defer v8.destroyArrayBufferAllocator(params.array_buffer_allocator.?);
    var isolate = v8.Isolate.init(&params);
    defer isolate.deinit();

    isolate.enter();
    defer isolate.exit();

    var hscope: v8.HandleScope = undefined;
    hscope.init(isolate);
    defer hscope.deinit();

    var context = v8.Context.init(isolate, null, null);
    context.enter();
    defer context.exit();

    const origin = v8.String.initUtf8(isolate, "(shell)");

    printFmt(
        \\Cosmic ({s})
        \\exit with Ctrl+D or "exit()"
        \\
    , .{VersionText});

    while (true) {
        printFmt("\n> ", .{});
        const input = getInputOrExit(&input_buf);
        if (string.eq(input, "exit()")) {
            break;
        }

        var res: v8.ExecuteResult = undefined;
        defer res.deinit();
        v8.executeString(alloc, isolate, input, origin, &res);
        if (res.success) {
            printFmt("{s}", .{res.result.?});
        } else {
            printFmt("{s}", .{res.err.?});
        }

        while (platform.pumpMessageLoop(isolate, false)) {
            log.info("What does this do?", .{});
            unreachable;
        }
        // log.info("input: {s}", .{input});
    }
    process.exit(0);
}

// TODO: We'll need to support extended key bindings/ncurses (eg. up arrow for last command) per platform.
// (Low priority since there will be a repl in the GUI)
fn getInputOrExit(input_buf: *std.ArrayList(u8)) []const u8 {
    input_buf.clearRetainingCapacity();
    std.io.getStdIn().reader().readUntilDelimiterArrayList(input_buf, '\n', 1000 * 1000 * 1000) catch |err| {
        if (err == error.EndOfStream) {
            printFmt("\n", .{});
            process.exit(0);
        } else {
            unreachable;
        }
    };
    return input_buf.items;
}

var rt: RuntimeContext = undefined;

const main_usage =
    \\Usage: cosmic [command] [options]
    \\
    \\Commands:
    \\
    \\  cli              Starts a REPL session.
    \\  run              Runs a Javascript or Typescript source file.
    \\  test             TODO: Runs tests in source files.
    \\  exe              TODO: Packages source files into a single binary executable.
    \\
    \\  help             Print this help and exit
    \\  version          Print version number and exit
    \\
    \\General Options:
    \\
    \\  -h, --help       Print command-specific usage.
    \\
;

fn usage() void {
    printFmt("{s}\n", .{main_usage});
}

fn version() void {
    printFmt("cosmic {s}\nv8 {s}\n", .{VersionText, v8.getVersion()});
}

pub fn abortFmt(comptime format: []const u8, args: anytype) noreturn {
    log.err(format, args);
    process.exit(1);
}

fn nextArg(args: [][]const u8, idx: *usize) ?[]const u8 {
    if (idx.* >= args.len) return null;
    defer idx.* += 1;
    return args[idx.*];
}