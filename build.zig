const std = @import("std");
const parser_sources = @import("src/sql/antlr/sources.zig");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    const openssl_lib_dir = b.option(
        []const u8,
        "openssl-lib-dir",
        "Directory containing OpenSSL libraries used by the static MariaDB client",
    ) orelse switch (target.result.os.tag) {
        .macos => @as(?[]const u8, "/opt/homebrew/lib"),
        else => @as(?[]const u8, null),
    };
    // The OpenSSL root holds lib/ and include/. Headers default to the root of
    // -Dopenssl-lib-dir, so cmake compiles MariaDB against the OpenSSL that thysql links.
    const openssl_root: ?[]const u8 = if (openssl_lib_dir) |lib_dir|
        std.fs.path.dirname(lib_dir) orelse "."
    else
        null;
    const openssl_include_dir = b.option(
        []const u8,
        "openssl-include-dir",
        "Directory containing OpenSSL headers (default: include/ next to -Dopenssl-lib-dir)",
    ) orelse @as(?[]const u8, if (openssl_root) |root| b.pathJoin(&.{ root, "include" }) else null);
    const zstd_lib_dir = b.option(
        []const u8,
        "zstd-lib-dir",
        "Directory containing zstd libraries (default: the library search path)",
    );
    // Links ssl, crypto and zstd statically, so the binary needs no Homebrew libraries.
    // Kerberos is still the system library.
    const static_deps = b.option(
        bool,
        "static-deps",
        "Link OpenSSL and zstd statically (default: false)",
    ) orelse false;
    // The version comes from build.zig.zon unless -Dversion overrides it. The commit is
    // optional and empty by default. Both reach the code as the build_options module.
    const zon_version: []const u8 = @import("build.zig.zon").version;
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", b.option(
        []const u8,
        "version",
        "Version to report with --version (default: build.zig.zon)",
    ) orelse zon_version);
    build_options.addOption([]const u8, "commit", b.option(
        []const u8,
        "commit",
        "Commit to report with --version, such as a short SHA (default: none)",
    ) orelse "");
    const mariadb = addMariaDbConnectorC(b, .{
        .openssl_root = openssl_root,
        .openssl_include_dir = openssl_include_dir,
        .zstd_lib_dir = zstd_lib_dir,
        .static_deps = static_deps,
    });
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    // The ANTLR4 runtime, antlr4-c3, the MySQL base classes and the generated MySQL parser,
    // with the C shim (src/sql/antlr/shim.h) that src/sql/parser.zig calls.
    const parser_lib = addMysqlParserLibrary(b, target, optimize);

    const mod = b.addModule("thysql", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
    });

    // Vendored readline library (see lib/replete). Built from its own sources,
    // not from replete's build.zig, which does not build under Zig 0.17.
    const replete_mod = b.createModule(.{
        .root_source_file = b.path("lib/replete/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mysql_c_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/mysql_c.h"),
        .target = target,
        .optimize = optimize,
    });
    mysql_c_translate.addIncludePath(mariadb.generated_include_dir);
    mysql_c_translate.addIncludePath(b.path("deps/mariadb-connector-c/include"));
    const mysql_c = mysql_c_translate.createModule();

    const parser_shim_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/sql/antlr/shim.h"),
        .target = target,
        .optimize = optimize,
    });
    const parser_shim_c = parser_shim_translate.createModule();

    mod.addImport("mysql_c", mysql_c);
    mod.addImport("mysql_parser_c", parser_shim_c);
    mod.addImport("replete", replete_mod);
    mod.addImport("build_options", build_options.createModule());

    mod.link_libc = true;
    mod.link_libcpp = true;
    mod.linkLibrary(parser_lib);
    mod.addObjectFile(mariadb.static_library);
    linkMariaDbSystemLibraries(mod, target, .{
        .openssl_lib_dir = openssl_lib_dir,
        .zstd_lib_dir = zstd_lib_dir,
        .static_deps = static_deps,
    });

    // The macOS keychain: a C shim over Security.framework, behind src/keychain.zig. Only
    // macOS targets compile it and link the frameworks.
    if (target.result.os.tag == .macos) {
        const keychain_translate = b.addTranslateC(.{
            .root_source_file = b.path("src/keychain/keychain.h"),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("keychain_c", keychain_translate.createModule());
        mod.addCSourceFile(.{ .file = b.path("src/keychain/keychain_darwin.c") });
        mod.linkFramework("Security", .{});
        mod.linkFramework("CoreFoundation", .{});
    }

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "thysql",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "thysql" is the name you will use in your source code to
                // import this module (e.g. `@import("thysql")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "thysql", .module = mod },
            },
        }),
    });

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    run_cmd.addPassthruArgs();

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // Tests for the vendored replete readline library.
    const replete_tests = b.addTest(.{
        .root_module = replete_mod,
    });
    const run_replete_tests = b.addRunArtifact(replete_tests);

    // Installed so that it stays compiling on its own, as well as linked into the module.
    b.installArtifact(parser_lib);

    // Regenerates src/sql/generated from src/sql/grammar. Needs Java; normal
    // builds use the committed sources and do not run this step.
    const gen_parser = b.addSystemCommand(&.{ "sh", "tools/gen_parser.sh" });
    const gen_parser_step = b.step("gen-parser", "Regenerate the MySQL parser sources (needs Java)");
    gen_parser_step.dependOn(&gen_parser.step);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_replete_tests.step);

    // C++ smoke test for the MySQL parser: parses a valid and an invalid query.
    const parser_smoke = b.addExecutable(.{
        .name = "mysql_parser_smoke_test",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libcpp = true,
        }),
    });
    parser_smoke.root_module.addCSourceFiles(.{
        .root = b.path("src/sql/antlr"),
        .files = &.{"smoke_test.cpp"},
        .flags = parser_cxx_flags,
    });
    addParserIncludePaths(parser_smoke.root_module, b);
    parser_smoke.root_module.linkLibrary(parser_lib);
    const run_parser_smoke = b.addRunArtifact(parser_smoke);
    test_step.dependOn(&run_parser_smoke.step);

    // End-to-end tests run the installed binary against Docker containers
    // (MySQL 8.4 and MariaDB 11.4). Extra arguments go to the Python runner,
    // e.g. `zig build e2e -- -k select`.
    const e2e_run = b.addSystemCommand(&.{ "python3", "tests/e2e/run.py" });
    e2e_run.addArtifactArg(exe);
    e2e_run.addPassthruArgs();
    e2e_run.step.dependOn(b.getInstallStep());
    const e2e_step = b.step("e2e", "Run end-to-end tests against MySQL 8.4 and MariaDB 11.4 (needs Docker)");
    e2e_step.dependOn(&e2e_run.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}

const MariaDbConnectorC = struct {
    generated_include_dir: std.Build.LazyPath,
    static_library: std.Build.LazyPath,
};

const MariaDbOptions = struct {
    openssl_root: ?[]const u8,
    openssl_include_dir: ?[]const u8,
    zstd_lib_dir: ?[]const u8,
    static_deps: bool,
};

fn addMariaDbConnectorC(b: *std.Build, opts: MariaDbOptions) MariaDbConnectorC {
    const build_cmd = b.addSystemCommand(&.{"sh"});
    build_cmd.addFileArg(b.path("tools/build_mariadb_static.sh"));
    build_cmd.addDirectoryArg(b.path("deps/mariadb-connector-c"));
    const build_dir = build_cmd.addOutputDirectoryArg("mariadb-connector-c");

    // The script passes these to cmake. They are arguments, not environment, so
    // changing an option invalidates the cache.
    if (opts.openssl_root) |root| build_cmd.addArg(b.fmt("-DOPENSSL_ROOT_DIR={s}", .{root}));
    if (opts.openssl_include_dir) |dir| build_cmd.addArg(b.fmt("-DOPENSSL_INCLUDE_DIR={s}", .{dir}));
    if (opts.zstd_lib_dir) |lib_dir| {
        build_cmd.addArg(b.fmt("-DZSTD_ROOT_DIR={s}", .{std.fs.path.dirname(lib_dir) orelse "."}));
    }
    if (opts.static_deps) build_cmd.addArg("-DOPENSSL_USE_STATIC_LIBS=ON");

    return .{
        .generated_include_dir = build_dir.path(b, "include"),
        .static_library = build_dir.path(b, "libmariadb/libmysqlclient.a"),
    };
}

const SystemLibraryOptions = struct {
    openssl_lib_dir: ?[]const u8,
    zstd_lib_dir: ?[]const u8,
    static_deps: bool,
};

fn linkMariaDbSystemLibraries(module: *std.Build.Module, target: std.Build.ResolvedTarget, opts: SystemLibraryOptions) void {
    if (opts.openssl_lib_dir) |lib_dir| {
        module.addLibraryPath(.{ .cwd_relative = lib_dir });
    }
    if (opts.zstd_lib_dir) |lib_dir| {
        module.addLibraryPath(.{ .cwd_relative = lib_dir });
    }
    // Zig falls back to the dynamic library when no .a is found, so check the
    // result with tools/check_linkage.sh.
    const link_mode: std.builtin.LinkMode = if (opts.static_deps) .static else .dynamic;
    module.linkSystemLibrary("ssl", .{ .preferred_link_mode = link_mode });
    module.linkSystemLibrary("crypto", .{ .preferred_link_mode = link_mode });
    module.linkSystemLibrary("zstd", .{ .preferred_link_mode = link_mode });

    switch (target.result.os.tag) {
        .macos => {
            module.linkSystemLibrary("krb5", .{});
        },
        .linux => {
            module.linkSystemLibrary("m", .{});
            module.linkSystemLibrary("pthread", .{});
            module.linkSystemLibrary("dl", .{});
            module.linkSystemLibrary("gssapi_krb5", .{});
            module.linkSystemLibrary("krb5", .{});
        },
        .freebsd, .openbsd, .netbsd, .dragonfly => {
            module.linkSystemLibrary("m", .{});
            module.linkSystemLibrary("pthread", .{});
            module.linkSystemLibrary("dl", .{});
            module.linkSystemLibrary("krb5", .{});
        },
        .windows => {
            module.linkSystemLibrary("secur32", .{});
        },
        else => {},
    }
}

// Flags for the ANTLR runtime, the MySQL base classes, the generated parser and
// the smoke test. The runtime targets C++17.
const parser_cxx_flags: []const []const u8 = &.{
    "-std=c++17",
    // Selects the static (non-dllexport) form of the ANTLR runtime's API.
    "-DANTLR4CPP_STATIC",
};

// antlr4-c3 needs C++20 (defaulted comparisons, ranges, contains()).
const antlr4_c3_cxx_flags: []const []const u8 = &.{
    "-std=c++20",
    "-DANTLR4CPP_STATIC",
};

fn addParserIncludePaths(module: *std.Build.Module, b: *std.Build) void {
    module.addIncludePath(b.path("deps/antlr4/runtime/Cpp/runtime/src"));
    module.addIncludePath(b.path("deps/antlr4-c3/ports/cpp/source/antlr4-c3"));
    // Holds the hand-written MySQL base classes and base/symbol-info.h.
    module.addIncludePath(b.path("src/sql/antlr"));
    module.addIncludePath(b.path("src/sql/generated"));
}

// Builds the ANTLR4 C++ runtime, antlr4-c3, the MySQL base classes and the
// generated MySQL lexer and parser as a static library.
fn addMysqlParserLibrary(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
    });
    addParserIncludePaths(module, b);

    module.addCSourceFiles(.{
        .files = &(parser_sources.antlr_runtime ++ parser_sources.mysql_base ++ parser_sources.mysql_generated),
        .flags = parser_cxx_flags,
    });

    // antlr4-c3 needs C++20, so it is compiled with its own flags. The shim includes
    // its header, so it needs them too.
    module.addCSourceFiles(.{
        .files = &(parser_sources.antlr4_c3 ++ parser_sources.mysql_shim),
        .flags = antlr4_c3_cxx_flags,
    });

    return b.addLibrary(.{
        .name = "mysql_parser",
        .linkage = .static,
        .root_module = module,
    });
}
