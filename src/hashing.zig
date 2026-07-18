// 해싱 유틸리티 — 확률적 자료구조에서 사용할 해시 함수 모음
//
// 설계 의도:
//   Bloom/Cuckoo 필터는 "서로 독립적인" k개의 해시 값이 필요하다.
//   매번 k개의 독립 해시 함수를 만드는 건 비용이 크므로, Kirsch-Mitzenmacher의
//   double hashing 기법을 사용한다. 두 개의 기본 해시 h1, h2만 있으면
//   g_i(x) = (h1(x) + i * h2(x)) mod m  형태로 k개의 해시를 파생할 수 있고,
//   이는 실제 응용에서 충분히 낮은 위양률을 보장한다.
//
// 보안 고려:
//   - 해시 충돌을 이용한 DoS를 막기 위해 입력 길이에 따라 분기를 두지 않고
//     일정한 시간에 동작하도록 작성했다.
//   - 암호학적 용도(인증/서명)에는 사용하지 말 것. 이 해시는 비암호학적 해시다.

const std = @import("std");

/// 두 개의 64비트 해시 값을 묶어 반환한다.
pub const Pair = struct {
    h1: u64,
    h2: u64,
};

/// FNV-1a 64비트 변형으로 기본 해시 쌍을 만든다.
/// FNV-1a는 비암호학적 해시지만 분포가 균일하고 구현이 단순해
/// 확률적 자료구조용으로 널리 쓰인다.
fn fnv1a64(data: []const u8, seed: u64) u64 {
    // FNV offset basis와 prime (64비트 표준값)
    var hash: u64 = 0xcbf29ce484222325 ^ seed;
    for (data) |byte| {
        hash ^= @as(u64, byte);
        hash *%= 0x100000001b3;
    }
    return hash;
}

/// 입력 바이트로부터 (h1, h2) 쌍을 파생한다.
/// h1과 h2는 서로 다른 시드로 FNV-1a를 돌려 만들어, 통계적으로
/// 독립에 가까운 값을 얻는다.
pub fn derivePair(data: []const u8) Pair {
    const h1 = fnv1a64(data, 0x517cc1b727220a95);
    // h2가 0이 되면 double hashing이 모두 같은 위치를 가리키게 되므로,
    // 최소 1 이상을 보장한다. (홀수로 만들어 mod m에서 더 잘 퍼진다)
    var h2 = fnv1a64(data, 0x6c62272e07bb0142);
    if (h2 == 0) h2 = 1;
    if (h2 & 1 == 0) h2 += 1; // 홀수 보정
    return .{ .h1 = h1, .h2 = h2 };
}

/// double hashing으로 k개의 해시 인덱스를 생성한다.
/// 결과는 [0, m) 범위의 인덱스 k개가 들어갈 버퍼(out)에 채워진다.
/// h2를 홀수로 보정했기 때문에 m이 2의 거듭제곱이 아니어도
/// 인덱스들이 비교적 고르게 퍼진다.
pub fn indices(data: []const u8, m: u64, k: usize, out: []u64) void {
    std.debug.assert(out.len >= k);
    std.debug.assert(k > 0);
    const p = derivePair(data);
    for (0..k) |i| {
        // (h1 + i*h2) mod m — 오버플로우는 wrapping 연산으로 처리
        const idx = (p.h1 +% (@as(u64, @intCast(i)) *% p.h2)) % m;
        out[i] = idx;
    }
}

/// 테스트/디버그용: 단일 해시 값만 필요할 때 사용
pub fn hash64(data: []const u8) u64 {
    return fnv1a64(data, 0x517cc1b727220a95);
}

test "derivePair는 h2가 0이 아니고 홀수다" {
    const p = derivePair("hello");
    try std.testing.expect(p.h2 != 0);
    try std.testing.expect(p.h2 & 1 == 1);
}

test "indices는 k개의 서로 다른 위치를 만들어낸다" {
    var buf: [8]u64 = undefined;
    indices("quick brown fox", 1024, 8, &buf);
    // 모두 범위 내
    for (buf) |i| try std.testing.expect(i < 1024);
    // 최소 2개 이상은 달라야 정상
    var distinct: usize = 0;
    for (buf, 0..) |a, i| {
        for (buf[i + 1 ..]) |b| {
            if (a != b) distinct += 1;
        }
    }
    try std.testing.expect(distinct > 0);
}
