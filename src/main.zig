const std = @import("std");

const c = @cImport({
    @cInclude("emscripten.h");
    @cInclude("webgpu/webgpu.h");
});

var instance: c.WGPUInstance = undefined;

pub fn main() void {
    instance = c.wgpuCreateInstance(null);

    const adapter_options = std.mem.zeroes(c.WGPURequestAdapterOptions);
    const req_adapter_info = c.WGPURequestAdapterCallbackInfo{
        // .mode = c.WGPUCallbackMode_AllowProcessEvents,
        .mode = c.WGPUCallbackMode_AllowSpontaneous,
        .callback = onAdapterRequestEnded,
    };

    std.log.info("Requesting Adapter...", .{});

    _ = c.wgpuInstanceRequestAdapter(instance, &adapter_options, req_adapter_info);

    c.wgpuInstanceProcessEvents(instance);
    c.emscripten_exit_with_live_runtime();
}

export fn onAdapterRequestEnded(
    status: c.WGPURequestAdapterStatus,
    adapter: c.WGPUAdapter,
    message: c.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) void {
    _ = userdata1;
    _ = userdata2;
    if (status != c.WGPURequestAdapterStatus_Success) {
        std.log.err("Adapter error: {s}", .{message.data[0..message.length]});
        return;
    }

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

fn toWGPUStringView(slice: []const u8) c.WGPUStringView {
    return .{ .data = slice.ptr, .length = slice.len };
}

export fn onDeviceRequestEnded(
    status: c.WGPURequestDeviceStatus,
    device: c.WGPUDevice,
    message: c.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) void {
    _ = userdata1;
    _ = userdata2;
    if (status != c.WGPURequestDeviceStatus_Success) {
        std.log.err("Device error: {s}", .{message.data[0..message.length]});
        return;
    }

    std.log.info("Device acquired successfully!", .{});

    const queue = c.wgpuDeviceGetQueue(device);
    if (queue != null) {
        std.log.info("Queue is live. System ready for Pipeline setup.", .{});
    }

    const shader_code = @embedFile("shader/fixed_triangle.wgsl");
    var wgsl_source = c.WGPUShaderSourceWGSL{
        .chain = .{ .next = null, .sType = c.WGPUSType_ShaderSourceWGSL },
        .code = toWGPUStringView(shader_code),
    };
    const shader_desc = c.WGPUShaderModuleDescriptor{
        .nextInChain = @ptrCast(&wgsl_source),
        .label = toWGPUStringView("triangle_shader"),
    };
    const shader_module = c.wgpuDeviceCreateShaderModule(device, &shader_desc);

    const color_target = c.WGPUColorTargetState{
        .nextInChain = null,
        .format = c.WGPUTextureFormat_BGRA8Unorm,
        .blend = null,
        .writeMask = c.WGPUColorWriteMask_All,
    };

    const fragment_state = c.WGPUFragmentState{
        .nextInChain = null,
        .module = shader_module,
        .entryPoint = toWGPUStringView("fs_main"),
        .constantCount = 0,
        .constants = null,
        .targetCount = 1,
        .targets = &color_target,
    };

    var pipeline_desc = std.mem.zeroes(c.WGPURenderPipelineDescriptor);
    pipeline_desc.label = toWGPUStringView("main_pipeline");
    pipeline_desc.vertex = .{
        .module = shader_module,
        .entryPoint = toWGPUStringView("vs_main"),
        .bufferCount = 0,
    };
    pipeline_desc.primitive = .{
        .topology = c.WGPUPrimitiveTopology_TriangleList,
        .frontFace = c.WGPUFrontFace_CCW,
        .cullMode = c.WGPUCullMode_None,
    };
    pipeline_desc.fragment = &fragment_state;
    pipeline_desc.multisample = .{
        .count = 1,
        .mask = 0xFFFFFFFF,
        .alphaToCoverageEnabled = @intFromBool(false),
    };

    const pipeline = c.wgpuDeviceCreateRenderPipeline(device, &pipeline_desc);
    std.log.info("Render Pipeline created successfully!", .{});

    _ = c.wgpuDeviceCreateShaderModule(device, &shader_desc);
    // Get the surface from the HTML canvas (usually ID "#canvas")
    const surface = c.wgpuInstanceCreateSurface(instance, &.{
        .nextInChain = @ptrCast(@constCast(&c.WGPUEmscriptenSurfaceSourceCanvasHTMLSelector{
            .chain = .{ .next = null, .sType = c.WGPUSType_EmscriptenSurfaceSourceCanvasHTMLSelector },
            .selector = toWGPUStringView("#canvas"),
        })),
    });

    // Configure the surface
    const config = c.WGPUSurfaceConfiguration{
        .nextInChain = null,
        .device = device,
        .format = c.WGPUTextureFormat_BGRA8Unorm, // Must match your pipeline!
        .usage = c.WGPUTextureUsage_RenderAttachment,
        .alphaMode = c.WGPUCompositeAlphaMode_Auto,
        .width = 800, // Match your canvas resolution
        .height = 600,
        .presentMode = c.WGPUPresentMode_Fifo,
    };
    c.wgpuSurfaceConfigure(surface, &config);
    // 1. Get the target texture from the canvas
    var surface_texture = std.mem.zeroes(c.WGPUSurfaceTexture);
    c.wgpuSurfaceGetCurrentTexture(surface, &surface_texture);

    const view = c.wgpuTextureCreateView(surface_texture.texture, null);

    // 2. Create the Encoder
    const encoder_desc = std.mem.zeroes(c.WGPUCommandEncoderDescriptor);
    const encoder = c.wgpuDeviceCreateCommandEncoder(device, &encoder_desc);

    // 3. Define the Color Attachment (Clearing the screen)
    const color_attachment = c.WGPURenderPassColorAttachment{
        .view = view,
        .depthSlice = c.WGPU_DEPTH_SLICE_UNDEFINED,
        .loadOp = c.WGPULoadOp_Clear,
        .storeOp = c.WGPUStoreOp_Store,
        .clearValue = .{ .r = 0.05, .g = 0.05, .b = 0.05, .a = 1.0 }, // Dark grey background
    };

    const render_pass_desc = c.WGPURenderPassDescriptor{
        .colorAttachmentCount = 1,
        .colorAttachments = &color_attachment,
    };

    // 4. Record the commands
    const pass = c.wgpuCommandEncoderBeginRenderPass(encoder, &render_pass_desc);
    c.wgpuRenderPassEncoderSetPipeline(pass, pipeline);
    c.wgpuRenderPassEncoderDraw(pass, 3, 1, 0, 0); // 3 vertices for our triangle
    c.wgpuRenderPassEncoderEnd(pass);

    // 5. Submit!
    const command_buffer = c.wgpuCommandEncoderFinish(encoder, null);
    c.wgpuQueueSubmit(queue, 1, &command_buffer);
}

export fn onError(
    device: [*c]const c.WGPUDevice,
    err_type: c.WGPUErrorType,
    message: c.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) void {
    _ = device;
    _ = userdata1;
    _ = userdata2;
    std.log.err("GPU Error ({any}): {s}", .{ err_type, message.data[0..message.length] });
}
