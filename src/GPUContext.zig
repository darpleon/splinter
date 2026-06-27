const std = @import("std");

const c = @cImport({
    @cInclude("emscripten.h");
    @cInclude("emscripten/html5.h");
    @cInclude("webgpu/webgpu.h");
});

var instance: c.WGPUInstance = undefined;
var adapter: c.WGPUAdapter = undefined;
var device: c.WGPUDevice = undefined;
var queue: c.WGPUQueue = undefined;
var surface: c.WGPUSurface = undefined;

var status: enum { uninitialized, acquiring_adapter, acquiring_device, ready, failed } = .uninitialized;

pub fn init() void {
    instance = c.wgpuCreateInstance(null);
    requestHardware();
    c.wgpuInstanceProcessEvents(instance);
}

pub fn requestHardware() void {
    status = .acquiring_adapter;
    const options = std.mem.zeroes(c.WGPURequestAdapterOptions);
    const cb_info = c.WGPURequestAdapterCallbackInfo{
        .mode = c.WGPUCallbackMode_AllowSpontaneous,
        .callback = onAdapterRequestEnded,
    };
    _ = c.wgpuInstanceRequestAdapter(instance, &options, cb_info);
}

export fn onAdapterRequestEnded(
    request_status: c.WGPURequestAdapterStatus,
    result_adapter: c.WGPUAdapter,
    message: c.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) void {
    _ = userdata1;
    _ = userdata2;
    if (status != c.WGPURequestAdapterStatus_Success) {
        status = .failed;
        std.log.err("Adapter error: {s}", .{message.data[0..message.length]});
        return;
    }
    adapter = adapter;
    status = .acquiring_device;

    var info = std.mem.zeroes(c.WGPUAdapterInfo);
    _ = c.wgpuAdapterGetInfo(adapter, &info);
    std.log.info("Adapter found. backendType: '{d}' | adapterType: '{d}'", .{
        info.backendType,
        info.adapterType,
    });

    const req_device_info = c.WGPURequestDeviceCallbackInfo{
        // .mode = c.WGPUCallbackMode_AllowProcessEvents,
        .mode = c.WGPUCallbackMode_AllowSpontaneous,
        .callback = onDeviceRequestEnded,
    };

    const descriptor = c.WGPUDeviceDescriptor{ .uncapturedErrorCallbackInfo = .{ .callback = onError } };
    _ = c.wgpuAdapterRequestDevice(adapter, &descriptor, req_device_info);
}
