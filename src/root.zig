//! thresh's stages as one module, for programs outside src/ that drive
//! them directly: the benchmarks.

pub const Dialect = @import("dialect.zig").Dialect;
pub const scan = @import("scan.zig");
pub const records = @import("records.zig");
pub const reference = @import("reference.zig");
pub const input = @import("input.zig");
