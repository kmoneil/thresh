//! thresh's stages as one module, for programs outside src/ that drive
//! them directly: the benchmarks; and lib, thresh as a library.

pub const lib = @import("lib.zig");
pub const Dialect = @import("dialect.zig").Dialect;
pub const scan = @import("scan.zig");
pub const records = @import("records.zig");
pub const reference = @import("reference.zig");
pub const input = @import("input.zig");
pub const schema = @import("schema.zig");
pub const validate = @import("validate.zig");
pub const builders = @import("builders.zig");
pub const stats = @import("stats.zig");
pub const infer = @import("infer.zig");
pub const csv = @import("write/csv.zig");
pub const arrow = @import("write/arrow.zig");
