// Counting Bloom Filter 종합 테스트
//
// 다음을 검증한다:
//   1. 위양률이 이론적 추정치 근처에 수렴하는가
//   2. 거짓 부정이 없는가 (삭제하지 않은 원소는 항상 조회 true)
//   3. 삭제 후 조회가 false가 되는가
//   4. 용량 한계에서도 동작하는가
//   5. 해시 분포가 균일한가

const std = @import("std");
const bloom = @import("bloom");

test "위양률: 측정값이 추정치 근처에 수렴" {
    const n: usize = 5000;
    const m: u64 = 65536;
    const k: usize = 7;
    var bf = try bloom.CountingBloom.init(std.testing.allocator, m, k);
    defer bf.deinit();

    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const key = std.fmt.bufPrint(&buf, "in-{d}", .{i}) catch unreachable;
        bf.add(key);
    }

    // 추가하지 않은 원소로 위양률 측정
    var fp: usize = 0;
    i = 0;
    while (i < n) : (i += 1) {
        const key = std.fmt.bufPrint(&buf, "out-{d}", .{i}) catch unreachable;
        if (bf.maybeContains(key)) fp += 1;
    }
    const measured = @as(f64, @floatFromInt(fp)) / @as(f64, @floatFromInt(n));
    const estimated = bf.estimatedFalsePositiveRate();
    // 측정값이 추정치의 3배 이내면 합격 (확률적 검증이라 여유를 둠)
    try std.testing.expect(measured < estimated * 3.0 + 0.01);
}

test "거짓 부정 없음: 추가한 원소는 항상 조회 true" {
    var bf = try bloom.CountingBloom.init(std.testing.allocator, 8192, 5);
    defer bf.deinit();
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const key = std.fmt.bufPrint(&buf, "item-{d}", .{i}) catch unreachable;
        bf.add(key);
    }
    i = 0;
    while (i < 1000) : (i += 1) {
        const key = std.fmt.bufPrint(&buf, "item-{d}", .{i}) catch unreachable;
        try std.testing.expect(bf.maybeContains(key));
    }
}

test "삭제 후 조회 false" {
    var bf = try bloom.CountingBloom.init(std.testing.allocator, 4096, 6);
    defer bf.deinit();
    bf.add("hello");
    bf.add("world");
    try std.testing.expect(bf.maybeContains("hello"));
    bf.remove("hello");
    try std.testing.expect(!bf.maybeContains("hello"));
    // world는 여전히 있어야 함
    try std.testing.expect(bf.maybeContains("world"));
}

test "용량 한계: 설계 용량 초과해도 크래시 없음" {
    // m=512, k=4로 작게 만들고 많이 넣어도 안전해야 한다
    var bf = try bloom.CountingBloom.init(std.testing.allocator, 512, 4);
    defer bf.deinit();
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        const key = std.fmt.bufPrint(&buf, "x-{d}", .{i}) catch unreachable;
        bf.add(key);
    }
    // 카운터가 saturate 되었어도 크래시 없이 동작
    try std.testing.expect(bf.count == 10000);
}

test "해시 분포: 인덱스가 균일하게 퍼진다" {
    // m개 슬롯에 k개 해시로 n개 원소를 넣었을 때,
    // 각 슬롯에 저장된 카운터 합이 극단적으로 치우치지 않아야 한다.
    const m: u64 = 1024;
    const k: usize = 5;
    const n: usize = 5000;
    var bf = try bloom.CountingBloom.init(std.testing.allocator, m, k);
    defer bf.deinit();

    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const key = std.fmt.bufPrint(&buf, "d-{d}", .{i}) catch unreachable;
        bf.add(key);
    }

    // 모든 슬롯의 카운터 합 = n * k (saturate로 인해 약간 클 수 없고 같거나 작음)
    var total: u64 = 0;
    var j: u64 = 0;
    while (j < m) : (j += 1) total += bf.slotValue(j);
    try std.testing.expect(total <= @as(u64, @intCast(n * k)));
    // 최소한 대부분의 슬롯은 0이 아니어야 한다 (분포가 퍼져 있음)
    var nonzero: u64 = 0;
    j = 0;
    while (j < m) : (j += 1) {
        if (bf.slotValue(j) > 0) nonzero += 1;
    }
    // 이론상 (1 - e^(-kn/m)) 비율의 슬롯이 채워져야 함
    const expected_ratio = 1.0 - @exp(-@as(f64, @floatFromInt(k * n)) / @as(f64, @floatFromInt(m)));
    const actual_ratio = @as(f64, @floatFromInt(nonzero)) / @as(f64, @floatFromInt(m));
    // 20% 이내 차이면 합격
    try std.testing.expect(@abs(actual_ratio - expected_ratio) < 0.2);
}

test "동일 원소 다중 추가 후 다중 삭제" {
    var bf = try bloom.CountingBloom.init(std.testing.allocator, 2048, 5);
    defer bf.deinit();
    bf.add("dup");
    bf.add("dup");
    bf.add("dup");
    // 3번 추가했으니 2번 삭제해도 여전히 있어야 함
    bf.remove("dup");
    bf.remove("dup");
    try std.testing.expect(bf.maybeContains("dup"));
    // 3번째 삭제하면 없어져야 함
    bf.remove("dup");
    try std.testing.expect(!bf.maybeContains("dup"));
}

test "잘못된 파라미터 거부" {
    try std.testing.expectError(bloom.Error.InvalidParameter, bloom.CountingBloom.init(std.testing.allocator, 0, 5));
    try std.testing.expectError(bloom.Error.InvalidParameter, bloom.CountingBloom.init(std.testing.allocator, 1024, 0));
}
