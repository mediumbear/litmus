//! A counter.

const std = @import("std");

pub fn add(a: u32, b: u32) u32 {
    return a + b;
}

test "adds" {
    try std.testing.expectEqual(3, add(1, 2));
}
