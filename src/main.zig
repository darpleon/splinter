const std = @import("std");

const c = @cImport({
    @cInclude("emscripten.h");
    @cInclude("emscripten/html5.h");
    @cInclude("webgpu/webgpu.h");
});

fn toWGPUStringView(slice: []const u8) c.WGPUStringView {
    return .{ .data = slice.ptr, .length = slice.len };
}

var instance: c.WGPUInstance = undefined;

const AppState = struct {
    device: c.WGPUDevice,
    queue: c.WGPUQueue,
    pipeline: c.WGPURenderPipeline,
    surface: c.WGPUSurface,
    surface_config: c.WGPUSurfaceConfiguration,
    vertex_buffer: c.WGPUBuffer,
    uniform_buffer: c.WGPUBuffer,
    bind_group: c.WGPUBindGroup,
};

var state: ?AppState = null;

const Vertex = struct {
    position: [2]f32,
    color: [3]f32,
};

const Uniforms = struct {
    aspect_ratio: f32,
    _padding: [3]u32 = .{ 0, 0, 0 }, // WebGPU uniforms usually prefer 16-byte alignment
};

export fn onResize(event_type: c_int, ui_event: [*c]const c.EmscriptenUiEvent, userdata: ?*anyopaque) callconv(.c) bool {
    _ = event_type;
    _ = ui_event;
    _ = userdata;
    var s = state orelse return false;
    var css_width: f64 = undefined;
    var css_height: f64 = undefined;
    _ = c.emscripten_get_element_css_size("#canvas", &css_width, &css_height);
    const device_pixel_ratio = c.emscripten_get_device_pixel_ratio();
    const target_width: u32 = @intFromFloat(css_width * device_pixel_ratio);
    const target_height: u32 = @intFromFloat(css_height * device_pixel_ratio);

    if (target_width != s.surface_config.width or target_height != s.surface_config.height) {
        _ = c.emscripten_set_canvas_element_size("#canvas", @intCast(target_width), @intCast(target_height));

        s.surface_config.width = target_width;
        s.surface_config.height = target_height;
        std.log.info("cavas size: {}x{}", .{ s.surface_config.width, s.surface_config.height });

        c.wgpuSurfaceConfigure(s.surface, &s.surface_config);

        const aspect_ratio = @as(f32, @floatFromInt(s.surface_config.width)) / @as(f32, @floatFromInt(s.surface_config.height));
        const ubo_data = Uniforms{ .aspect_ratio = aspect_ratio };

        c.wgpuQueueWriteBuffer(s.queue, s.uniform_buffer, 0, &ubo_data, @sizeOf(Uniforms));

        render();
        return false;
    }
    return false;
}

export fn render() void {
    std.log.info("rendering", .{});
    const s = state orelse return;

    var surface_texture = std.mem.zeroes(c.WGPUSurfaceTexture);
    c.wgpuSurfaceGetCurrentTexture(s.surface, &surface_texture);

    const view = c.wgpuTextureCreateView(surface_texture.texture, null);

    const encoder_desc = std.mem.zeroes(c.WGPUCommandEncoderDescriptor);
    const encoder = c.wgpuDeviceCreateCommandEncoder(s.device, &encoder_desc);

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

    const pass = c.wgpuCommandEncoderBeginRenderPass(encoder, &render_pass_desc);
    c.wgpuRenderPassEncoderSetPipeline(pass, s.pipeline);
    c.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, s.vertex_buffer, 0, @sizeOf(Vertex) * 3);
    c.wgpuRenderPassEncoderSetBindGroup(pass, 0, s.bind_group, 0, null);
    c.wgpuRenderPassEncoderDraw(pass, 3, 1, 0, 0);
    c.wgpuRenderPassEncoderEnd(pass);
    c.wgpuRenderPassEncoderRelease(pass);

    const command_buffer = c.wgpuCommandEncoderFinish(encoder, null);
    c.wgpuQueueSubmit(s.queue, 1, &command_buffer);
}

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
    // c.emscripten_set_main_loop(frame, 1, false);
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

    const shader_code = @embedFile("shader/colored_vertices.wgsl");
    var wgsl_source = c.WGPUShaderSourceWGSL{
        .chain = .{ .next = null, .sType = c.WGPUSType_ShaderSourceWGSL },
        .code = toWGPUStringView(shader_code),
    };
    const shader_desc = c.WGPUShaderModuleDescriptor{
        .nextInChain = @ptrCast(&wgsl_source),
        .label = toWGPUStringView("colored_vertices_shader"),
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

    const vertices = [_]Vertex{
        .{ .position = .{ 0.0, 0.5 }, .color = .{ 1.0, 0.0, 0.0 } },
        .{ .position = .{ -0.5, -0.5 }, .color = .{ 0.0, 1.0, 0.0 } },
        .{ .position = .{ 0.5, -0.5 }, .color = .{ 0.0, 0.0, 1.0 } },
    };

    const vertex_buffer_desc = c.WGPUBufferDescriptor{
        .nextInChain = null,
        .label = toWGPUStringView("vertex_buffer"),
        .usage = c.WGPUBufferUsage_Vertex | c.WGPUBufferUsage_CopyDst,
        .size = @sizeOf(@TypeOf(vertices)),
        .mappedAtCreation = @intFromBool(false),
    };
    const vertex_buffer = c.wgpuDeviceCreateBuffer(device, &vertex_buffer_desc);
    const vertex_attributes = [_]c.WGPUVertexAttribute{
        .{ .format = c.WGPUVertexFormat_Float32x2, .offset = @offsetOf(Vertex, "position"), .shaderLocation = 0 },
        .{ .format = c.WGPUVertexFormat_Float32x3, .offset = @offsetOf(Vertex, "color"), .shaderLocation = 1 },
    };

    const vertex_buffer_layout = c.WGPUVertexBufferLayout{
        .arrayStride = @sizeOf(Vertex),
        .stepMode = c.WGPUVertexStepMode_Vertex,
        .attributeCount = vertex_attributes.len,
        .attributes = &vertex_attributes,
    };

    const uniform_buffer_desc = c.WGPUBufferDescriptor{
        .label = toWGPUStringView("uniform_buffer"),
        .usage = c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst,
        .size = @sizeOf(Uniforms),
        .mappedAtCreation = @intFromBool(false),
    };
    const uniform_buffer = c.wgpuDeviceCreateBuffer(device, &uniform_buffer_desc);
    // 2. Define the Bind Group Layout (The "Template")
    const bgl_entry = c.WGPUBindGroupLayoutEntry{
        .binding = 0,
        .visibility = c.WGPUShaderStage_Vertex,
        .buffer = .{ .type = c.WGPUBufferBindingType_Uniform },
    };

    const bgl_desc = c.WGPUBindGroupLayoutDescriptor{
        .entryCount = 1,
        .entries = &bgl_entry,
    };
    const bind_group_layout = c.wgpuDeviceCreateBindGroupLayout(device, &bgl_desc);

    const pipeline_layout_desc = c.WGPUPipelineLayoutDescriptor{
        .bindGroupLayoutCount = 1,
        .bindGroupLayouts = &bind_group_layout,
    };
    const pipeline_layout = c.wgpuDeviceCreatePipelineLayout(device, &pipeline_layout_desc);

    var pipeline_desc = std.mem.zeroes(c.WGPURenderPipelineDescriptor);
    pipeline_desc.label = toWGPUStringView("main_pipeline");
    pipeline_desc.vertex = .{
        .module = shader_module,
        .entryPoint = toWGPUStringView("vs_main"),
        .bufferCount = 1,
        .buffers = &vertex_buffer_layout, // Direct WebGPU to use your buffer
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
    pipeline_desc.layout = pipeline_layout;
    const pipeline = c.wgpuDeviceCreateRenderPipeline(device, &pipeline_desc);
    std.log.info("Render Pipeline created successfully!", .{});

    // 5. Create the Bind Group (The "Actual Data")
    const bg_entry = c.WGPUBindGroupEntry{
        .binding = 0,
        .buffer = uniform_buffer,
        .offset = 0,
        .size = @sizeOf(Uniforms),
    };

    const bind_group = c.wgpuDeviceCreateBindGroup(device, &.{
        .layout = bind_group_layout,
        .entryCount = 1,
        .entries = &bg_entry,
    });

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
        .width = 800,
        .height = 600,
        .presentMode = c.WGPUPresentMode_Fifo,
    };
    c.wgpuSurfaceConfigure(surface, &config);
    state = .{
        .device = device,
        .queue = queue,
        .pipeline = pipeline,
        .surface = surface,
        .surface_config = config,
        .vertex_buffer = vertex_buffer,
        .uniform_buffer = uniform_buffer,
        .bind_group = bind_group,
    };
    // Calculate and upload the initial aspect ratio
    const initial_aspect = @as(f32, @floatFromInt(config.width)) / @as(f32, @floatFromInt(config.height));
    const initial_ubo = Uniforms{ .aspect_ratio = initial_aspect };
    c.wgpuQueueWriteBuffer(queue, uniform_buffer, 0, &initial_ubo, @sizeOf(Uniforms));

    const EMSCRIPTEN_EVENT_TARGET_WINDOW = @as([*c]const u8, @ptrFromInt(2));
    _ = c.emscripten_set_resize_callback(EMSCRIPTEN_EVENT_TARGET_WINDOW, null, false, onResize);

    // Upload data using the queue
    c.wgpuQueueWriteBuffer(queue, vertex_buffer, 0, &vertices, @sizeOf(@TypeOf(vertices)));

    render();
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
