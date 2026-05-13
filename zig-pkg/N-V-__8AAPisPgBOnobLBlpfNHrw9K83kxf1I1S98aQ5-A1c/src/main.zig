pub const gen = @import("gen.zig");
pub const extras = @import("extras.zig");

// Re-export commonly used types from gen.zig
pub const id = gen.id;
pub const SEL = gen.SEL;
pub const Class = gen.Class;
pub const Protocol = gen.Protocol;
pub const IMP = gen.IMP;
pub const NSZone = gen.NSZone;
pub const objc_msgSend = gen.objc_msgSend;
pub const objc_lookUpClass = gen.objc_lookUpClass;
pub const objc_getClass = gen.objc_getClass;
pub const sel_registerName = gen.sel_registerName;
pub const objc_allocateClassPair = gen.objc_allocateClassPair;
pub const class_addMethod = gen.class_addMethod;
pub const NSImage = gen.NSImage;
pub const CachedClass = gen.CachedClass;
pub const CachedSelector = gen.CachedSelector;
pub const Object = gen.Object;
pub const NSObject = gen.NSObject;
pub const MTLSize = gen.MTLSize;
pub const MTLResourceOptions = gen.MTLResourceOptions;
pub const NSError = gen.NSError;
pub const NSArray = gen.NSArray;
pub const dispatch_data_t = gen.dispatch_data_t;

// Wrapper function that returns the MTLDevice wrapper type
pub fn createSystemDefaultDevice() ?MTLDevice {
    const ptr = gen.MTLCreateSystemDefaultDevice() orelse return null;
    return MTLDevice{ .ptr = ptr };
}

// Keep the raw function for backwards compatibility
pub const MTLCreateSystemDefaultDevice = gen.MTLCreateSystemDefaultDevice;

// NSString wrapper
pub const NSString = struct {
    ptr: *gen.NSString,

    // Use the opaque type directly (not pointer) so *Self = *gen.NSString
    const StringMixin = gen.NSStringInterfaceMixin(gen.NSString, "NSString");

    pub fn stringWithUTF8String(str: [*:0]const u8) NSString {
        return .{ .ptr = StringMixin.stringWithUTF8String(str) };
    }

    pub fn UTF8String(self: NSString) [*:0]const u8 {
        return StringMixin.UTF8String(self.ptr);
    }
};

// MTLDevice wrapper with method access
pub const MTLDevice = struct {
    ptr: *gen.MTLDevice,

    // Use the opaque type directly (not pointer) so *Self = *gen.MTLDevice
    const DeviceMixin = gen.MTLDeviceProtocolMixin(gen.MTLDevice, "MTLDevice");
    const ObjectMixin = gen.NSObjectProtocolMixin(gen.MTLDevice, "MTLDevice");

    pub fn name(self: MTLDevice) NSString {
        return NSString{ .ptr = DeviceMixin.name(self.ptr) };
    }

    pub fn newCommandQueue(self: MTLDevice) ?MTLCommandQueue {
        const ptr = DeviceMixin.newCommandQueue(self.ptr) orelse return null;
        return MTLCommandQueue{ .ptr = ptr };
    }

    pub fn newLibraryWithSourceOptionsError(self: MTLDevice, source: NSString, options: ?*gen.MTLCompileOptions, err: ?*?*NSError) ?MTLLibrary {
        const ptr = DeviceMixin.newLibraryWithSourceOptionsError(self.ptr, source.ptr, options, err) orelse return null;
        return MTLLibrary{ .ptr = ptr };
    }

    pub fn newBufferWithLengthOptions(self: MTLDevice, length: c_ulong, options: gen.MTLResourceOptions) ?MTLBuffer {
        const ptr = DeviceMixin.newBufferWithLengthOptions(self.ptr, length, options) orelse return null;
        return MTLBuffer{ .ptr = ptr };
    }

    pub fn newComputePipelineStateWithFunctionError(self: MTLDevice, func: MTLFunction, err: ?*?*NSError) ?MTLComputePipelineState {
        const ptr = DeviceMixin.newComputePipelineStateWithFunctionError(self.ptr, func.ptr, err) orelse return null;
        return MTLComputePipelineState{ .ptr = ptr };
    }

    pub fn release(self: MTLDevice) void {
        ObjectMixin.release(self.ptr);
    }
};

// MTLCommandQueue wrapper
pub const MTLCommandQueue = struct {
    ptr: *gen.MTLCommandQueue,

    const QueueMixin = gen.MTLCommandQueueProtocolMixin(gen.MTLCommandQueue, "MTLCommandQueue");
    const ObjectMixin = gen.NSObjectProtocolMixin(gen.MTLCommandQueue, "MTLCommandQueue");

    pub fn commandBuffer(self: MTLCommandQueue) ?MTLCommandBuffer {
        const ptr = QueueMixin.commandBuffer(self.ptr) orelse return null;
        return MTLCommandBuffer{ .ptr = ptr };
    }

    pub fn release(self: MTLCommandQueue) void {
        ObjectMixin.release(self.ptr);
    }
};

// MTLCommandBuffer wrapper
pub const MTLCommandBuffer = struct {
    ptr: *gen.MTLCommandBuffer,

    const BufferMixin = gen.MTLCommandBufferProtocolMixin(gen.MTLCommandBuffer, "MTLCommandBuffer");

    pub fn computeCommandEncoder(self: MTLCommandBuffer) ?MTLComputeCommandEncoder {
        const ptr = BufferMixin.computeCommandEncoder(self.ptr) orelse return null;
        return MTLComputeCommandEncoder{ .ptr = ptr };
    }

    pub fn commit(self: MTLCommandBuffer) void {
        BufferMixin.commit(self.ptr);
    }

    pub fn waitUntilCompleted(self: MTLCommandBuffer) void {
        BufferMixin.waitUntilCompleted(self.ptr);
    }
};

// MTLComputeCommandEncoder wrapper
pub const MTLComputeCommandEncoder = struct {
    ptr: *gen.MTLComputeCommandEncoder,

    const EncoderMixin = gen.MTLComputeCommandEncoderProtocolMixin(gen.MTLComputeCommandEncoder, "MTLComputeCommandEncoder");
    const BaseEncoderMixin = gen.MTLCommandEncoderProtocolMixin(gen.MTLComputeCommandEncoder, "MTLComputeCommandEncoder");

    pub fn setComputePipelineState(self: MTLComputeCommandEncoder, state: MTLComputePipelineState) void {
        EncoderMixin.setComputePipelineState(self.ptr, state.ptr);
    }

    pub fn setBufferOffsetAtIndex(self: MTLComputeCommandEncoder, buffer: MTLBuffer, offset: c_ulong, index: c_ulong) void {
        EncoderMixin.setBufferOffsetAtIndex(self.ptr, buffer.ptr, offset, index);
    }

    pub fn dispatchThreadgroupsThreadsPerThreadgroup(self: MTLComputeCommandEncoder, grid: MTLSize, threads: MTLSize) void {
        EncoderMixin.dispatchThreadgroupsThreadsPerThreadgroup(self.ptr, grid, threads);
    }

    pub fn dispatchThreadsThreadsPerThreadgroup(self: MTLComputeCommandEncoder, grid: MTLSize, threads: MTLSize) void {
        EncoderMixin.dispatchThreadsThreadsPerThreadgroup(self.ptr, grid, threads);
    }

    pub fn endEncoding(self: MTLComputeCommandEncoder) void {
        BaseEncoderMixin.endEncoding(self.ptr);
    }
};

// MTLLibrary wrapper
pub const MTLLibrary = struct {
    ptr: *gen.MTLLibrary,

    const LibMixin = gen.MTLLibraryProtocolMixin(gen.MTLLibrary, "MTLLibrary");
    const ObjectMixin = gen.NSObjectProtocolMixin(gen.MTLLibrary, "MTLLibrary");

    pub fn newFunctionWithName(self: MTLLibrary, func_name: NSString) ?MTLFunction {
        const ptr = LibMixin.newFunctionWithName(self.ptr, func_name.ptr) orelse return null;
        return MTLFunction{ .ptr = ptr };
    }

    pub fn release(self: MTLLibrary) void {
        ObjectMixin.release(self.ptr);
    }
};

// MTLFunction wrapper
pub const MTLFunction = struct {
    ptr: *gen.MTLFunction,

    const ObjectMixin = gen.NSObjectProtocolMixin(gen.MTLFunction, "MTLFunction");

    pub fn release(self: MTLFunction) void {
        ObjectMixin.release(self.ptr);
    }
};

// MTLComputePipelineState wrapper
pub const MTLComputePipelineState = struct {
    ptr: *gen.MTLComputePipelineState,

    const PipelineMixin = gen.MTLComputePipelineStateProtocolMixin(gen.MTLComputePipelineState, "MTLComputePipelineState");
    const ObjectMixin = gen.NSObjectProtocolMixin(gen.MTLComputePipelineState, "MTLComputePipelineState");

    pub fn maxTotalThreadsPerThreadgroup(self: MTLComputePipelineState) c_ulong {
        return PipelineMixin.maxTotalThreadsPerThreadgroup(self.ptr);
    }

    pub fn release(self: MTLComputePipelineState) void {
        ObjectMixin.release(self.ptr);
    }
};

// MTLBuffer wrapper
pub const MTLBuffer = struct {
    ptr: *gen.MTLBuffer,

    const BufferMixin = gen.MTLBufferProtocolMixin(gen.MTLBuffer, "MTLBuffer");
    const ObjectMixin = gen.NSObjectProtocolMixin(gen.MTLBuffer, "MTLBuffer");

    pub fn contents(self: MTLBuffer) ?*anyopaque {
        return BufferMixin.contents(self.ptr);
    }

    pub fn release(self: MTLBuffer) void {
        ObjectMixin.release(self.ptr);
    }
};
