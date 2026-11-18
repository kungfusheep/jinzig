//! jinzig is a port of jingo: it encodes zig structs to a buffer as JSON.
//!
//! You only need to create an instance of an encoder once per struct/slice type
//! you wish to marshal.

const std = @import("std");

pub const buffer = @import("buffer.zig");
pub const Buffer = buffer.Buffer;
pub const Error = buffer.Error;

const struct_encoder = @import("struct_encoder.zig");
pub const StructEncoder = struct_encoder.StructEncoder;
pub const EscapeString = struct_encoder.EscapeString;
pub const Instruction = struct_encoder.Instruction;

pub const SliceEncoder = @import("slice_encoder.zig").SliceEncoder;

pub const Time = @import("ptrconvert.zig").Time;

pub const mode = @import("build_options").mode;

test {
    std.testing.refAllDecls(@This());
}
