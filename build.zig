//! Zinux kernel — build-konfiguraatio (Zig 0.16).
//!
//! **Vastuu**: Käännä freestanding kernel, luo ISO, käynnistä QEMU.
//! **Käyttö**:
//!   `zig build`        — käännä kernel.elf
//!   `zig build iso`    — luo bootattava ISO
//!   `zig build run`        — QEMU smoke boot (nopea, lopettaa "Smoke boot OK")
//!   `zig build boot-test`  — QEMU täysi integraatiotestit (lopettaa "Full boot OK")
//!   `zig build run -Dboot=dev` — interaktiivinen scheduler (ei lopeta)
//!   `zig build test`   — aja host-yksikkötestit

const std = @import("std");

// Limine-binäärit ladataan tähän cache-hakemistoon ensimmäisellä ISO-buildillä.
const limine_version = "12.6.1";
const limine_cache = ".zig-cache/limine";

/// Convert backslash path separators to forward slashes (fresh allocation —
/// the old stack-buffer version returned a dangling slice, so every call
/// aliased the same dead frame and ISO paths came out as garbage).
fn posixPath(b: *std.Build, src: []const u8) []u8 {
    const out = b.allocator.alloc(u8, src.len) catch @panic("OOM");
    for (src, 0..) |c, i| out[i] = if (c == '\\') '/' else c;
    return out;
}

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // Boot-tila: smoke (CI/nopea), full (integraatiotestit), dev (ikuinen scheduler).
    const boot_mode = b.option(
        enum { smoke, full, dev },
        "boot",
        "Kernel boot mode: smoke (fast CI), full (all tests + exit), dev (interactive)",
    ) orelse .smoke;

    // Freestanding x86_64 — ei SSE/AVX (ei FPU-tilan tallennusta bootissa).
    var query = std.Target.Query{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    };
    query.cpu_features_add = std.Target.x86.featureSet(&.{.soft_float});
    query.cpu_features_sub = std.Target.x86.featureSet(&.{
        .mmx, .sse, .sse2, .sse3, .ssse3, .sse4_1, .sse4_2, .avx, .avx2,
    });
    const target = b.resolveTargetQuery(query);

    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("kernel/main.zig"),
        .target = target,
        // ReleaseSafe freestandingissä — Debug vetää UBSAN/SSE-runtimea jota ei ole.
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
    });
    kernel_mod.red_zone = false;
    kernel_mod.stack_protector = false;
    kernel_mod.code_model = .kernel;
    kernel_mod.single_threaded = true;
    const abi_mod = b.createModule(.{
        .root_source_file = b.path("libs/zinuxabi.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
    });
    kernel_mod.addImport("zinuxabi", abi_mod);
    // Plugin-manifestiskeema kerneliin (Vaihe 30 manifest-valvonta).
    const plugin_manifest_kernel_dep = b.createModule(.{
        .root_source_file = b.path("userland/plugin_manifest.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
    });
    plugin_manifest_kernel_dep.single_threaded = true;
    kernel_mod.addImport("plugin_manifest", plugin_manifest_kernel_dep);
    // Vaihe 34.1/34.2 — TDL-spec + composer-heuristiikka kerneliin.
    // Jaettu `composer_task`-instanssi molemmille (ei kahta tyyppi-instanssia).
    const composer_task_kernel_mod = b.createModule(.{
        .root_source_file = b.path("userland/composer/task.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
    });
    composer_task_kernel_mod.single_threaded = true;
    kernel_mod.addImport("composer_task", composer_task_kernel_mod);
    const composer_resolve_kernel_mod = b.createModule(.{
        .root_source_file = b.path("userland/composer/resolve.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
    });
    composer_resolve_kernel_mod.single_threaded = true;
    composer_resolve_kernel_mod.addImport("composer_task", composer_task_kernel_mod);
    kernel_mod.addImport("composer_resolve", composer_resolve_kernel_mod);

    // Prosessitaulukko — capability-slotit per pid (Vaihe 20).
    const process_core_kernel_mod = b.createModule(.{
        .root_source_file = b.path("kernel/sched/process_core.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
    });
    process_core_kernel_mod.single_threaded = true;
    kernel_mod.addImport("process_core", process_core_kernel_mod);

    // Boot-tila kernelille (smoke / full / dev).
    const boot_options = b.addOptions();
    boot_options.addOption(@TypeOf(boot_mode), "mode", boot_mode);
    kernel_mod.addOptions("boot_options", boot_options);

    // --- Loader-testi user-ELF (Vaihe 5.1) — upotetaan kerneliin ---
    const user_test_mod = b.createModule(.{
        .root_source_file = b.path("userland/loader_test/main.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
    });
    user_test_mod.red_zone = false;
    user_test_mod.stack_protector = false;
    user_test_mod.single_threaded = true;
    const user_test_exe = b.addExecutable(.{
        .name = "loader-test-user",
        .root_module = user_test_mod,
    });
    user_test_exe.setLinkerScript(b.path("userland/user.ld"));
    user_test_exe.root_module.addAssemblyFile(b.path("userland/loader_test/start.S"));
    b.installArtifact(user_test_exe);

    const embedded_elf_path = b.path("kernel/loader/test_prog.bin");
    const copy_test_elf = b.addSystemCommand(&.{ "cp", "-f" });
    copy_test_elf.addFileArg(user_test_exe.getEmittedBin());
    copy_test_elf.addFileArg(embedded_elf_path);
    copy_test_elf.step.dependOn(&user_test_exe.step);

    // --- Init-prosessi user-ELF (Vaihe 5.2) — upotetaan kerneliin ---
    const init_mod = b.createModule(.{
        .root_source_file = b.path("userland/init/main.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
    });
    init_mod.red_zone = false;
    init_mod.stack_protector = false;
    init_mod.single_threaded = true;
    const init_exe = b.addExecutable(.{
        .name = "zinux-init",
        .root_module = init_mod,
    });
    init_exe.setLinkerScript(b.path("userland/init/user.ld"));
    init_exe.root_module.addAssemblyFile(b.path("userland/init/start.S"));
    b.installArtifact(init_exe);

    const embedded_init_path = b.path("kernel/loader/init_prog.bin");
    const copy_init_elf = b.addSystemCommand(&.{ "cp", "-f" });
    copy_init_elf.addFileArg(init_exe.getEmittedBin());
    copy_init_elf.addFileArg(embedded_init_path);
    copy_init_elf.step.dependOn(&init_exe.step);

    // --- Shell user-ELF (Vaihe 5.3) — upotetaan kerneliin ---
    const shell_mod = b.createModule(.{
        .root_source_file = b.path("userland/shell/main.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
    });
    shell_mod.red_zone = false;
    shell_mod.stack_protector = false;
    shell_mod.single_threaded = true;
    shell_mod.code_model = .large;
    const shell_exe = b.addExecutable(.{
        .name = "zinux-shell",
        .root_module = shell_mod,
    });
    shell_exe.setLinkerScript(b.path("userland/shell/user.ld"));
    shell_exe.root_module.addAssemblyFile(b.path("userland/shell/start.S"));
    b.installArtifact(shell_exe);

    const embedded_shell_path = b.path("kernel/loader/shell_prog.bin");
    const copy_shell_elf = b.addSystemCommand(&.{ "cp", "-f" });
    copy_shell_elf.addFileArg(shell_exe.getEmittedBin());
    copy_shell_elf.addFileArg(embedded_shell_path);
    copy_shell_elf.step.dependOn(&shell_exe.step);

    // --- Userland driver test ELF (Vaihe 6.5) — upotetaan kerneliin ---
    const driver_mod = b.createModule(.{
        .root_source_file = b.path("userland/drivers/main.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
    });
    driver_mod.red_zone = false;
    driver_mod.stack_protector = false;
    driver_mod.single_threaded = true;
    driver_mod.code_model = .large;
    const driver_exe = b.addExecutable(.{
        .name = "zinux-driver-test",
        .root_module = driver_mod,
    });
    driver_exe.setLinkerScript(b.path("userland/drivers/user.ld"));
    driver_exe.root_module.addAssemblyFile(b.path("userland/drivers/start.S"));
    b.installArtifact(driver_exe);

    const embedded_driver_path = b.path("kernel/loader/driver_prog.bin");
    const copy_driver_elf = b.addSystemCommand(&.{ "cp", "-f" });
    copy_driver_elf.addFileArg(driver_exe.getEmittedBin());
    copy_driver_elf.addFileArg(embedded_driver_path);
    copy_driver_elf.step.dependOn(&driver_exe.step);

    // --- IPC userland test ELF (Vaihe 8.2) — upotetaan kerneliin ---
    const ipc_core_user_mod = b.createModule(.{
        .root_source_file = b.path("userland/lib/ipc_core.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
    });
    const ipc_lib_mod = b.createModule(.{
        .root_source_file = b.path("userland/lib/ipc.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
    });
    ipc_lib_mod.addImport("ipc_core", ipc_core_user_mod);
    const ipc_test_mod = b.createModule(.{
        .root_source_file = b.path("userland/ipc_test/main.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
    });
    ipc_test_mod.red_zone = false;
    ipc_test_mod.stack_protector = false;
    ipc_test_mod.single_threaded = true;
    ipc_test_mod.code_model = .large;
    ipc_test_mod.addImport("ipc", ipc_lib_mod);
    const ipc_test_exe = b.addExecutable(.{
        .name = "zinux-ipc-test",
        .root_module = ipc_test_mod,
    });
    ipc_test_exe.setLinkerScript(b.path("userland/ipc_test/user.ld"));
    ipc_test_exe.root_module.addAssemblyFile(b.path("userland/ipc_test/start.S"));
    b.installArtifact(ipc_test_exe);

    const embedded_ipc_test_path = b.path("kernel/loader/ipc_test_prog.bin");
    const copy_ipc_test_elf = b.addSystemCommand(&.{ "cp", "-f" });
    copy_ipc_test_elf.addFileArg(ipc_test_exe.getEmittedBin());
    copy_ipc_test_elf.addFileArg(embedded_ipc_test_path);
    copy_ipc_test_elf.step.dependOn(&ipc_test_exe.step);

    // --- Cap userland test ELF (Vaihe 9.2) — upotetaan kerneliin ---
    const cap_core_user_mod = b.createModule(.{
        .root_source_file = b.path("userland/lib/cap_core.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
    });
    const cap_lib_mod = b.createModule(.{
        .root_source_file = b.path("userland/lib/cap.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
    });
    cap_lib_mod.addImport("cap_core", cap_core_user_mod);
    const cap_test_mod = b.createModule(.{
        .root_source_file = b.path("userland/cap_test/main.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
    });
    cap_test_mod.red_zone = false;
    cap_test_mod.stack_protector = false;
    cap_test_mod.single_threaded = true;
    cap_test_mod.code_model = .large;
    cap_test_mod.addImport("cap", cap_lib_mod);
    cap_test_mod.addImport("ipc", ipc_lib_mod);
    const cap_test_exe = b.addExecutable(.{
        .name = "zinux-cap-test",
        .root_module = cap_test_mod,
    });
    cap_test_exe.setLinkerScript(b.path("userland/cap_test/user.ld"));
    cap_test_exe.root_module.addAssemblyFile(b.path("userland/cap_test/start.S"));
    b.installArtifact(cap_test_exe);

    const embedded_cap_test_path = b.path("kernel/loader/cap_test_prog.bin");
    const copy_cap_test_elf = b.addSystemCommand(&.{ "cp", "-f" });
    copy_cap_test_elf.addFileArg(cap_test_exe.getEmittedBin());
    copy_cap_test_elf.addFileArg(embedded_cap_test_path);
    copy_cap_test_elf.step.dependOn(&cap_test_exe.step);

    // --- Cap create userland test ELF (Vaihe 10.2) — upotetaan kerneliin ---
    const cap_create_test_mod = b.createModule(.{
        .root_source_file = b.path("userland/cap_create_test/main.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
    });
    cap_create_test_mod.red_zone = false;
    cap_create_test_mod.stack_protector = false;
    cap_create_test_mod.single_threaded = true;
    cap_create_test_mod.code_model = .large;
    cap_create_test_mod.addImport("cap", cap_lib_mod);
    cap_create_test_mod.addImport("ipc", ipc_lib_mod);
    const cap_create_test_exe = b.addExecutable(.{
        .name = "zinux-cap-create-test",
        .root_module = cap_create_test_mod,
    });
    cap_create_test_exe.setLinkerScript(b.path("userland/cap_create_test/user.ld"));
    cap_create_test_exe.root_module.addAssemblyFile(b.path("userland/cap_create_test/start.S"));
    b.installArtifact(cap_create_test_exe);

    const embedded_cap_create_test_path = b.path("kernel/loader/cap_create_test_prog.bin");
    const copy_cap_create_test_elf = b.addSystemCommand(&.{ "cp", "-f" });
    copy_cap_create_test_elf.addFileArg(cap_create_test_exe.getEmittedBin());
    copy_cap_create_test_elf.addFileArg(embedded_cap_create_test_path);
    copy_cap_create_test_elf.step.dependOn(&cap_create_test_exe.step);

    // --- Cap revoke userland test ELF (Vaihe 12.2) — upotetaan kerneliin ---
    const cap_revoke_test_mod = b.createModule(.{
        .root_source_file = b.path("userland/cap_revoke_test/main.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
    });
    cap_revoke_test_mod.red_zone = false;
    cap_revoke_test_mod.stack_protector = false;
    cap_revoke_test_mod.single_threaded = true;
    cap_revoke_test_mod.code_model = .large;
    cap_revoke_test_mod.addImport("cap", cap_lib_mod);
    cap_revoke_test_mod.addImport("ipc", ipc_lib_mod);
    const cap_revoke_test_exe = b.addExecutable(.{
        .name = "zinux-cap-revoke-test",
        .root_module = cap_revoke_test_mod,
    });
    cap_revoke_test_exe.setLinkerScript(b.path("userland/cap_revoke_test/user.ld"));
    cap_revoke_test_exe.root_module.addAssemblyFile(b.path("userland/cap_revoke_test/start.S"));
    b.installArtifact(cap_revoke_test_exe);

    const embedded_cap_revoke_test_path = b.path("kernel/loader/cap_revoke_test_prog.bin");
    const copy_cap_revoke_test_elf = b.addSystemCommand(&.{ "cp", "-f" });
    copy_cap_revoke_test_elf.addFileArg(cap_revoke_test_exe.getEmittedBin());
    copy_cap_revoke_test_elf.addFileArg(embedded_cap_revoke_test_path);
    copy_cap_revoke_test_elf.step.dependOn(&cap_revoke_test_exe.step);

    // --- IPC try recv userland test ELF (Vaihe 13.2) — upotetaan kerneliin ---
    const ipc_try_recv_test_mod = b.createModule(.{
        .root_source_file = b.path("userland/ipc_try_recv_test/main.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
    });
    ipc_try_recv_test_mod.red_zone = false;
    ipc_try_recv_test_mod.stack_protector = false;
    ipc_try_recv_test_mod.single_threaded = true;
    ipc_try_recv_test_mod.code_model = .large;
    ipc_try_recv_test_mod.addImport("cap", cap_lib_mod);
    ipc_try_recv_test_mod.addImport("ipc", ipc_lib_mod);
    const ipc_try_recv_test_exe = b.addExecutable(.{
        .name = "zinux-ipc-try-recv-test",
        .root_module = ipc_try_recv_test_mod,
    });
    ipc_try_recv_test_exe.setLinkerScript(b.path("userland/ipc_try_recv_test/user.ld"));
    ipc_try_recv_test_exe.root_module.addAssemblyFile(b.path("userland/ipc_try_recv_test/start.S"));
    b.installArtifact(ipc_try_recv_test_exe);

    const embedded_ipc_try_recv_test_path = b.path("kernel/loader/ipc_try_recv_test_prog.bin");
    const copy_ipc_try_recv_test_elf = b.addSystemCommand(&.{ "cp", "-f" });
    copy_ipc_try_recv_test_elf.addFileArg(ipc_try_recv_test_exe.getEmittedBin());
    copy_ipc_try_recv_test_elf.addFileArg(embedded_ipc_try_recv_test_path);
    copy_ipc_try_recv_test_elf.step.dependOn(&ipc_try_recv_test_exe.step);

    // --- IPC pending userland test ELF (Vaihe 14.2) — upotetaan kerneliin ---
    const ipc_pending_test_mod = b.createModule(.{
        .root_source_file = b.path("userland/ipc_pending_test/main.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
    });
    ipc_pending_test_mod.red_zone = false;
    ipc_pending_test_mod.stack_protector = false;
    ipc_pending_test_mod.single_threaded = true;
    ipc_pending_test_mod.code_model = .large;
    ipc_pending_test_mod.addImport("cap", cap_lib_mod);
    ipc_pending_test_mod.addImport("ipc", ipc_lib_mod);
    const ipc_pending_test_exe = b.addExecutable(.{
        .name = "zinux-ipc-pending-test",
        .root_module = ipc_pending_test_mod,
    });
    ipc_pending_test_exe.setLinkerScript(b.path("userland/ipc_pending_test/user.ld"));
    ipc_pending_test_exe.root_module.addAssemblyFile(b.path("userland/ipc_pending_test/start.S"));
    b.installArtifact(ipc_pending_test_exe);

    const embedded_ipc_pending_test_path = b.path("kernel/loader/ipc_pending_test_prog.bin");
    const copy_ipc_pending_test_elf = b.addSystemCommand(&.{ "cp", "-f" });
    copy_ipc_pending_test_elf.addFileArg(ipc_pending_test_exe.getEmittedBin());
    copy_ipc_pending_test_elf.addFileArg(embedded_ipc_pending_test_path);
    copy_ipc_pending_test_elf.step.dependOn(&ipc_pending_test_exe.step);

    // --- IPC queue capacity userland test ELF (Vaihe 19.2) — upotetaan kerneliin ---
    const ipc_queue_capacity_test_mod = b.createModule(.{
        .root_source_file = b.path("userland/ipc_queue_capacity_test/main.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
    });
    ipc_queue_capacity_test_mod.red_zone = false;
    ipc_queue_capacity_test_mod.stack_protector = false;
    ipc_queue_capacity_test_mod.single_threaded = true;
    ipc_queue_capacity_test_mod.code_model = .large;
    ipc_queue_capacity_test_mod.addImport("cap", cap_lib_mod);
    ipc_queue_capacity_test_mod.addImport("ipc", ipc_lib_mod);
    const ipc_queue_capacity_test_exe = b.addExecutable(.{
        .name = "zinux-ipc-queue-capacity-test",
        .root_module = ipc_queue_capacity_test_mod,
    });
    ipc_queue_capacity_test_exe.setLinkerScript(b.path("userland/ipc_queue_capacity_test/user.ld"));
    ipc_queue_capacity_test_exe.root_module.addAssemblyFile(b.path("userland/ipc_queue_capacity_test/start.S"));
    b.installArtifact(ipc_queue_capacity_test_exe);

    const embedded_ipc_queue_capacity_test_path = b.path("kernel/loader/ipc_queue_capacity_test_prog.bin");
    const copy_ipc_queue_capacity_test_elf = b.addSystemCommand(&.{ "cp", "-f" });
    copy_ipc_queue_capacity_test_elf.addFileArg(ipc_queue_capacity_test_exe.getEmittedBin());
    copy_ipc_queue_capacity_test_elf.addFileArg(embedded_ipc_queue_capacity_test_path);
    copy_ipc_queue_capacity_test_elf.step.dependOn(&ipc_queue_capacity_test_exe.step);

    // --- Cap get rights userland test ELF (Vaihe 15.2) — upotetaan kerneliin ---
    const cap_get_rights_test_mod = b.createModule(.{
        .root_source_file = b.path("userland/cap_get_rights_test/main.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
    });
    cap_get_rights_test_mod.red_zone = false;
    cap_get_rights_test_mod.stack_protector = false;
    cap_get_rights_test_mod.single_threaded = true;
    cap_get_rights_test_mod.code_model = .large;
    cap_get_rights_test_mod.addImport("cap", cap_lib_mod);
    const cap_get_rights_test_exe = b.addExecutable(.{
        .name = "zinux-cap-get-rights-test",
        .root_module = cap_get_rights_test_mod,
    });
    cap_get_rights_test_exe.setLinkerScript(b.path("userland/cap_get_rights_test/user.ld"));
    cap_get_rights_test_exe.root_module.addAssemblyFile(b.path("userland/cap_get_rights_test/start.S"));
    b.installArtifact(cap_get_rights_test_exe);

    const embedded_cap_get_rights_test_path = b.path("kernel/loader/cap_get_rights_test_prog.bin");
    const copy_cap_get_rights_test_elf = b.addSystemCommand(&.{ "cp", "-f" });
    copy_cap_get_rights_test_elf.addFileArg(cap_get_rights_test_exe.getEmittedBin());
    copy_cap_get_rights_test_elf.addFileArg(embedded_cap_get_rights_test_path);
    copy_cap_get_rights_test_elf.step.dependOn(&cap_get_rights_test_exe.step);

    // --- Cap get type userland test ELF (Vaihe 16.2) — upotetaan kerneliin ---
    const cap_get_type_test_mod = b.createModule(.{
        .root_source_file = b.path("userland/cap_get_type_test/main.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
    });
    cap_get_type_test_mod.red_zone = false;
    cap_get_type_test_mod.stack_protector = false;
    cap_get_type_test_mod.single_threaded = true;
    cap_get_type_test_mod.code_model = .large;
    cap_get_type_test_mod.addImport("cap", cap_lib_mod);
    const cap_get_type_test_exe = b.addExecutable(.{
        .name = "zinux-cap-get-type-test",
        .root_module = cap_get_type_test_mod,
    });
    cap_get_type_test_exe.setLinkerScript(b.path("userland/cap_get_type_test/user.ld"));
    cap_get_type_test_exe.root_module.addAssemblyFile(b.path("userland/cap_get_type_test/start.S"));
    b.installArtifact(cap_get_type_test_exe);

    const embedded_cap_get_type_test_path = b.path("kernel/loader/cap_get_type_test_prog.bin");
    const copy_cap_get_type_test_elf = b.addSystemCommand(&.{ "cp", "-f" });
    copy_cap_get_type_test_elf.addFileArg(cap_get_type_test_exe.getEmittedBin());
    copy_cap_get_type_test_elf.addFileArg(embedded_cap_get_type_test_path);
    copy_cap_get_type_test_elf.step.dependOn(&cap_get_type_test_exe.step);

    // --- IPC flush userland test ELF (Vaihe 17.2) — upotetaan kerneliin ---
    const ipc_flush_test_mod = b.createModule(.{
        .root_source_file = b.path("userland/ipc_flush_test/main.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
    });
    ipc_flush_test_mod.red_zone = false;
    ipc_flush_test_mod.stack_protector = false;
    ipc_flush_test_mod.single_threaded = true;
    ipc_flush_test_mod.code_model = .large;
    ipc_flush_test_mod.addImport("cap", cap_lib_mod);
    ipc_flush_test_mod.addImport("ipc", ipc_lib_mod);
    const ipc_flush_test_exe = b.addExecutable(.{
        .name = "zinux-ipc-flush-test",
        .root_module = ipc_flush_test_mod,
    });
    ipc_flush_test_exe.setLinkerScript(b.path("userland/ipc_flush_test/user.ld"));
    ipc_flush_test_exe.root_module.addAssemblyFile(b.path("userland/ipc_flush_test/start.S"));
    b.installArtifact(ipc_flush_test_exe);

    const embedded_ipc_flush_test_path = b.path("kernel/loader/ipc_flush_test_prog.bin");
    const copy_ipc_flush_test_elf = b.addSystemCommand(&.{ "cp", "-f" });
    copy_ipc_flush_test_elf.addFileArg(ipc_flush_test_exe.getEmittedBin());
    copy_ipc_flush_test_elf.addFileArg(embedded_ipc_flush_test_path);
    copy_ipc_flush_test_elf.step.dependOn(&ipc_flush_test_exe.step);

    // --- Cap get resource userland test ELF (Vaihe 18.2) — upotetaan kerneliin ---
    const cap_get_resource_test_mod = b.createModule(.{
        .root_source_file = b.path("userland/cap_get_resource_test/main.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
    });
    cap_get_resource_test_mod.red_zone = false;
    cap_get_resource_test_mod.stack_protector = false;
    cap_get_resource_test_mod.single_threaded = true;
    cap_get_resource_test_mod.code_model = .large;
    cap_get_resource_test_mod.addImport("cap", cap_lib_mod);
    const cap_get_resource_test_exe = b.addExecutable(.{
        .name = "zinux-cap-get-resource-test",
        .root_module = cap_get_resource_test_mod,
    });
    cap_get_resource_test_exe.setLinkerScript(b.path("userland/cap_get_resource_test/user.ld"));
    cap_get_resource_test_exe.root_module.addAssemblyFile(b.path("userland/cap_get_resource_test/start.S"));
    b.installArtifact(cap_get_resource_test_exe);

    const embedded_cap_get_resource_test_path = b.path("kernel/loader/cap_get_resource_test_prog.bin");
    const copy_cap_get_resource_test_elf = b.addSystemCommand(&.{ "cp", "-f" });
    copy_cap_get_resource_test_elf.addFileArg(cap_get_resource_test_exe.getEmittedBin());
    copy_cap_get_resource_test_elf.addFileArg(embedded_cap_get_resource_test_path);
    copy_cap_get_resource_test_elf.step.dependOn(&cap_get_resource_test_exe.step);

    // --- IPC block userland test ELF (Vaihe 11.2) — upotetaan kerneliin ---
    const ipc_block_test_mod = b.createModule(.{
        .root_source_file = b.path("userland/ipc_block_test/main.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
    });
    ipc_block_test_mod.red_zone = false;
    ipc_block_test_mod.stack_protector = false;
    ipc_block_test_mod.single_threaded = true;
    ipc_block_test_mod.code_model = .large;
    ipc_block_test_mod.addImport("ipc", ipc_lib_mod);
    const ipc_block_test_exe = b.addExecutable(.{
        .name = "zinux-ipc-block-test",
        .root_module = ipc_block_test_mod,
    });
    ipc_block_test_exe.setLinkerScript(b.path("userland/ipc_block_test/user.ld"));
    ipc_block_test_exe.root_module.addAssemblyFile(b.path("userland/ipc_block_test/start.S"));
    b.installArtifact(ipc_block_test_exe);

    const embedded_ipc_block_test_path = b.path("kernel/loader/ipc_block_test_prog.bin");
    const copy_ipc_block_test_elf = b.addSystemCommand(&.{ "cp", "-f" });
    copy_ipc_block_test_elf.addFileArg(ipc_block_test_exe.getEmittedBin());
    copy_ipc_block_test_elf.addFileArg(embedded_ipc_block_test_path);
    copy_ipc_block_test_elf.step.dependOn(&ipc_block_test_exe.step);

    // --- Spawn child A user-ELF (Vaihe 21) — upotetaan kerneliin ---
    const spawn_child_a_mod = b.createModule(.{
        .root_source_file = b.path("userland/spawn_child_a/main.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
    });
    spawn_child_a_mod.red_zone = false;
    spawn_child_a_mod.stack_protector = false;
    spawn_child_a_mod.single_threaded = true;
    const spawn_child_a_exe = b.addExecutable(.{
        .name = "zinux-spawn-child-a",
        .root_module = spawn_child_a_mod,
    });
    spawn_child_a_exe.setLinkerScript(b.path("userland/spawn_child_a/user.ld"));
    spawn_child_a_exe.root_module.addAssemblyFile(b.path("userland/spawn_child_a/start.S"));
    b.installArtifact(spawn_child_a_exe);

    const embedded_spawn_child_a_path = b.path("kernel/loader/spawn_child_a_prog.bin");
    const copy_spawn_child_a_elf = b.addSystemCommand(&.{ "cp", "-f" });
    copy_spawn_child_a_elf.addFileArg(spawn_child_a_exe.getEmittedBin());
    copy_spawn_child_a_elf.addFileArg(embedded_spawn_child_a_path);
    copy_spawn_child_a_elf.step.dependOn(&spawn_child_a_exe.step);

    // --- Spawn child B user-ELF (Vaihe 21) — upotetaan kerneliin ---
    const spawn_child_b_mod = b.createModule(.{
        .root_source_file = b.path("userland/spawn_child_b/main.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
    });
    spawn_child_b_mod.red_zone = false;
    spawn_child_b_mod.stack_protector = false;
    spawn_child_b_mod.single_threaded = true;
    const spawn_child_b_exe = b.addExecutable(.{
        .name = "zinux-spawn-child-b",
        .root_module = spawn_child_b_mod,
    });
    spawn_child_b_exe.setLinkerScript(b.path("userland/spawn_child_b/user.ld"));
    spawn_child_b_exe.root_module.addAssemblyFile(b.path("userland/spawn_child_b/start.S"));
    b.installArtifact(spawn_child_b_exe);

    const embedded_spawn_child_b_path = b.path("kernel/loader/spawn_child_b_prog.bin");
    const copy_spawn_child_b_elf = b.addSystemCommand(&.{ "cp", "-f" });
    copy_spawn_child_b_elf.addFileArg(spawn_child_b_exe.getEmittedBin());
    copy_spawn_child_b_elf.addFileArg(embedded_spawn_child_b_path);
    copy_spawn_child_b_elf.step.dependOn(&spawn_child_b_exe.step);

    // --- Spawn child exit user-ELF (Vaihe 24) — upotetaan kerneliin ---
    const spawn_child_exit_mod = b.createModule(.{
        .root_source_file = b.path("userland/spawn_child_exit/main.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
    });
    spawn_child_exit_mod.red_zone = false;
    spawn_child_exit_mod.stack_protector = false;
    spawn_child_exit_mod.single_threaded = true;
    const spawn_child_exit_exe = b.addExecutable(.{
        .name = "zinux-spawn-child-exit",
        .root_module = spawn_child_exit_mod,
    });
    spawn_child_exit_exe.setLinkerScript(b.path("userland/spawn_child_exit/user.ld"));
    spawn_child_exit_exe.root_module.addAssemblyFile(b.path("userland/spawn_child_exit/start.S"));
    b.installArtifact(spawn_child_exit_exe);

    const embedded_spawn_child_exit_path = b.path("kernel/loader/spawn_child_exit_prog.bin");
    const copy_spawn_child_exit_elf = b.addSystemCommand(&.{ "cp", "-f" });
    copy_spawn_child_exit_elf.addFileArg(spawn_child_exit_exe.getEmittedBin());
    copy_spawn_child_exit_elf.addFileArg(embedded_spawn_child_exit_path);
    copy_spawn_child_exit_elf.step.dependOn(&spawn_child_exit_exe.step);

    // --- Cross-IPC userland test ELF (Vaihe 22.3) — upotetaan kerneliin ---
    const cross_ipc_test_mod = b.createModule(.{
        .root_source_file = b.path("userland/cross_ipc_test/main.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
    });
    cross_ipc_test_mod.red_zone = false;
    cross_ipc_test_mod.stack_protector = false;
    cross_ipc_test_mod.single_threaded = true;
    cross_ipc_test_mod.code_model = .large;
    cross_ipc_test_mod.addImport("ipc", ipc_lib_mod);
    const cross_ipc_test_exe = b.addExecutable(.{
        .name = "zinux-cross-ipc-test",
        .root_module = cross_ipc_test_mod,
    });
    cross_ipc_test_exe.setLinkerScript(b.path("userland/cross_ipc_test/user.ld"));
    cross_ipc_test_exe.root_module.addAssemblyFile(b.path("userland/cross_ipc_test/start.S"));
    b.installArtifact(cross_ipc_test_exe);

    const embedded_cross_ipc_test_path = b.path("kernel/loader/cross_ipc_test_prog.bin");
    const copy_cross_ipc_test_elf = b.addSystemCommand(&.{ "cp", "-f" });
    copy_cross_ipc_test_elf.addFileArg(cross_ipc_test_exe.getEmittedBin());
    copy_cross_ipc_test_elf.addFileArg(embedded_cross_ipc_test_path);
    copy_cross_ipc_test_elf.step.dependOn(&cross_ipc_test_exe.step);

    // --- Cross-spawn IPC userland test ELF (Vaihe 27) — upotetaan kerneliin ---
    const cross_spawn_mod = b.createModule(.{
        .root_source_file = b.path("userland/cross_spawn_ipc_test/main.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
    });
    cross_spawn_mod.red_zone = false;
    cross_spawn_mod.stack_protector = false;
    cross_spawn_mod.single_threaded = true;
    cross_spawn_mod.code_model = .large;
    cross_spawn_mod.addImport("cap_core", cap_core_user_mod);
    cross_spawn_mod.addImport("ipc_core", ipc_core_user_mod);

    const cross_spawn_exe = b.addExecutable(.{
        .name = "zinux-cross-spawn-test",
        .root_module = cross_spawn_mod,
    });
    cross_spawn_exe.setLinkerScript(b.path("userland/cross_spawn_ipc_test/user.ld"));
    cross_spawn_exe.root_module.addAssemblyFile(b.path("userland/cross_spawn_ipc_test/start.S"));
    b.installArtifact(cross_spawn_exe);

    const embedded_cross_spawn_path = b.path("kernel/loader/cross_spawn_test_prog.bin");
    const copy_cross_spawn_elf = b.addSystemCommand(&.{ "cp", "-f" });
    copy_cross_spawn_elf.addFileArg(cross_spawn_exe.getEmittedBin());
    copy_cross_spawn_elf.addFileArg(embedded_cross_spawn_path);
    copy_cross_spawn_elf.step.dependOn(&cross_spawn_exe.step);

    // --- Mem map userland test ELF (Vaihe 28) — upotetaan kerneliin ---
    const mem_map_test_mod = b.createModule(.{
        .root_source_file = b.path("userland/mem_map_test/main.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
    });
    mem_map_test_mod.red_zone = false;
    mem_map_test_mod.stack_protector = false;
    mem_map_test_mod.single_threaded = true;
    mem_map_test_mod.code_model = .large;
    const mem_map_test_exe = b.addExecutable(.{
        .name = "zinux-mem-map-test",
        .root_module = mem_map_test_mod,
    });
    mem_map_test_exe.setLinkerScript(b.path("userland/mem_map_test/user.ld"));
    mem_map_test_exe.root_module.addAssemblyFile(b.path("userland/mem_map_test/start.S"));
    b.installArtifact(mem_map_test_exe);

    const embedded_mem_map_test_path = b.path("kernel/loader/mem_map_test_prog.bin");
    const copy_mem_map_test_elf = b.addSystemCommand(&.{ "cp", "-f" });
    copy_mem_map_test_elf.addFileArg(mem_map_test_exe.getEmittedBin());
    copy_mem_map_test_elf.addFileArg(embedded_mem_map_test_path);
    copy_mem_map_test_elf.step.dependOn(&mem_map_test_exe.step);

    // --- Plugin userland test ELF (Vaihe 30) — upotetaan kerneliin ---
    const plugin_test_mod = b.createModule(.{
        .root_source_file = b.path("userland/plugin_test/main.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
    });
    plugin_test_mod.red_zone = false;
    plugin_test_mod.stack_protector = false;
    plugin_test_mod.single_threaded = true;
    const plugin_test_exe = b.addExecutable(.{
        .name = "zinux-plugin-test",
        .root_module = plugin_test_mod,
    });
    plugin_test_exe.setLinkerScript(b.path("userland/plugin_test/user.ld"));
    plugin_test_exe.root_module.addAssemblyFile(b.path("userland/plugin_test/start.S"));
    b.installArtifact(plugin_test_exe);

    const embedded_plugin_test_path = b.path("kernel/loader/plugin_prog.bin");
    const copy_plugin_test_elf = b.addSystemCommand(&.{ "cp", "-f" });
    copy_plugin_test_elf.addFileArg(plugin_test_exe.getEmittedBin());
    copy_plugin_test_elf.addFileArg(embedded_plugin_test_path);
    copy_plugin_test_elf.step.dependOn(&plugin_test_exe.step);

    // --- Plugin transfer userland test ELF (Vaihe 31.3) — upotetaan kerneliin ---
    const pxfer_lib_mod = b.createModule(.{
        .root_source_file = b.path("userland/lib/plugin_transfer.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
    });
    const plugin_xfer_test_mod = b.createModule(.{
        .root_source_file = b.path("userland/plugin_xfer_test/main.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
    });
    plugin_xfer_test_mod.red_zone = false;
    plugin_xfer_test_mod.stack_protector = false;
    plugin_xfer_test_mod.single_threaded = true;
    plugin_xfer_test_mod.code_model = .large;
    plugin_xfer_test_mod.addImport("pxfer", pxfer_lib_mod);
    const plugin_xfer_test_exe = b.addExecutable(.{
        .name = "zinux-plugin-xfer-test",
        .root_module = plugin_xfer_test_mod,
    });
    plugin_xfer_test_exe.setLinkerScript(b.path("userland/plugin_xfer_test/user.ld"));
    plugin_xfer_test_exe.root_module.addAssemblyFile(b.path("userland/plugin_xfer_test/start.S"));
    b.installArtifact(plugin_xfer_test_exe);

    const embedded_plugin_xfer_test_path = b.path("kernel/loader/plugin_xfer_test_prog.bin");
    const copy_plugin_xfer_test_elf = b.addSystemCommand(&.{ "cp", "-f" });
    copy_plugin_xfer_test_elf.addFileArg(plugin_xfer_test_exe.getEmittedBin());
    copy_plugin_xfer_test_elf.addFileArg(embedded_plugin_xfer_test_path);
    copy_plugin_xfer_test_elf.step.dependOn(&plugin_xfer_test_exe.step);

    const kernel = b.addExecutable(.{
        .name = "zinux-kernel",
        .root_module = kernel_mod,
    });
    kernel.setLinkerScript(b.path("linker.ld"));
    kernel.root_module.addAssemblyFile(b.path("kernel/arch/x86_64/context_switch.S"));
    kernel.root_module.addAssemblyFile(b.path("kernel/arch/x86_64/timer_irq.S"));
    kernel.root_module.addAssemblyFile(b.path("kernel/arch/x86_64/syscall_entry.S"));
    kernel.root_module.addAssemblyFile(b.path("kernel/arch/x86_64/usermode_entry.S"));
    kernel.root_module.addAssemblyFile(b.path("kernel/arch/x86_64/usermode_jump.S"));
    kernel.root_module.addAssemblyFile(b.path("kernel/arch/x86_64/keyboard_irq.S"));
    kernel.step.dependOn(&copy_test_elf.step);
    kernel.step.dependOn(&copy_init_elf.step);
    kernel.step.dependOn(&copy_shell_elf.step);
    kernel.step.dependOn(&copy_driver_elf.step);
    kernel.step.dependOn(&copy_ipc_test_elf.step);
    kernel.step.dependOn(&copy_cap_test_elf.step);
    kernel.step.dependOn(&copy_cap_create_test_elf.step);
    kernel.step.dependOn(&copy_cap_revoke_test_elf.step);
    kernel.step.dependOn(&copy_ipc_try_recv_test_elf.step);
    kernel.step.dependOn(&copy_ipc_pending_test_elf.step);
    kernel.step.dependOn(&copy_ipc_queue_capacity_test_elf.step);
    kernel.step.dependOn(&copy_cap_get_rights_test_elf.step);
    kernel.step.dependOn(&copy_cap_get_type_test_elf.step);
    kernel.step.dependOn(&copy_ipc_flush_test_elf.step);
    kernel.step.dependOn(&copy_cap_get_resource_test_elf.step);
    kernel.step.dependOn(&copy_ipc_block_test_elf.step);
    kernel.step.dependOn(&copy_spawn_child_a_elf.step);
    kernel.step.dependOn(&copy_spawn_child_b_elf.step);
    kernel.step.dependOn(&copy_spawn_child_exit_elf.step);
    kernel.step.dependOn(&copy_cross_spawn_elf.step);
    kernel.step.dependOn(&copy_cross_ipc_test_elf.step);
    kernel.step.dependOn(&copy_mem_map_test_elf.step);
    kernel.step.dependOn(&copy_plugin_test_elf.step);
    kernel.step.dependOn(&copy_plugin_xfer_test_elf.step);
    b.installArtifact(kernel);

    // --- Host-testit ---
    const pmm_mod = b.createModule(.{
        .root_source_file = b.path("kernel/mm/pmm.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const heap_core_mod = b.createModule(.{
        .root_source_file = b.path("kernel/mm/heap_core.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const cap_audit_core_mod = b.createModule(.{
        .root_source_file = b.path("kernel/ipc/cap_audit_core.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const capability_core_mod = b.createModule(.{
        .root_source_file = b.path("kernel/ipc/capability_core.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    capability_core_mod.addImport("cap_audit_core", cap_audit_core_mod);
    kernel_mod.addImport("cap_audit_core", cap_audit_core_mod);
    const port_core_mod = b.createModule(.{
        .root_source_file = b.path("kernel/ipc/port_core.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    // capability_core tuhoaa portin revokeObject-kutsussa — tarvitsee port_core host-testeissä.
    capability_core_mod.addImport("port_core.zig", port_core_mod);
    const elf_core_mod = b.createModule(.{
        .root_source_file = b.path("kernel/loader/elf_core.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const vfs_core_mod = b.createModule(.{
        .root_source_file = b.path("kernel/fs/vfs_core.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const tmpfs_core_mod = b.createModule(.{
        .root_source_file = b.path("kernel/fs/tmpfs_core.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const driver_registry_core_mod = b.createModule(.{
        .root_source_file = b.path("userland/drivers/registry_core.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const hardening_core_mod = b.createModule(.{
        .root_source_file = b.path("kernel/arch/x86_64/hardening_core.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const stack_canary_core_mod = b.createModule(.{
        .root_source_file = b.path("kernel/arch/x86_64/stack_canary_core.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const kaslr_core_mod = b.createModule(.{
        .root_source_file = b.path("kernel/arch/x86_64/kaslr_core.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const syscall_fuzz_core_mod = b.createModule(.{
        .root_source_file = b.path("kernel/syscall/syscall_fuzz_core.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const ipc_syscall_core_mod = b.createModule(.{
        .root_source_file = b.path("kernel/syscall/ipc_syscall_core.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const ipc_core_mod = b.createModule(.{
        .root_source_file = b.path("userland/lib/ipc_core.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const cap_syscall_core_mod = b.createModule(.{
        .root_source_file = b.path("kernel/syscall/cap_syscall_core.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const cap_core_mod = b.createModule(.{
        .root_source_file = b.path("userland/lib/cap_core.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const ipc_block_core_mod = b.createModule(.{
        .root_source_file = b.path("kernel/syscall/ipc_block_core.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const process_core_mod = b.createModule(.{
        .root_source_file = b.path("kernel/sched/process_core.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    // capability_core käyttää prosessitaulukkoa slotteihin (Vaihe 20).
    capability_core_mod.addImport("process_core", process_core_mod);
    const host_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/host/root.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    host_test_mod.addImport("pmm", pmm_mod);
    host_test_mod.addImport("heap_core", heap_core_mod);
    host_test_mod.addImport("capability_core", capability_core_mod);
    host_test_mod.addImport("port_core", port_core_mod);
    host_test_mod.addImport("vfs_core", vfs_core_mod);
    host_test_mod.addImport("tmpfs_core", tmpfs_core_mod);
    host_test_mod.addImport("driver_registry_core", driver_registry_core_mod);
    host_test_mod.addImport("hardening_core", hardening_core_mod);
    host_test_mod.addImport("stack_canary_core", stack_canary_core_mod);
    host_test_mod.addImport("kaslr_core", kaslr_core_mod);
    host_test_mod.addImport("cap_audit_core", cap_audit_core_mod);
    host_test_mod.addImport("syscall_fuzz_core", syscall_fuzz_core_mod);
    host_test_mod.addImport("ipc_syscall_core", ipc_syscall_core_mod);
    host_test_mod.addImport("ipc_core", ipc_core_mod);
    host_test_mod.addImport("cap_syscall_core", cap_syscall_core_mod);
    host_test_mod.addImport("cap_core", cap_core_mod);
    host_test_mod.addImport("ipc_block_core", ipc_block_core_mod);
    host_test_mod.addImport("process_core", process_core_mod);
    const ps_syscall_core_mod = b.createModule(.{
        .root_source_file = b.path("kernel/syscall/ps_syscall_core.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    host_test_mod.addImport("ps_syscall_core", ps_syscall_core_mod);
    const wait_syscall_core_mod = b.createModule(.{
        .root_source_file = b.path("kernel/syscall/wait_syscall_core.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    host_test_mod.addImport("wait_syscall_core", wait_syscall_core_mod);
    // Vaihe 29.1 — plugin scope -ydin host-testeihin (riippuvuudeton).
    const scope_core_mod = b.createModule(.{
        .root_source_file = b.path("kernel/plugin/scope.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    host_test_mod.addImport("scope_core", scope_core_mod);
    // Vaihe 29.2 — plugin-manifest-skeema host-testeihin (riippuvuudeton).
    const plugin_manifest_mod = b.createModule(.{
        .root_source_file = b.path("userland/plugin_manifest.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    host_test_mod.addImport("plugin_manifest", plugin_manifest_mod);
    // Vaihe 30.2 — plugin-manifestin kernel-valvonta host-testeihin.
    const plugin_manifest_kernel_mod = b.createModule(.{
        .root_source_file = b.path("kernel/plugin/manifest.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    plugin_manifest_kernel_mod.addImport("scope.zig", scope_core_mod);
    plugin_manifest_kernel_mod.addImport("plugin_manifest", plugin_manifest_mod);
    host_test_mod.addImport("plugin_manifest_kernel", plugin_manifest_kernel_mod);
    // Vaihe 32.2 — plugin-pakettiformaatti host-testeihin + verify-työkaluun.
    const registry_pkg_mod = b.createModule(.{
        .root_source_file = b.path("userland/plugin_registry/package.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    registry_pkg_mod.addImport("plugin_manifest", plugin_manifest_mod);
    host_test_mod.addImport("registry_package", registry_pkg_mod);
    // Vaihe 32.2 — plugin-rekisterihakemisto host-testeihin (riippuvuudeton).
    const registry_idx_mod = b.createModule(.{
        .root_source_file = b.path("userland/plugin_registry/registry.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    host_test_mod.addImport("registry_index", registry_idx_mod);
    // Vaihe 33.1 — plugin-diagnostiikkaydin host-testeihin (riippuvuudeton).
    const plugin_diag_core_mod = b.createModule(.{
        .root_source_file = b.path("kernel/plugin_diag.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    host_test_mod.addImport("plugin_diag_core", plugin_diag_core_mod);
    // Vaihe 34.1/34.2 — TDL + composer-heuristiikka host-testeihin.
    // Jaettu `composer_task`-instanssi (sama kaava kuin capability/process).
    const composer_task_mod = b.createModule(.{
        .root_source_file = b.path("userland/composer/task.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    host_test_mod.addImport("composer_task", composer_task_mod);
    const composer_resolve_mod = b.createModule(.{
        .root_source_file = b.path("userland/composer/resolve.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    composer_resolve_mod.addImport("composer_task", composer_task_mod);
    host_test_mod.addImport("composer_resolve", composer_resolve_mod);
    // Vaihe 34.4 — decomposer-purkupolitiikka host-testeihin (riippuvuudeton).
    const decomposer_core_mod = b.createModule(.{
        .root_source_file = b.path("kernel/decomposer.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    host_test_mod.addImport("decomposer_core", decomposer_core_mod);
    const host_tests = b.addTest(.{
        .root_module = host_test_mod,
    });
    const elf_core_tests = b.addTest(.{
        .root_module = elf_core_mod,
    });
    elf_core_tests.step.dependOn(&copy_test_elf.step);
    const run_host_tests = b.step("test", "Run host unit tests");
    run_host_tests.dependOn(&b.addRunArtifact(host_tests).step);
    run_host_tests.dependOn(&b.addRunArtifact(elf_core_tests).step);

    // --- Vaihe 32.4 — plugin-install: hae URL:stä + varmenna Ed25519 + asenna ---
    // Käyttö: zig build plugin-install -Dplugin-url=<https|file> -Dplugin-key=<64 hex>
    // Luottamus tulee KUTSujan avaimesta; tyhjä url/key → askel epäonnistuu heti.
    const plugin_url = b.option([]const u8, "plugin-url", "Plugin package URL for plugin-install (https:// or file://)") orelse "";
    const plugin_key = b.option([]const u8, "plugin-key", "Trusted Ed25519 pubkey hex (64 chars) for plugin-install") orelse "";
    // Varmennin-työkalu (host-exe, rakennetaan vain tätä askelta varten).
    const verify_mod = b.createModule(.{
        .root_source_file = b.path("tools/plugin_verify.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    verify_mod.addImport("registry_package", registry_pkg_mod);
    const verify_exe = b.addExecutable(.{
        .name = "zinux-plugin-verify",
        .root_module = verify_mod,
    });
    // Haku + pyyntötiedosto varmentimelle (kiinteä polku työkalun kanssa).
    const fetch_pkg = b.addSystemCommand(&.{
        "bash", "-c",
        b.fmt(
            \\set -euo pipefail
            \\URL="{s}"
            \\KEY="{s}"
            \\if [ -z "$URL" ] || [ -z "$KEY" ]; then
            \\  echo "usage: zig build plugin-install -Dplugin-url=<url> -Dplugin-key=<64 hex>" >&2
            \\  exit 1
            \\fi
            \\DIR="zig-out/plugin-install"
            \\REG="zig-out/plugin-registry"
            \\mkdir -p "$DIR" "$REG"
            \\curl -fsSL "$URL" -o "$DIR/pkg.zpkg"
            \\NAME="$(basename "$URL")"
            \\printf '%s\n' "$DIR/pkg.zpkg" "$KEY" "$REG" "$NAME" > "$DIR/request"
        , .{ plugin_url, plugin_key }),
    });
    // Varmennus + asennus (exit != 0 → paketti EI asennu).
    const run_verify = b.addRunArtifact(verify_exe);
    run_verify.setCwd(b.path("."));
    run_verify.step.dependOn(&fetch_pkg.step);
    const install_step = b.step("plugin-install", "Fetch, Ed25519-verify and install a plugin package");
    install_step.dependOn(&run_verify.step);

    // --- Limine binary fetch + host tool build ---
    const cache_path_raw = b.pathFromRoot(limine_cache);
    const cache_path = posixPath(b, cache_path_raw);
    const fetch_limine = b.addSystemCommand(&.{
        "bash", "-c",
        b.fmt(
            \\set -euo pipefail
            \\CACHE="{s}"
            \\if [ ! -f "$CACHE/limine-bios-cd.bin" ]; then
            \\  mkdir -p "$CACHE"
            \\  curl -fsSL "https://github.com/Limine-Bootloader/Limine/releases/download/v{s}/limine-binary.tar.xz" \
            \\    | tar xJ --strip-components=1 -C "$CACHE"
            \\fi
            \\if [ ! -x "$CACHE/limine" ]; then
            \\  cc -g -O2 -std=c99 -D_FILE_OFFSET_BITS=64 "$CACHE/limine.c" -o "$CACHE/limine"
            \\fi
        , .{ cache_path, limine_version }),
    });

    // --- ISO root layout ---
    const iso_root_rel = "zig-out/iso-root";
    const iso_path_rel = "zig-out/zinux.iso";
    const root_path_raw = b.pathFromRoot(iso_root_rel);
    const root_path = posixPath(b, root_path_raw);
    const iso_path_raw = b.pathFromRoot(iso_path_rel);
    const iso_path = posixPath(b, iso_path_raw);
    const kernel_path_raw = b.pathFromRoot("zig-out/bin/zinux-kernel");
    const kernel_path = posixPath(b, kernel_path_raw);
    const limine_conf_path_raw = b.pathFromRoot("limine.conf");
    const limine_conf_path = posixPath(b, limine_conf_path_raw);

    const mk_iso_root = b.addSystemCommand(&.{
        "bash", "-c",
        b.fmt(
            \\set -euo pipefail
            \\ROOT="{s}"
            \\rm -rf "$ROOT"
            \\mkdir -p "$ROOT/boot/limine" "$ROOT/EFI/BOOT"
            \\cp "{s}" "$ROOT/boot/zinux-kernel"
            \\cp "{s}" "$ROOT/boot/limine/limine.conf"
            \\CACHE="{s}"
            \\cp "$CACHE/limine-bios-cd.bin" "$CACHE/limine-bios.sys" "$CACHE/limine-uefi-cd.bin" "$ROOT/boot/limine/"
            \\cp "$CACHE/BOOTX64.EFI" "$CACHE/BOOTIA32.EFI" "$ROOT/EFI/BOOT/"
        , .{ root_path, kernel_path, limine_conf_path, cache_path }),
    });
    mk_iso_root.step.dependOn(b.getInstallStep());
    mk_iso_root.step.dependOn(&fetch_limine.step);

    const xorriso = b.addSystemCommand(&.{
        "xorriso",          "-as",                            "mkisofs",
        "-R",               "-r",                             "-J",
        "-b",               "boot/limine/limine-bios-cd.bin", "-no-emul-boot",
        "-boot-load-size",  "4",                              "-boot-info-table",
        "-hfsplus",         "-apm-block-size",                "2048",
        "--efi-boot",       "boot/limine/limine-uefi-cd.bin", "-efi-boot-part",
        "--efi-boot-image", "--protective-msdos-label",       "-o",
    });
    xorriso.addFileArg(b.path(iso_path_rel));
    xorriso.addDirectoryArg(b.path(iso_root_rel));
    xorriso.step.dependOn(&mk_iso_root.step);

    const limine_install = b.addSystemCommand(&.{
        "bash", "-c",
        b.fmt(
            \\"{s}/limine" bios-install "{s}"
        , .{ cache_path, iso_path }),
    });
    limine_install.step.dependOn(&xorriso.step);
    limine_install.step.dependOn(&fetch_limine.step);

    const iso_step = b.step("iso", "Build bootable Zinux ISO");
    iso_step.dependOn(&limine_install.step);

    // --- Testilevy VirtIO block -ajurille (Vaihe 6.2) ---
    const test_img_rel = "zig-out/zinux-test.img";
    const test_img_path = b.pathFromRoot(test_img_rel);
    const mk_test_disk = b.addSystemCommand(&.{
        "bash", "-c",
        b.fmt(
            \\set -euo pipefail
            \\IMG="{s}"
            \\mkdir -p "$(dirname "$IMG")"
            \\dd if=/dev/zero of="$IMG" bs=512 count=2048 status=none 2>/dev/null
            \\printf 'ZINUX' | dd of="$IMG" bs=1 count=5 conv=notrunc status=none 2>/dev/null
        , .{test_img_path}),
    });

    // --- QEMU run (headless — isa-debug-exit lopettaa smoke/full-testit) ---
    // isa-debug-exit palauttaa shellille exit 1 kun kirjoitetaan 0 (QEMU-konventio).
    const qemu = b.addSystemCommand(&.{ "bash", "-c" });
    qemu.addArg(b.fmt(
        \\set -o pipefail
        \\qemu-system-x86_64 \
        \\  -M q35 \
        \\  -cpu qemu64,+smep,+smap \
        \\  -m 512M \
        \\  -display none \
        \\  -monitor none \
        \\  -serial stdio \
        \\  -no-reboot \
        \\  -no-shutdown \
        \\  -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
        \\  -drive if=none,id=zbd,format=raw,file={s} \
        \\  -device virtio-blk-pci,drive=zbd,disable-legacy=on \
        \\  -cdrom {s}
        \\ec=$?
        \\if [ "$ec" -eq 0 ] || [ "$ec" -eq 1 ]; then exit 0; fi
        \\exit "$ec"
    , .{ test_img_path, iso_path }));
    qemu.step.dependOn(&limine_install.step);
    qemu.step.dependOn(&mk_test_disk.step);

    const run_step = b.step("run", "Run Zinux in QEMU (smoke boot, exits quickly)");
    run_step.dependOn(&qemu.step);

    // --- Täysi boot-integraatiotestit (erillinen build -Dboot=full) ---
    const boot_test_cmd = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        "run",
        "-Dboot=full",
    });
    boot_test_cmd.setCwd(b.path("."));
    const boot_test_step = b.step("boot-test", "Run full QEMU integration boot tests");
    boot_test_step.dependOn(&boot_test_cmd.step);
}
