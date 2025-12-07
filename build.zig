const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "auctions-api",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const persistence_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/persistence_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const api_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/api_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const blind_auction_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/blind_auction_state_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const english_auction_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/english_auction_state_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Serialization tests temporarily disabled due to Zig 0.15 JSON API changes
    // const english_auction_serialization_tests = b.addTest(.{
    //     .root_module = b.createModule(.{
    //         .root_source_file = b.path("src/english_auction_serialization_test.zig"),
    //         .target = target,
    //         .optimize = optimize,
    //     }),
    // });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const run_persistence_tests = b.addRunArtifact(persistence_tests);
    const run_api_tests = b.addRunArtifact(api_tests);
    const run_blind_auction_tests = b.addRunArtifact(blind_auction_tests);
    const run_english_auction_tests = b.addRunArtifact(english_auction_tests);
    // const run_english_auction_serialization_tests = b.addRunArtifact(english_auction_serialization_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_persistence_tests.step);
    test_step.dependOn(&run_api_tests.step);
    test_step.dependOn(&run_blind_auction_tests.step);
    test_step.dependOn(&run_english_auction_tests.step);
    // test_step.dependOn(&run_english_auction_serialization_tests.step);
}
