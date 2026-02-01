const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .emscripten });
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addLibrary(.{
        .name = "splinter",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });
    lib.linkLibC();

    const env_map = try std.process.getEnvMap(b.allocator);
    const cache_path = env_map.get("EMSDK_CACHE") orelse return error.MissingEmsdkCachePath;
    const webgpu_include = b.pathJoin(&.{ cache_path, "ports", "emdawnwebgpu", "emdawnwebgpu_pkg", "webgpu", "include" });
    const sysroot_include = b.pathJoin(&.{ cache_path, "sysroot", "include" });
    lib.addSystemIncludePath(.{ .cwd_relative = webgpu_include });
    lib.addSystemIncludePath(.{ .cwd_relative = sysroot_include });

    b.installBinFile("www/webgpu-setup.js", "webgpu-setup.js");

    const bin_path = b.getInstallPath(.bin, "");
    std.fs.cwd().makePath(bin_path) catch |err| {
        std.log.err("Failed to create output directory: {s}", .{@errorName(err)});
    };

    const emcc_run = b.addSystemCommand(&.{"emcc"});

    _ = emcc_run.addArg(b.fmt("-o{s}/index.html", .{bin_path}));
    emcc_run.addPrefixedFileArg("--shell-file=", b.path("www/shell.html"));
    emcc_run.addArg("--use-port=emdawnwebgpu");
    // emcc_run.addArg("-sASYNCIFY");

    emcc_run.addArtifactArg(lib);

    b.getInstallStep().dependOn(&emcc_run.step);

    const run_step = b.step("run", "Serve the web page");

    const bun_path = b.findProgram(&.{"bun"}, &.{}) catch {
        const fail_msg = b.addFail(
            \\This step requires 'bun' to serve the application.
            \\Install it from https://bun.sh, or serve manually with the tool of your choice.
        );
        run_step.dependOn(&fail_msg.step);
        return;
    };

    const serve_cmd = b.addSystemCommand(&.{ bun_path, "serve.ts" });

    serve_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&serve_cmd.step);
}
