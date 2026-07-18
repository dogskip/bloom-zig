# bloom-zig

Zig로 구현한 확률적 자료구조 라이브러리. Counting Bloom Filter와 Cuckoo Filter를 제공하며, 둘 다 원소 삭제를 지원한다.

## 왜?

일반 Bloom Filter는 공간 효율이 좋지만 삭제가 안 된다. 이 라이브러리는 두 가지 삭제 가능한 변형을 제공한다:

- **Counting Bloom Filter**: 각 슬롯을 비트 대신 카운터로 둬 추가/삭제 시 +1/-1
- **Cuckoo Filter**: fingerprint 기반으로 cuckoo hashing 사용. 공간 효율이 더 좋음

## 아키텍처

```
src/
├── hashing.zig   — double hashing (h1, h2 파생, k개 해시 생성)
├── bloom.zig     — Counting Bloom Filter (4비트 카운터, 니블 packing)
├── cuckoo.zig    — Cuckoo Filter (8비트 fingerprint, 4슬롯 버킷)
└── main.zig      — CLI 데모/벤치마크
tests/
├── bloom_test.zig
└── cuckoo_test.zig
```

### 해싱 전략

Kirsch-Mitzenmacher의 double hashing을 사용한다. 두 개의 기본 해시 `h1`, `h2`만 있으면 `k`개의 해시를 다음처럼 파생한다:

```
g_i(x) = (h1(x) + i * h2(x)) mod m    (i = 0, 1, ..., k-1)
```

이는 `k`개의 독립 해시 함수를 쓰는 것과 통계적으로 거의 동등하면서, 해시 계산 비용을 `O(k)`가 아닌 `O(1)` + 파생 `O(k)`로 줄인다.

기본 해시는 FNV-1a 64비트 변형을 사용한다. 비암호학적이지만 분포가 균일하고 구현이 단순하다. `h2`는 홀수로 보정해 `mod m`에서 인덱스가 잘 퍼지게 한다.

## 수학적 기반

### Counting Bloom Filter 위양률

`m`개 슬롯, `k`개 해시 함수, `n`개 원소일 때:

```
p ≈ (1 - e^(-kn/m))^k
```

역산으로 원하는 위양률 `p`와 예상 원소 수 `n`에 대한 최적 파라미터:

```
m = -n * ln(p) / (ln(2))^2
k = (m/n) * ln(2)
```

### Cuckoo Filter 위양률

`b`개 슬롯 per 버킷, `f`비트 fingerprint, load factor `α`일 때:

```
p ≈ 2b / 2^f   (근사)
```

`f=8`, `b=4`면 이론적 위양률은 약 3% 수준. 실제로는 load factor와 해시 품질에 따라 달라진다.

## 사용법

### 라이브러리로

```zig
const bloom = @import("bloom.zig");
const cuckoo = @import("cuckoo.zig");

// Counting Bloom Filter
var bf = try bloom.CountingBloom.init(allocator, 65536, 7);
defer bf.deinit();
bf.add("hello");
if (bf.maybeContains("hello")) { ... }
bf.remove("hello");

// Cuckoo Filter
var cf = try cuckoo.CuckooFilter.init(allocator, 4096);
defer cf.deinit();
try cf.add("world");
if (cf.maybeContains("world")) { ... }
_ = cf.remove("world");
```

### CLI

```sh
zig build run -- demo
zig build run -- bench 10000
zig build run -- fp 10000
```

### 테스트

```sh
zig build test
```

## 보안 고려사항

- **비암호학적 해시**: FNV-1a는 속도와 분포 균일성에 초점을 맞춘 비암호학적 해시다. 인증, 서명, 패스워드 저장 등 암호학적 용도로 절대 사용하지 말 것.
- **DoS 저항성**: 입력 길이에 무관하게 일정 시간에 동작하도록 작성했다. 하지만 해시 충돌을 의도적으로 유도하는 공격자에 대해서는 별도의 keyed 해시(SipHash 등) 적용을 권장한다.
- **카운터 오버플로우**: Counting Bloom Filter의 4비트 카운터는 saturating add로 15에서 멈춘다. 오버플로우 시 해당 슬롯은 0이 될 수 없어 삭제 정확도가 떨어지지만, 거짓 부정은 발생하지 않는다. 운영상 안전한 선택이다.
- **kick-out 상한**: Cuckoo Filter는 무한 kick-out 루프를 막기 위해 `MAX_KICKS=500` 상한을 둔다. 초과 시 `Full` 에러를 반환한다.
- **메모리 안전**: Zig의 allocator 모델을 따르며, 할당 실패 시 명시적 에러를 반환한다. `deinit` 누락 시 메모리 누수가 발생하므로 항상 `defer deinit()` 패턴을 사용할 것.
- **동시성**: 이 구조는 thread-safe하지 않다. 다중 스레드 환경에서는 외부 락(RwLock 등)으로 보호할 것.

## 라이선스

MIT. 자세한 내용은 [LICENSE](LICENSE) 참고.
