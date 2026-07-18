// bloom-zig CLI 데모
//
// Counting Bloom Filter와 Cuckoo Filter의 동작을 보여주는 간단한 CLI.
// 실제 라이브러리 사용법을 익히기 위한 참고용 예제다.
//
// 사용법:
//   bloom-zig demo              — 기본 데모 실행
//   bloom-zig bench <n>         — n개 원소로 벤치마크
//   bloom-zig fp <n>            — n개 추가 후 위양률 측정

const std = @import("std");
const bloom = @import("bloom.zig");
const cuckoo = @import("cuckoo.zig");

const Allocator = std.mem.Allocator;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // 프로그램 이름

    const cmd = args.next() orelse "demo";

    if (std.mem.eql(u8, cmd, "demo")) {
        try runDemo(allocator);
    } else if (std.mem.eql(u8, cmd, "bench")) {
        const n_str = args.next() orelse "10000";
        const n = try std.fmt.parseInt(usize, n_str, 10);
        try runBench(allocator, n);
    } else if (std.mem.eql(u8, cmd, "fp")) {
        const n_str = args.next() orelse "10000";
        const n = try std.fmt.parseInt(usize, n_str, 10);
        try runFalsePositive(allocator, n);
    } else {
        std.debug.print("알 수 없는 명령: {s}\n", .{cmd});
        std.debug.print("사용 가능: demo | bench <n> | fp <n>\n", .{});
        std.process.exit(1);
    }
}

/// 기본 데모: 두 필터의 추가/조회/삭제 흐름을 보여준다.
fn runDemo(allocator: Allocator) !void {
    std.debug.print("== bloom-zig 데모 ==\n", .{});

    // Counting Bloom Filter
    var bf = try bloom.CountingBloom.init(allocator, 8192, 7);
    defer bf.deinit();
    std.debug.print("\n[Counting Bloom Filter] m=8192, k=7\n", .{});
    const fruits = [_][]const u8{ "사과", "배", "포도", "귤", "수박" };
    for (fruits) |f| bf.add(f);
    std.debug.print("  추가: {s}\n", .{fruits});
    std.debug.print("  '사과' 조회: {}\n", .{bf.maybeContains("사과")});
    std.debug.print("  '바나나' 조회: {} (위양이어야 함)\n", .{bf.maybeContains("바나나")});
    bf.remove("사과");
    std.debug.print("  '사과' 삭제 후 조회: {}\n", .{bf.maybeContains("사과")});
    std.debug.print("  추정 위양률: {d:.4}\n", .{bf.estimatedFalsePositiveRate()});

    // Cuckoo Filter
    var cf = try cuckoo.CuckooFilter.init(allocator, 4096);
    defer cf.deinit();
    std.debug.print("\n[Cuckoo Filter] buckets=4096, slot/bucket=4\n", .{});
    for (fruits) |f| try cf.add(f);
    std.debug.print("  추가: {s}\n", .{fruits});
    std.debug.print("  '배' 조회: {}\n", .{cf.maybeContains("배")});
    std.debug.print("  '체리' 조회: {} (위양이어야 함)\n", .{cf.maybeContains("체리")});
    _ = cf.remove("배");
    std.debug.print("  '배' 삭제 후 조회: {}\n", .{cf.maybeContains("배")});
    std.debug.print("  load factor: {d:.3}\n", .{cf.loadFactor()});
}

/// 벤치마크: n개 원소 삽입/조회 시간 측정
fn runBench(allocator: Allocator, n: usize) !void {
    std.debug.print("== 벤치마크: {d}개 원소 ==\n", .{n});

    var bf = try bloom.CountingBloom.init(allocator, @as(u64, @intCast(n)) * 10, 7);
    defer bf.deinit();
    var cf = try cuckoo.CuckooFilter.init(allocator, n * 2);
    defer cf.deinit();

    var prng = std.Random.DefaultPrng.init(42);
    const rng = prng.random();

    var buf: [16]u8 = undefined;

    const bf_start = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const key = std.fmt.bufPrint(&buf, "k{d}", .{rng.int(u64)}) catch unreachable;
        bf.add(key);
    }
    const bf_end = std.time.nanoTimestamp();
    std.debug.print("  Bloom 추가: {d} ms\n", .{@divFloor(bf_end - bf_start, 1_000_000)});

    const cf_start = std.time.nanoTimestamp();
    i = 0;
    while (i < n) : (i += 1) {
        const key = std.fmt.bufPrint(&buf, "k{d}", .{rng.int(u64)}) catch unreachable;
        try cf.add(key);
    }
    const cf_end = std.time.nanoTimestamp();
    std.debug.print("  Cuckoo 추가: {d} ms\n", .{@divFloor(cf_end - cf_start, 1_000_000)});
    std.debug.print("  Cuckoo load factor: {d:.3}\n", .{cf.loadFactor()});
}

/// 위양률 측정: n개 추가 후, 추가하지 않은 원소들로 조회해 위양률 계산
fn runFalsePositive(allocator: Allocator, n: usize) !void {
    std.debug.print("== 위양률 측정: {d}개 원소 ==\n", .{n});

    var bf = try bloom.CountingBloom.init(allocator, @as(u64, @intCast(n)) * 10, 7);
    defer bf.deinit();

    // n개 추가
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const key = std.fmt.bufPrint(&buf, "in-{d}", .{i}) catch unreachable;
        bf.add(key);
    }

    // 추가하지 않은 원소 n개로 조회
    var false_positives: usize = 0;
    i = 0;
    while (i < n) : (i += 1) {
        const key = std.fmt.bufPrint(&buf, "out-{d}", .{i}) catch unreachable;
        if (bf.maybeContains(key)) false_positives += 1;
    }
    const measured = @as(f64, @floatFromInt(false_positives)) / @as(f64, @floatFromInt(n));
    std.debug.print("  측정 위양률: {d:.4} ({d}/{d})\n", .{ measured, false_positives, n });
    std.debug.print("  추정 위양률: {d:.4}\n", .{bf.estimatedFalsePositiveRate()});
}
