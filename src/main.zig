const std = @import("std");

const c = @cImport({
    @cInclude("emscripten.h");
    @cInclude("webgpu/webgpu.h");
});

pub fn main() void {
    const device = c.emscripten_webgpu_get_device();

    std.log.info("Handshake Success! Device acquired: {any}", .{device});

    const queue = c.wgpuDeviceGetQueue(device);
    if (queue != null) {
        std.log.info("Command Queue acquired! The GPU is ready.", .{});
    }
}
