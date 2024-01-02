const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Atomic;

pub fn Rc(comptime T: type) type {
    return RefCount(T, false);
}

pub fn Arc(comptime T: type) type {
    return RefCount(T, true);
}

pub fn RefCount(comptime T: type, comptime thread_safe: bool) type {
    const use_atomic = !builtin.single_threaded and thread_safe;
    const Counter = if (use_atomic) Atomic(usize) else usize;
    const init_count = if (use_atomic) Atomic(usize).init(1) else 1;

    return struct {
        value: T,
        _count: Counter = init_count,
        allocator: Allocator,

        pub inline fn init(allocator: Allocator, value: T) !*@This() {
            var self = try allocator.create(@This());
            self.* = .{
                .value = value,
                .allocator = allocator,
            };
            return self;
        }

        pub inline fn get(self: *@This()) *T {
            self.ref();
            return self.leak();
        }

        pub inline fn getRef(self: *@This()) *@This() {
            self.ref();
            return self;
        }

        pub inline fn leak(self: *@This()) *T {
            return &self.value;
        }

        pub inline fn ref(self: *@This()) void {
            if (use_atomic) {
                _ = self._count.fetchAdd(1, .Monotonic);
            } else {
                self._count += 1;
            }
        }

        pub inline fn deref(self: *@This()) void {
            if (use_atomic) {
                if (self._count.fetchSub(1, .Release) == 1) {
                    self._count.fence(.Acquire);
                    self.deinit();
                }
            } else {
                assert(self._count > 0);
                self._count -= 1;
                if (self._count == 0) {
                    self.deinit();
                }
            }
        }

        pub inline fn deinit(self: *@This()) void {
            self.value.deinit();
            self.allocator.destroy(self);
        }

        pub inline fn count(self: *@This()) usize {
            if (use_atomic) {
                return self._count.load(.SeqCst);
            } else {
                return self._count;
            }
        }
    };
}

test "Rc" {
    const I32List = std.ArrayList(i32);

    var ptr = try Rc(I32List).init(testing.allocator, I32List.init(testing.allocator));
    defer ptr.deref();

    try testing.expectEqual(@as(usize, 1), ptr.count());
    try ptr.value.append(1);

    {
        var ptr2 = ptr.getRef();
        defer ptr2.deref();
        try testing.expectEqual(@as(usize, 2), ptr.count());
        try ptr.value.append(2);
    }
    try testing.expectEqual(@as(usize, 1), ptr.count());

    {
        var inner_value = ptr.get();
        defer ptr.deref();
        try testing.expectEqual(@as(usize, 2), ptr.count());
        try inner_value.append(3);
    }
    try testing.expectEqual(@as(usize, 1), ptr.count());

    try testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3 }, ptr.value.items);
}

test "Arc" {
    // This test requires spawning threads.
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }

    const I32List = std.ArrayList(i32);
    const Thread = std.Thread;

    var ptr = try Arc(I32List).init(testing.allocator, I32List.init(testing.allocator));
    // defer ptr.deref();

    const num_threads = 4;
    const num_increments = 1000;

    const Runner = struct {
        thread: Thread = undefined,
        ptr: *Arc(I32List) = undefined,

        fn run(self: *@This()) void {
            var i: usize = num_increments;
            while (i > 0) : (i -= 1) {
                var ptr2 = self.ptr.getRef();
                defer ptr2.deref();
            }
        }
    };

    var runners = [_]Runner{.{}} ** num_threads;

    for (&runners) |*r| r.ptr = ptr.getRef();
    try testing.expectEqual(@as(usize, num_threads + 1), ptr.count());
    ptr.deref();
    try testing.expectEqual(@as(usize, num_threads), runners[0].ptr.count());

    for (&runners) |*r| r.thread = try Thread.spawn(.{}, Runner.run, .{r});
    for (runners) |r| {
        r.thread.join();
        r.ptr.deref();
    }
}
