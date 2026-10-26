//! Command line argument iterator.
//! Takes in a slice of 0-sentinel-terminated slice of bytes.
const std = @import("std");
const testing = std.testing;

pub const ArgsIterator = @This();

/// Command line arguements.
buffer: []const [:0]const u8,

/// Seek pointer of the iterator.
seek: usize = 0,

// Init the iterator with command line arguments.
pub fn init(args: []const [:0]const u8) ArgsIterator {
    return .{ .buffer = args, .seek = 0 };
}

/// Yield next element, advancing the seek pointer.
/// Return `null` if at the end of `buffer`.
pub fn next(self: *ArgsIterator) ?[]const u8 {
    if (self.peek()) |slice| {
        self.seek += 1;
        return slice;
    }
    return null;
}

/// Look at the next element, without advancing the seek pointer.
/// Return `null` if at the end of `buffer`.
pub fn peek(self: ArgsIterator) ?[]const u8 {
    return self.peekAhead(0);
}

/// Look at the element at position `n` form the seek pointer.
/// `n = 0` is equivalent to calling `peek`.
/// Return `null` if at the end of `buffer`.
pub fn peekAhead(self: ArgsIterator, n: usize) ?[]const u8 {
    if (self.seek + n >= self.buffer.len) return null;
    return self.buffer[self.seek + n];
}

/// Return the remaining of `buffer`. Does not affect the iterator state.
pub fn rest(self: ArgsIterator) []const [:0]const u8 {
    return self.buffer[self.seek..];
}

/// Reset the iterator to its initial state.
pub fn reset(self: *ArgsIterator) void {
    self.seek = 0;
}

test next {
    const args: []const [:0]const u8 = &.{ "abc", "def", "ghi" };
    var it = ArgsIterator.init(args);
    try testing.expectEqualSlices(u8, "abc", it.next().?);
    try testing.expectEqualSlices(u8, "def", it.next().?);
    try testing.expectEqualSlices(u8, "ghi", it.next().?);
    try testing.expect(it.next() == null);
}

test peek {
    const args: []const [:0]const u8 = &.{ "abc", "def", "ghi" };
    var it = ArgsIterator.init(args);
    try testing.expectEqualSlices(u8, "abc", it.peek().?);
    try testing.expectEqual(0, it.seek);
}

test peekAhead {
    const args: []const [:0]const u8 = &.{ "abc", "def", "ghi" };
    var it = ArgsIterator.init(args);
    try testing.expectEqualSlices(u8, "def", it.peekAhead(1).?);
    try testing.expectEqualSlices(u8, "ghi", it.peekAhead(2).?);
    try testing.expect(it.peekAhead(3) == null);
    try testing.expectEqual(0, it.seek);
}

test rest {
    const args: []const [:0]const u8 = &.{ "abc", "def", "ghi" };
    var it = ArgsIterator.init(args);
    _ = it.next().?;
    const r = it.rest();
    try testing.expectEqual(2, r.len);
    try testing.expectEqualSlices([:0]const u8, &.{ "def", "ghi" }, r);

    it.seek = 3;
    const r_empty = it.rest();
    try testing.expectEqual(0, r_empty.len);
    try testing.expectEqualSlices([:0]const u8, &.{}, r_empty);
}

test reset {
    const args: []const [:0]const u8 = &.{ "abc", "def", "ghi" };
    var it = ArgsIterator.init(args);
    _ = it.next();
    it.reset();
    try testing.expectEqual(0, it.seek);
}
