const std = @import("std");

const Scheduler = @This();

const ProcessState = enum {
    running,
    done,
};

const ProcessFn = *const fn

const Process = struct {

};

var processes = std.ArrayList();
