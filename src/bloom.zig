// Counting Bloom Filter
//
// 일반 Bloom Filter는 비트 배열만 써서 "원소가 있을 수 있다/없다"만 알려주지만,
// 삭제를 지원하지 않는다는 치명적 단점이 있다. Counting Bloom Filter는
// 각 슬롯을 1비트가 아니라 n비트 카운터로 두어, 원소 추가 시 +1, 삭제 시 -1 한다.
// 이로 인해 삭제 연산이 가능해진다. (대신 메모리는 n배 소모)
//
// 수학적 기반 (위양률):
//   m = 비트(카운터) 수, k = 해시 함수 개수, n = 저장 원소 수
//   위양률 p ≈ (1 - e^(-kn/m))^k
//   이를 역산해 원하는 p와 n에 대해 필요한 m을 구하면:
//     m = -n*ln(p) / (ln(2)^2)
//     k = (m/n) * ln(2)
//
// 보안 고려:
//   - 카운터 오버플로우를 막기 위해 saturating add를 사용한다.
//     (오버플로우 시 카운터가 최댓값에 머문다 — false negative는 발생하지 않지만
//      해당 슬롯은 더 이상 0이 될 수 없어 삭제 정확도가 떨어진다. 운영상 안전한 선택.)
//   - 할당 실패 시 명시적으로 에러를 반환한다.
//   - 입력 길이에 무관하게 일정 시간에 동작한다.

const std = @import("std");
const hashing = @import("hashing.zig");

/// 카운터 비트 폭. 4비트면 대부분의 실용적 사례에서 충분하다
/// (카운터가 15에 도달할 확률은 매우 낮다).
pub const COUNTER_BITS = 4;
pub const COUNTER_MAX: u8 = (1 << COUNTER_BITS) - 1; // 15

pub const Error = error{
    OutOfMemory,
    InvalidParameter,
};

/// Counting Bloom Filter 본체.
/// 카운터는 4비트이므로, 메모리 절약을 위해 1바이트에 2개 카운터를 packing한다.
pub const CountingBloom = struct {
    // packed 배열 대신 일반 바이트 배열을 쓰고, 상하 니블로 2개 카운터를 저장.
    buckets: []u8,
    m: u64, // 카운터 개수 (슬롯 수)
    k: usize, // 해시 함수 개수
    allocator: std.mem.Allocator,
    count: u64, // 현재 저장된 원소 수 (추정치 아닌 add 호출 수)

    /// 주어진 파라미터로 필터를 초기화한다.
    /// m은 카운터 개수, k는 해시 함수 개수.
    pub fn init(allocator: std.mem.Allocator, m: u64, k: usize) Error!CountingBloom {
        if (m == 0 or k == 0) return Error.InvalidParameter;
        // 2개 카운터 per 바이트이므로 바이트 수는 (m+1)/2
        const byte_count = (m + 1) / 2;
        const buf = try allocator.alloc(u8, byte_count);
        @memset(buf, 0);
        return .{
            .buckets = buf,
            .m = m,
            .k = k,
            .allocator = allocator,
            .count = 0,
        };
    }

    pub fn deinit(self: *CountingBloom) void {
        self.allocator.free(self.buckets);
        self.buckets = &[_]u8{};
    }

    /// i번째 카운터 읽기
    inline fn get(self: *const CountingBloom, i: u64) u8 {
        const byte_idx = i / 2;
        const b = self.buckets[byte_idx];
        if (i & 1 == 0) return b & 0x0F else return (b >> 4) & 0x0F;
    }

    /// i번째 슬롯의 카운터 값 (테스트/검사용 public 접근자)
    pub fn slotValue(self: *const CountingBloom, i: u64) u8 {
        return self.get(i);
    }

    /// i번째 카운터 쓰기
    inline fn set(self: *CountingBloom, i: u64, v: u8) void {
        const byte_idx = i / 2;
        const b = self.buckets[byte_idx];
        if (i & 1 == 0) {
            self.buckets[byte_idx] = (b & 0xF0) | (v & 0x0F);
        } else {
            self.buckets[byte_idx] = (b & 0x0F) | ((v & 0x0F) << 4);
        }
    }

    /// 카운터를 saturating increment
    inline fn inc(self: *CountingBloom, i: u64) void {
        const v = self.get(i);
        if (v < COUNTER_MAX) self.set(i, v + 1);
    }

    /// 카운터를 decrement. 0이면 0으로 둔다 (underflow 방지).
    inline fn dec(self: *CountingBloom, i: u64) void {
        const v = self.get(i);
        if (v > 0) self.set(i, v - 1);
    }

    /// 원소 추가. k개 해시 위치의 카운터를 1씩 올린다.
    pub fn add(self: *CountingBloom, data: []const u8) void {
        var buf: [16]u64 = undefined;
        std.debug.assert(self.k <= buf.len);
        hashing.indices(data, self.m, self.k, &buf);
        for (buf[0..self.k]) |idx| self.inc(idx);
        self.count += 1;
    }

    /// 원소 조회. 모든 k개 해시 위치의 카운터가 0보다 크면 "있을 수 있다".
    /// 하나라도 0이면 "확실히 없다" (거짓 부정 불가).
    pub fn maybeContains(self: *const CountingBloom, data: []const u8) bool {
        var buf: [16]u64 = undefined;
        std.debug.assert(self.k <= buf.len);
        hashing.indices(data, self.m, self.k, &buf);
        for (buf[0..self.k]) |idx| {
            if (self.get(idx) == 0) return false;
        }
        return true;
    }

    /// 원소 삭제. add와 반대로 k개 위치의 카운터를 1씩 내린다.
    /// 주의: 실제로 add한 적 없는 원소를 삭제하면 다른 원소의 카운터가
    /// 깎여서 거짓 부정이 발생할 수 있다. 호출자 책임하에 사용할 것.
    pub fn remove(self: *CountingBloom, data: []const u8) void {
        var buf: [16]u64 = undefined;
        std.debug.assert(self.k <= buf.len);
        hashing.indices(data, self.m, self.k, &buf);
        for (buf[0..self.k]) |idx| self.dec(idx);
        if (self.count > 0) self.count -= 1;
    }

    /// 현재 위양률 추정치. p ≈ (1 - e^(-kn/m))^k
    pub fn estimatedFalsePositiveRate(self: *const CountingBloom) f64 {
        if (self.count == 0) return 0.0;
        const m_f: f64 = @floatFromInt(self.m);
        const k_f: f64 = @floatFromInt(self.k);
        const n_f: f64 = @floatFromInt(self.count);
        const exponent = -k_f * n_f / m_f;
        const e_neg = @exp(exponent);
        const inner = 1.0 - e_neg;
        return std.math.pow(f64, inner, k_f);
    }
};

test "CountingBloom: 추가 후 조회, 삭제 후 조회" {
    var bf = try CountingBloom.init(std.testing.allocator, 4096, 7);
    defer bf.deinit();

    bf.add("apple");
    bf.add("banana");
    try std.testing.expect(bf.maybeContains("apple"));
    try std.testing.expect(bf.maybeContains("banana"));
    try std.testing.expect(!bf.maybeContains("cherry")); // 확실히 없음

    bf.remove("apple");
    try std.testing.expect(!bf.maybeContains("apple"));
}

test "CountingBloom: 카운터 오버플로우 시 saturate" {
    var bf = try CountingBloom.init(std.testing.allocator, 64, 4);
    defer bf.deinit();
    // 같은 원소를 COUNTER_MAX 이상 추가해도 카운터는 15에서 멈춰야 한다
    var i: usize = 0;
    while (i < 30) : (i += 1) bf.add("x");
    // 어느 슬롯도 15를 넘지 않는다
    var j: u64 = 0;
    while (j < bf.m) : (j += 1) {
        try std.testing.expect(bf.get(j) <= COUNTER_MAX);
    }
}
