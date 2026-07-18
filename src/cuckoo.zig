// Cuckoo Filter
//
// Counting Bloom Filter보다 더 높은 공간 효율과 삭제 성능을 제공하는 구조.
// 핵심 아이디어: 각 원소의 fingerprint(짧은 해시)만 저장하고,
// cuckoo hashing으로 두 개의 후보 버킷 중 하나에 배치한다.
//
// 동작:
//   - 각 원소 x에 대해 fingerprint f = hash(x)의 하위 비트
//   - 두 후보 버킷: i1 = hash(x), i2 = i1 XOR hash(f)
//   - 삽입: 둘 중 빈 슬롯에 f 저장. 둘 다 차 있으면 기존 항목을 kick-out
//     하고 다른 버킷으로 옮긴다. (최대 MAX_KICKS 회 시도)
//   - 조회: 두 버킷에 f가 있는지 확인
//   - 삭제: 조회 후 해당 슬롯 비움
//
// 장점:
//   - 삭제가 Bloom보다 정확하다 (fingerprint 기반이라 충돌 시에도 동작)
//   - 공간 효율이 좋다 (원소당 ~1비트 수준까지 압축 가능)
//
// 한계:
//   - 버킷이 꽉 차면 삽입 실패 (load factor 한계)
//   - 동일 원소를 여러 번 삽입하면 삭제 시 하나만 지워짐
//
// 보안 고려:
//   - kick-out 무한 루프 방지를 위해 MAX_KICKS 상한
//   - 버킷 인덱스는 항상 mod bucket_count로 클램프
//   - 할당 실패 시 명시적 에러 반환

const std = @import("std");
const hashing = @import("hashing.zig");

pub const Error = error{
    OutOfMemory,
    InvalidParameter,
    Full, // 버킷이 꽉 차서 더 이상 삽입 불가
};

const FINGERPRINT_BITS = 8;
pub const FINGERPRINT_MAX: u8 = (1 << FINGERPRINT_BITS) - 1;
const BUCKET_SIZE = 4; // 버킷당 슬롯 수 (Cuckoo 필터 표준)
const MAX_KICKS = 500; // 삽입 시 kick-out 최대 횟수

const EMPTY: u8 = 0; // fingerprint 0은 빈 슬롯을 의미 (fingerprint 생성 시 0 피함)

pub const CuckooFilter = struct {
    buckets: []Bucket,
    bucket_count: usize,
    allocator: std.mem.Allocator,
    count: u64, // 저장된 항목 수

    const Bucket = [BUCKET_SIZE]u8;

    pub fn init(allocator: std.mem.Allocator, bucket_count: usize) Error!CuckooFilter {
        if (bucket_count == 0) return Error.InvalidParameter;
        const bs = try allocator.alloc(Bucket, bucket_count);
        for (bs) |*b| b.* = .{ 0, 0, 0, 0 };
        return .{
            .buckets = bs,
            .bucket_count = bucket_count,
            .allocator = allocator,
            .count = 0,
        };
    }

    pub fn deinit(self: *CuckooFilter) void {
        self.allocator.free(self.buckets);
        self.buckets = &[_]Bucket{};
    }

    /// 입력으로부터 fingerprint와 두 후보 버킷 인덱스를 계산한다.
    /// i2 = i1 XOR hash(fingerprint) — 이렇게 하면 f만 봐도
    /// 다른 후보 버킷을 알 수 있어 kick-out이 가능하다.
    fn computeIndices(self: *const CuckooFilter, data: []const u8) struct { idx1: usize, idx2: usize, fp: u8 } {
        const p = hashing.derivePair(data);
        const idx1_raw = p.h1;
        // fingerprint: h1의 하위 8비트. 0이면 1로 보정 (빈 슬롯과 구분)
        var fp: u8 = @intCast(idx1_raw & 0xFF);
        if (fp == EMPTY) fp = 1;
        // fingerprint 자체의 해시로 i2를 파생
        const fp_hash = hashing.hash64(&[_]u8{fp});
        const idx1: usize = @intCast(idx1_raw % self.bucket_count);
        const idx2: usize = @intCast((idx1_raw ^ fp_hash) % self.bucket_count);
        return .{ .idx1 = idx1, .idx2 = idx2, .fp = fp };
    }

    /// 버킷에 빈 슬롯이 있으면 fingerprint를 넣는다. 성공 여부 반환.
    fn tryInsert(self: *CuckooFilter, bucket_idx: usize, fp: u8) bool {
        var b = &self.buckets[bucket_idx];
        for (b, 0..) |slot, i| {
            if (slot == EMPTY) {
                b[i] = fp;
                return true;
            }
        }
        return false;
    }

    /// 버킷에 해당 fingerprint가 있는지 조회
    fn bucketContains(self: *const CuckooFilter, bucket_idx: usize, fp: u8) bool {
        const b = self.buckets[bucket_idx];
        for (b) |slot| {
            if (slot == fp) return true;
        }
        return false;
    }

    /// 버킷에서 fingerprint 하나를 지운다. 성공 여부 반환.
    fn bucketDelete(self: *CuckooFilter, bucket_idx: usize, fp: u8) bool {
        var b = &self.buckets[bucket_idx];
        // 동일 fingerprint가 여러 슬롯에 있을 수 있으므로 첫 번째 것만 지운다
        for (b, 0..) |slot, i| {
            if (slot == fp) {
                b[i] = EMPTY;
                return true;
            }
        }
        return false;
    }

    /// 원소 추가. 버킷이 꽉 차서 MAX_KICKS 안에 자리를 못 찾으면 Full 에러.
    pub fn add(self: *CuckooFilter, data: []const u8) Error!void {
        const r = self.computeIndices(data);
        if (self.tryInsert(r.idx1, r.fp) or self.tryInsert(r.idx2, r.fp)) {
            self.count += 1;
            return;
        }
        // 둘 다 꽉참 — kick-out 시작
        var cur_idx = r.idx1;
        var cur_fp = r.fp;
        var kicks: usize = 0;
        while (kicks < MAX_KICKS) : (kicks += 1) {
            // 무작위 슬롯 하나를 선택해 kick-out
            const slot_idx = @as(usize, @intCast(hashing.hash64(&[_]u8{cur_fp, @intCast(kicks & 0xFF)}) & 0x03));
            const kicked_fp = self.buckets[cur_idx][slot_idx];
            self.buckets[cur_idx][slot_idx] = cur_fp;
            cur_fp = kicked_fp;
            // kicked fingerprint의 다른 후보 버킷으로 이동
            const fp_hash = hashing.hash64(&[_]u8{cur_fp});
            cur_idx = @intCast((@as(u64, @intCast(cur_idx)) ^ fp_hash) % self.bucket_count);
            if (self.tryInsert(cur_idx, cur_fp)) {
                self.count += 1;
                return;
            }
        }
        return Error.Full;
    }

    /// 원소 조회. 두 후보 버킷에 fingerprint가 있으면 true.
    /// 거짓 부정은 없고, 위양률은 fingerprint 비트 수와 load factor로 결정된다.
    pub fn maybeContains(self: *const CuckooFilter, data: []const u8) bool {
        const r = self.computeIndices(data);
        return self.bucketContains(r.idx1, r.fp) or self.bucketContains(r.idx2, r.fp);
    }

    /// 원소 삭제. 조회 후 일치하는 fingerprint 하나를 제거.
    /// 주의: 실제로 add한 적 없는 원소를 삭제하면 다른 원소의 fingerprint가
    /// 우연히 일치해 잘못 지워질 수 있다. (위양률과 같은 확률로)
    pub fn remove(self: *CuckooFilter, data: []const u8) bool {
        const r = self.computeIndices(data);
        if (self.bucketDelete(r.idx1, r.fp)) {
            if (self.count > 0) self.count -= 1;
            return true;
        }
        if (self.bucketDelete(r.idx2, r.fp)) {
            if (self.count > 0) self.count -= 1;
            return true;
        }
        return false;
    }

    /// 현재 load factor (0.0 ~ 1.0)
    pub fn loadFactor(self: *const CuckooFilter) f64 {
        const total_slots: f64 = @floatFromInt(self.bucket_count * BUCKET_SIZE);
        const used: f64 = @floatFromInt(self.count);
        return used / total_slots;
    }
};

test "CuckooFilter: 기본 추가/조회/삭제" {
    var cf = try CuckooFilter.init(std.testing.allocator, 4096);
    defer cf.deinit();
    try cf.add("alpha");
    try cf.add("beta");
    try cf.add("gamma");
    try std.testing.expect(cf.maybeContains("alpha"));
    try std.testing.expect(cf.maybeContains("beta"));
    try std.testing.expect(cf.maybeContains("gamma"));
    try std.testing.expect(!cf.maybeContains("delta"));

    try std.testing.expect(cf.remove("alpha"));
    try std.testing.expect(!cf.maybeContains("alpha"));
}

test "CuckooFilter: 동일 원소 다중 삽입 후 삭제" {
    var cf = try CuckooFilter.init(std.testing.allocator, 1024);
    defer cf.deinit();
    try cf.add("dup");
    try cf.add("dup");
    try cf.add("dup");
    // 하나만 삭제해도 나머지가 있어야 조회 true
    _ = cf.remove("dup");
    try std.testing.expect(cf.maybeContains("dup"));
}
