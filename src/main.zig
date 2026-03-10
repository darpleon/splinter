const std = @import("std");

const c = @cImport({
    @cInclude("emscripten.h");
    @cInclude("emscripten/html5.h");
    @cInclude("webgpu/webgpu.h");
});

fn toWGPUStringView(slice: []const u8) c.WGPUStringView {
    return .{ .data = slice.ptr, .length = slice.len };
}

const GPUContext = struct {
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
};

const AppState = struct {
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

fn configureSurface() void {
    const s = state orelse unreachable;
    var css_width: f64 = undefined;
    var css_height: f64 = undefined;
    _ = c.emscripten_get_element_css_size("#canvas", &css_width, &css_height);
    const device_pixel_ratio = c.emscripten_get_device_pixel_ratio();
    const target_width: u32 = @intFromFloat(css_width * device_pixel_ratio);
    const target_height: u32 = @intFromFloat(css_height * device_pixel_ratio);

    _ = c.emscripten_set_canvas_element_size("#canvas", @intCast(target_width), @intCast(target_height));

    std.log.info("cavas size: {}x{}", .{ target_width, target_height });

    const config = c.WGPUSurfaceConfiguration{
        .nextInChain = null,
        .device = GPUContext.device,
        .format = c.WGPUTextureFormat_BGRA8Unorm,
        .usage = c.WGPUTextureUsage_RenderAttachment,
        .alphaMode = c.WGPUCompositeAlphaMode_Auto,
        .width = target_width,
        .height = target_height,
        .presentMode = c.WGPUPresentMode_Fifo,
    };

    c.wgpuSurfaceConfigure(GPUContext.surface, &config);

    const aspect_ratio = @as(f32, @floatFromInt(target_width)) / @as(f32, @floatFromInt(target_height));
    const ubo_data = Uniforms{ .aspect_ratio = aspect_ratio };

    c.wgpuQueueWriteBuffer(GPUContext.queue, s.uniform_buffer, 0, &ubo_data, @sizeOf(Uniforms));

    render();
}

export fn onResize(event_type: c_int, ui_event: [*c]const c.EmscriptenUiEvent, userdata: ?*anyopaque) callconv(.c) bool {
    _ = event_type;
    _ = ui_event;
    _ = userdata;
    configureSurface();
    return false;
}

export fn render() void {
    std.log.info("rendering", .{});
    const s = state orelse return;

    var surface_texture = std.mem.zeroes(c.WGPUSurfaceTexture);
    c.wgpuSurfaceGetCurrentTexture(GPUContext.surface, &surface_texture);

    const view = c.wgpuTextureCreateView(surface_texture.texture, null);

    const encoder_desc = std.mem.zeroes(c.WGPUCommandEncoderDescriptor);
    const encoder = c.wgpuDeviceCreateCommandEncoder(GPUContext.device, &encoder_desc);

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
    c.wgpuRenderPassEncoderSetPipeline(pass, Pipelines.basic_2d);
    c.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, s.vertex_buffer, 0, @sizeOf(Vertex) * 3);
    c.wgpuRenderPassEncoderSetBindGroup(pass, 0, s.bind_group, 0, null);
    c.wgpuRenderPassEncoderDraw(pass, 3, 1, 0, 0);
    c.wgpuRenderPassEncoderEnd(pass);
    c.wgpuRenderPassEncoderRelease(pass);

    const command_buffer = c.wgpuCommandEncoderFinish(encoder, null);
    c.wgpuQueueSubmit(GPUContext.queue, 1, &command_buffer);
}

pub fn main() void {
    GPUContext.init();

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
        GPUContext.status = .failed;
        std.log.err("Adapter error: {s}", .{message.data[0..message.length]});
        return;
    }
    GPUContext.adapter = adapter;
    GPUContext.status = .acquiring_device;

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

const InitState = enum { uninitialized, initialized };

const Shaders = struct {
    var colored_vertices: c.WGPUShaderModule = undefined;

    var status: InitState = .uninitialized;

    pub fn init(device: c.WGPUDevice) void {
        const shader_code = @embedFile("shader/colored_vertices.wgsl");
        var wgsl_source = c.WGPUShaderSourceWGSL{
            .chain = .{ .next = null, .sType = c.WGPUSType_ShaderSourceWGSL },
            .code = toWGPUStringView(shader_code),
        };
        const shader_desc = c.WGPUShaderModuleDescriptor{
            .nextInChain = @ptrCast(&wgsl_source),
            .label = toWGPUStringView("colored_vertices_shader"),
        };
        colored_vertices = c.wgpuDeviceCreateShaderModule(device, &shader_desc);

        status = .initialized;
        std.log.info("Colored vertices shader initialized", .{});
    }
};

const VertexBufferLayouts = struct {
    var colored_vertices: c.WGPUVertexBufferLayout = undefined;

    var status: InitState = .uninitialized;

    pub fn init() void {
        if (status == .initialized) return;
        const vertex_attributes = [_]c.WGPUVertexAttribute{
            .{ .format = c.WGPUVertexFormat_Float32x2, .offset = @offsetOf(Vertex, "position"), .shaderLocation = 0 },
            .{ .format = c.WGPUVertexFormat_Float32x3, .offset = @offsetOf(Vertex, "color"), .shaderLocation = 1 },
        };

        colored_vertices = c.WGPUVertexBufferLayout{
            .arrayStride = @sizeOf(Vertex),
            .stepMode = c.WGPUVertexStepMode_Vertex,
            .attributeCount = vertex_attributes.len,
            .attributes = &vertex_attributes,
        };
        status = .initialized;
    }
};

const BindGroupLayouts = struct {
    var canvas_scale: c.WGPUBindGroupLayout = undefined;

    var status: InitState = .uninitialized;

    pub fn init(device: c.WGPUDevice) void {
        if (status == .initialized) return;
        const bgl_entry = c.WGPUBindGroupLayoutEntry{
            .binding = 0,
            .visibility = c.WGPUShaderStage_Vertex,
            .buffer = .{ .type = c.WGPUBufferBindingType_Uniform },
        };

        const bgl_desc = c.WGPUBindGroupLayoutDescriptor{
            .entryCount = 1,
            .entries = &bgl_entry,
        };
        canvas_scale = c.wgpuDeviceCreateBindGroupLayout(device, &bgl_desc);
        status = .initialized;
    }
};

const PipelineLayouts = struct {
    var basic_2d: c.WGPUPipelineLayout = undefined;

    var status: InitState = .uninitialized;

    pub fn init(device: c.WGPUDevice) void {
        if (status == .initialized) return;

        BindGroupLayouts.init(device);

        const pipeline_layout_desc = c.WGPUPipelineLayoutDescriptor{
            .bindGroupLayoutCount = 1,
            .bindGroupLayouts = &BindGroupLayouts.canvas_scale,
        };
        basic_2d = c.wgpuDeviceCreatePipelineLayout(device, &pipeline_layout_desc);
        status = .initialized;
    }
};

const Pipelines = struct {
    var basic_2d: c.WGPURenderPipeline = undefined;

    var status: InitState = .uninitialized;

    pub fn init(device: c.WGPUDevice) void {
        if (status == .initialized) return;

        Shaders.init(device);
        VertexBufferLayouts.init();
        PipelineLayouts.init(device);

        const vertex: c.WGPUVertexState = .{
            .module = Shaders.colored_vertices,
            .entryPoint = toWGPUStringView("vs_main"),
            .bufferCount = 1,
            .buffers = &VertexBufferLayouts.colored_vertices,
        };
        const primitive: c.WGPUPrimitiveState = .{
            .topology = c.WGPUPrimitiveTopology_TriangleList,
            .frontFace = c.WGPUFrontFace_CCW,
            .cullMode = c.WGPUCullMode_None,
        };
        const multisample: c.WGPUMultisampleState = .{
            .count = 1,
            .mask = 0xFFFFFFFF,
            .alphaToCoverageEnabled = @intFromBool(false),
        };
        const color_target: c.WGPUColorTargetState = .{
            .nextInChain = null,
            .format = c.WGPUTextureFormat_BGRA8Unorm,
            .blend = null,
            .writeMask = c.WGPUColorWriteMask_All,
        };
        const fragment_state: c.WGPUFragmentState = .{
            .nextInChain = null,
            .module = Shaders.colored_vertices,
            .entryPoint = toWGPUStringView("fs_main"),
            .constantCount = 0,
            .constants = null,
            .targetCount = 1,
            .targets = &color_target,
        };

        const pipeline_desc: c.WGPURenderPipelineDescriptor = .{
            .nextInChain = null,
            .label = toWGPUStringView("basic_pipeline"),
            .layout = PipelineLayouts.basic_2d,
            .vertex = vertex,
            .primitive = primitive,
            .depthStencil = null,
            .multisample = multisample,
            .fragment = &fragment_state,
        };
        basic_2d = c.wgpuDeviceCreateRenderPipeline(device, &pipeline_desc);

        status = .initialized;
        std.log.info("Basic render pipeline initialized", .{});
    }
};

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
        GPUContext.status = .failed;
        std.log.err("Device error: {s}", .{message.data[0..message.length]});
        return;
    }
    GPUContext.device = device;
    GPUContext.queue = c.wgpuDeviceGetQueue(device);
    GPUContext.status = .ready;

    std.log.info("GPU context successfully initialized", .{});

    Pipelines.init(device);

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
    const uniform_buffer_desc = c.WGPUBufferDescriptor{
        .label = toWGPUStringView("uniform_buffer"),
        .usage = c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst,
        .size = @sizeOf(Uniforms),
        .mappedAtCreation = @intFromBool(false),
    };
    const uniform_buffer = c.wgpuDeviceCreateBuffer(device, &uniform_buffer_desc);

    const bg_entry = c.WGPUBindGroupEntry{
        .binding = 0,
        .buffer = uniform_buffer,
        .offset = 0,
        .size = @sizeOf(Uniforms),
    };

    const bind_group = c.wgpuDeviceCreateBindGroup(device, &.{
        .layout = BindGroupLayouts.canvas_scale,
        .entryCount = 1,
        .entries = &bg_entry,
    });

    GPUContext.surface = c.wgpuInstanceCreateSurface(GPUContext.instance, &.{
        .nextInChain = @ptrCast(@constCast(&c.WGPUEmscriptenSurfaceSourceCanvasHTMLSelector{
            .chain = .{ .next = null, .sType = c.WGPUSType_EmscriptenSurfaceSourceCanvasHTMLSelector },
            .selector = toWGPUStringView("#canvas"),
        })),
    });

    state = .{
        .vertex_buffer = vertex_buffer,
        .uniform_buffer = uniform_buffer,
        .bind_group = bind_group,
    };

    configureSurface();

    const EMSCRIPTEN_EVENT_TARGET_WINDOW = @as([*c]const u8, @ptrFromInt(2));
    _ = c.emscripten_set_resize_callback(EMSCRIPTEN_EVENT_TARGET_WINDOW, null, false, onResize);

    // Upload data using the queue
    c.wgpuQueueWriteBuffer(GPUContext.queue, vertex_buffer, 0, &vertices, @sizeOf(@TypeOf(vertices)));

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
