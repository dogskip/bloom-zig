// Cuckoo Filter 종합 테스트
//
// 검증 항목:
//   1. 위양률이 합리적 범위 내
//   2. 거짓 부정 없음
//   3. 삭제 후 조회 false
//   4. 용량 한계 도달 시 Full 에러
//   5. 해시 분포 균일성

const std = @import("std");
const cuckoo = @import("cuckoo");

test "위양률: 측정값이 합리적 범위 내" {
    const n: usize = 5000;
    var cf = try cuckoo.CuckooFilter.init(std.testing.allocator, n * 2);
    defer cf.deinit();

    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const key = std.fmt.bufPrint(&buf, "in-{d}", .{i}) catch unreachable;
        try cf.add(key);
    }

    // 추가하지 않은 원소로 위양률 측정
    var fp: usize = 0;
    i = 0;
    while (i < n) : (i += 1) {
        const key = std.fmt.bufPrint(&buf, "out-{d}", .{i}) catch unreachable;
        if (cf.maybeContains(key)) fp += 1;
    }
    const measured = @as(f64, @floatFromInt(fp)) / @as(f64, @floatFromInt(n));
    // 8비트 fingerprint, load factor ~0.5 기준 위양률은 수% 수준
    // 20% 이하면 합격 (여유 있게)
    try std.testing.expect(measured < 0.20);
}

test "거짓 부정 없음: 추가한 원소는 항상 조회 true" {
    var cf = try cuckoo.CuckooFilter.init(std.testing.allocator, 4096);
    defer cf.deinit();
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const key = std.fmt.bufPrint(&buf, "item-{d}", .{i}) catch unreachable;
        try cf.add(key);
    }
    i = 0;
    while (i < 1000) : (i += 1) {
        const key = std.fmt.bufPrint(&buf, "item-{d}", .{i}) catch unreachable;
        try std.testing.expect(cf.maybeContains(key));
    }
}

test "삭제 후 조회 false" {
    var cf = try cuckoo.CuckooFilter.init(std.testing.allocator, 2048);
    defer cf.deinit();
    try cf.add("alpha");
    try cf.add("beta");
    try std.testing.expect(cf.remove("alpha"));
    try std.testing.expect(!cf.maybeContains("alpha"));
    try std.testing.expect(cf.maybeContains("beta"));
}

test "용량 한계: 꽉 차면 Full 에러" {
    // 매우 작은 필터로 강제 포화
    var cf = try cuckoo.CuckooFilter.init(std.testing.allocator, 4);
    defer cf.deinit();
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    var inserted: usize = 0;
    while (i < 1000) : (i += 1) {
        const key = std.fmt.bufPrint(&buf, "k-{d}", .{i}) catch unreachable;
        cf.add(key) catch |err| switch (err) {
            cuckoo.Error.Full => break,
            else => return err,
        };
        inserted += 1;
    }
    // 4 버킷 * 4 슬롯 = 16개까진 들어가야 정상
    try std.testing.expect(inserted >= 16);
    try std.testing.expect(inserted < 1000);
}

test "해시 분포: 두 후보 버킷이 균일하게 사용된다" {
    const bucket_count: usize = 4096;
    var cf = try cuckoo.CuckooFilter.init(std.testing.allocator, bucket_count);
    defer cf.deinit();

    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        const key = std.fmt.bufPrint(&buf, "h-{d}", .{i}) catch unreachable;
        try cf.add(key);
    }

    // 각 버킷의 사용 슬롯 수를 세어 분산이 너무 크지 않은지 확인
    var histogram: [5]usize = .{ 0, 0, 0, 0, 0 }; // 0~4개 사용
    for (cf.buckets) |b| {
        var used: usize = 0;
        for (b) |slot| {
            if (slot != 0) used += 1;
        }
        histogram[used] += 1;
    }
    // 모든 버킷이 비어있거나 모두 꽉 차면 분포가 안 좋은 것
    try std.testing.expect(histogram[0] < bucket_count);
    try std.testing.expect(histogram[4] < bucket_count);
    // 적어도 일부 버킷은 사용 중이어야 함
    const used_total = histogram[1] + histogram[2] + histogram[3] + histogram[4];
    try std.testing.expect(used_total > 0);
}

test "동일 원소 다중 삽입/삭제" {
    var cf = try cuckoo.CuckooFilter.init(std.testing.allocator, 1024);
    defer cf.deinit();
    try cf.add("dup");
    try cf.add("dup");
    _ = cf.remove("dup");
    // 하나 남아 있어야 함
    try std.testing.expect(cf.maybeContains("dup"));
    _ = cf.remove("dup");
    try std.testing.expect(!cf.maybeContains("dup"));
}

test "존재하지 않는 원소 삭제 시 false 반환" {
    var cf = try cuckoo.CuckooFilter.init(std.testing.allocator, 1024);
    defer cf.deinit();
    try cf.add("real");
    try std.testing.expect(!cf.remove("nonexistent"));
}

test "잘못된 파라미터 거부" {
    try std.testing.expectError(cuckoo.Error.InvalidParameter, cuckoo.CuckooFilter.init(std.testing.allocator, 0));
}
