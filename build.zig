const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 공용 라이브러리 모듈 — src/bloom.zig가 src/hashing.zig를,
    // src/cuckoo.zig도 src/hashing.zig를 import한다.
    // 테스트에서도 같은 모듈을 재사용하도록 모듈 그래프를 구성한다.

    // 실행 파일 (CLI 데모)
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "bloom-zig",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // 실행 명령
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "CLI 데모 실행");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "모든 테스트 실행");

    // 단위 테스트 (src 내부) — 각 파일이 자체적으로 @import("hashing.zig") 등을
    // 해결하므로 root_source_file만 지정하면 된다.
    const src_tests = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "hashing", .path = "src/hashing.zig" },
        .{ .name = "bloom", .path = "src/bloom.zig" },
        .{ .name = "cuckoo", .path = "src/cuckoo.zig" },
    };
    for (src_tests) |t| {
        const mod = b.createModule(.{
            .root_source_file = b.path(t.path),
            .target = target,
            .optimize = optimize,
        });
        const unit = b.addTest(.{
            .name = t.name,
            .root_module = mod,
        });
        const run_unit = b.addRunArtifact(unit);
        test_step.dependOn(&run_unit.step);
    }

    // 통합 테스트 (tests/ 디렉토리)
    // tests/*.zig는 src/*.zig를 import해야 하므로, src를 모듈로 노출한다.
    const bloom_mod = b.createModule(.{
        .root_source_file = b.path("src/bloom.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cuckoo_mod = b.createModule(.{
        .root_source_file = b.path("src/cuckoo.zig"),
        .target = target,
        .optimize = optimize,
    });
    const hashing_mod = b.createModule(.{
        .root_source_file = b.path("src/hashing.zig"),
        .target = target,
        .optimize = optimize,
    });

    const integration_tests = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "bloom_test", .path = "tests/bloom_test.zig" },
        .{ .name = "cuckoo_test", .path = "tests/cuckoo_test.zig" },
    };
    for (integration_tests) |t| {
        const mod = b.createModule(.{
            .root_source_file = b.path(t.path),
            .target = target,
            .optimize = optimize,
        });
        // tests/bloom_test.zig는 @import("bloom")로, tests/cuckoo_test.zig는
        // @import("cuckoo")로 src를 참조한다.
        mod.addImport("bloom", bloom_mod);
        mod.addImport("cuckoo", cuckoo_mod);
        mod.addImport("hashing", hashing_mod);
        const unit = b.addTest(.{
            .name = t.name,
            .root_module = mod,
        });
        const run_unit = b.addRunArtifact(unit);
        test_step.dependOn(&run_unit.step);
    }
}
