const MachO = @This();

const std = @import("std");
const build_options = @import("build_options");
const builtin = @import("builtin");
const assert = std.debug.assert;
const fmt = std.fmt;
const fs = std.fs;
const log = std.log.scoped(.link);
const macho = std.macho;
const math = std.math;
const mem = std.mem;
const meta = std.meta;

const aarch64 = @import("../codegen/aarch64.zig");
const bind = @import("MachO/bind.zig");
const codegen = @import("../codegen.zig");
const commands = @import("MachO/commands.zig");
const link = @import("../link.zig");
const llvm_backend = @import("../codegen/llvm.zig");
const target_util = @import("../target.zig");
const trace = @import("../tracy.zig").trace;

const Air = @import("../Air.zig");
const Allocator = mem.Allocator;
const Archive = @import("MachO/Archive.zig");
const Cache = @import("../Cache.zig");
const CodeSignature = @import("MachO/CodeSignature.zig");
const Compilation = @import("../Compilation.zig");
const DebugSymbols = @import("MachO/DebugSymbols.zig");
const Dylib = @import("MachO/Dylib.zig");
const File = link.File;
const Object = @import("MachO/Object.zig");
const LibStub = @import("tapi.zig").LibStub;
const Liveness = @import("../Liveness.zig");
const LlvmObject = @import("../codegen/llvm.zig").Object;
const LoadCommand = commands.LoadCommand;
const Module = @import("../Module.zig");
const SegmentCommand = commands.SegmentCommand;
pub const TextBlock = @import("MachO/TextBlock.zig");
const Trie = @import("MachO/Trie.zig");

pub const base_tag: File.Tag = File.Tag.macho;

base: File,

/// If this is not null, an object file is created by LLVM and linked with LLD afterwards.
llvm_object: ?*LlvmObject = null,

/// Debug symbols bundle (or dSym).
d_sym: ?DebugSymbols = null,

/// Page size is dependent on the target cpu architecture.
/// For x86_64 that's 4KB, whereas for aarch64, that's 16KB.
page_size: u16,

/// TODO Should we figure out embedding code signatures for other Apple platforms as part of the linker?
/// Or should this be a separate tool?
/// https://github.com/ziglang/zig/issues/9567
requires_adhoc_codesig: bool,

/// We commit 0x1000 = 4096 bytes of space to the header and
/// the table of load commands. This should be plenty for any
/// potential future extensions.
header_pad: u16 = 0x1000,

/// The absolute address of the entry point.
entry_addr: ?u64 = null,

objects: std.ArrayListUnmanaged(Object) = .{},
archives: std.ArrayListUnmanaged(Archive) = .{},

dylibs: std.ArrayListUnmanaged(Dylib) = .{},
dylibs_map: std.StringHashMapUnmanaged(u16) = .{},
referenced_dylibs: std.AutoArrayHashMapUnmanaged(u16, void) = .{},

load_commands: std.ArrayListUnmanaged(LoadCommand) = .{},

pagezero_segment_cmd_index: ?u16 = null,
text_segment_cmd_index: ?u16 = null,
data_const_segment_cmd_index: ?u16 = null,
data_segment_cmd_index: ?u16 = null,
linkedit_segment_cmd_index: ?u16 = null,
dyld_info_cmd_index: ?u16 = null,
symtab_cmd_index: ?u16 = null,
dysymtab_cmd_index: ?u16 = null,
dylinker_cmd_index: ?u16 = null,
data_in_code_cmd_index: ?u16 = null,
function_starts_cmd_index: ?u16 = null,
main_cmd_index: ?u16 = null,
dylib_id_cmd_index: ?u16 = null,
source_version_cmd_index: ?u16 = null,
build_version_cmd_index: ?u16 = null,
uuid_cmd_index: ?u16 = null,
code_signature_cmd_index: ?u16 = null,

// __TEXT segment sections
text_section_index: ?u16 = null,
stubs_section_index: ?u16 = null,
stub_helper_section_index: ?u16 = null,
text_const_section_index: ?u16 = null,
cstring_section_index: ?u16 = null,
ustring_section_index: ?u16 = null,
gcc_except_tab_section_index: ?u16 = null,
unwind_info_section_index: ?u16 = null,
eh_frame_section_index: ?u16 = null,

objc_methlist_section_index: ?u16 = null,
objc_methname_section_index: ?u16 = null,
objc_methtype_section_index: ?u16 = null,
objc_classname_section_index: ?u16 = null,

// __DATA_CONST segment sections
got_section_index: ?u16 = null,
mod_init_func_section_index: ?u16 = null,
mod_term_func_section_index: ?u16 = null,
data_const_section_index: ?u16 = null,

objc_cfstring_section_index: ?u16 = null,
objc_classlist_section_index: ?u16 = null,
objc_imageinfo_section_index: ?u16 = null,

// __DATA segment sections
tlv_section_index: ?u16 = null,
tlv_data_section_index: ?u16 = null,
tlv_bss_section_index: ?u16 = null,
la_symbol_ptr_section_index: ?u16 = null,
data_section_index: ?u16 = null,
bss_section_index: ?u16 = null,

objc_const_section_index: ?u16 = null,
objc_selrefs_section_index: ?u16 = null,
objc_classrefs_section_index: ?u16 = null,
objc_data_section_index: ?u16 = null,

bss_file_offset: ?u32 = null,
tlv_bss_file_offset: ?u32 = null,

locals: std.ArrayListUnmanaged(macho.nlist_64) = .{},
globals: std.ArrayListUnmanaged(macho.nlist_64) = .{},
undefs: std.ArrayListUnmanaged(macho.nlist_64) = .{},
symbol_resolver: std.AutoHashMapUnmanaged(u32, SymbolWithLoc) = .{},
unresolved: std.AutoArrayHashMapUnmanaged(u32, enum {
    none,
    stub,
    got,
}) = .{},

locals_free_list: std.ArrayListUnmanaged(u32) = .{},
globals_free_list: std.ArrayListUnmanaged(u32) = .{},

dyld_private_sym_index: ?u32 = null,
dyld_stub_binder_index: ?u32 = null,
stub_preamble_sym_index: ?u32 = null,

strtab: std.ArrayListUnmanaged(u8) = .{},
strtab_dir: std.HashMapUnmanaged(u32, u32, StringIndexContext, std.hash_map.default_max_load_percentage) = .{},

got_entries_map: std.AutoArrayHashMapUnmanaged(GotIndirectionKey, *TextBlock) = .{},
stubs_map: std.AutoArrayHashMapUnmanaged(u32, *TextBlock) = .{},

error_flags: File.ErrorFlags = File.ErrorFlags{},

load_commands_dirty: bool = false,
sections_order_dirty: bool = false,

has_dices: bool = false,
has_stabs: bool = false,

section_ordinals: std.AutoArrayHashMapUnmanaged(MatchingSection, void) = .{},

/// A list of text blocks that have surplus capacity. This list can have false
/// positives, as functions grow and shrink over time, only sometimes being added
/// or removed from the freelist.
///
/// A text block has surplus capacity when its overcapacity value is greater than
/// padToIdeal(minimum_text_block_size). That is, when it has so
/// much extra capacity, that we could fit a small new symbol in it, itself with
/// ideal_capacity or more.
///
/// Ideal capacity is defined by size + (size / ideal_factor).
///
/// Overcapacity is measured by actual_capacity - ideal_capacity. Note that
/// overcapacity can be negative. A simple way to have negative overcapacity is to
/// allocate a fresh text block, which will have ideal capacity, and then grow it
/// by 1 byte. It will then have -1 overcapacity.
block_free_lists: std.AutoHashMapUnmanaged(MatchingSection, std.ArrayListUnmanaged(*TextBlock)) = .{},

/// Pointer to the last allocated text block
blocks: std.AutoHashMapUnmanaged(MatchingSection, *TextBlock) = .{},

/// List of TextBlocks that are owned directly by the linker.
/// Currently these are only TextBlocks that are the result of linking
/// object files. TextBlock which take part in incremental linking are 
/// at present owned by Module.Decl.
/// TODO consolidate this.
managed_blocks: std.ArrayListUnmanaged(*TextBlock) = .{},

/// Table of Decls that are currently alive.
/// We store them here so that we can properly dispose of any allocated
/// memory within the TextBlock in the incremental linker.
/// TODO consolidate this.
decls: std.AutoArrayHashMapUnmanaged(*Module.Decl, void) = .{},

/// Currently active Module.Decl.
/// TODO this might not be necessary if we figure out how to pass Module.Decl instance
/// to codegen.genSetReg() or alterntively move PIE displacement for MCValue{ .memory = x }
/// somewhere else in the codegen.
active_decl: ?*Module.Decl = null,

const PendingUpdate = union(enum) {
    resolve_undef: u32,
    add_stub_entry: u32,
    add_got_entry: u32,
};

const StringIndexContext = struct {
    strtab: *std.ArrayListUnmanaged(u8),

    pub fn eql(_: StringIndexContext, a: u32, b: u32) bool {
        return a == b;
    }

    pub fn hash(self: StringIndexContext, x: u32) u64 {
        const x_slice = mem.spanZ(@ptrCast([*:0]const u8, self.strtab.items.ptr) + x);
        return std.hash_map.hashString(x_slice);
    }
};

pub const StringSliceAdapter = struct {
    strtab: *std.ArrayListUnmanaged(u8),

    pub fn eql(self: StringSliceAdapter, a_slice: []const u8, b: u32) bool {
        const b_slice = mem.spanZ(@ptrCast([*:0]const u8, self.strtab.items.ptr) + b);
        return mem.eql(u8, a_slice, b_slice);
    }

    pub fn hash(self: StringSliceAdapter, adapted_key: []const u8) u64 {
        _ = self;
        return std.hash_map.hashString(adapted_key);
    }
};

const SymbolWithLoc = struct {
    // Table where the symbol can be found.
    where: enum {
        global,
        undef,
    },
    where_index: u32,
    local_sym_index: u32 = 0,
    file: u16 = 0,
};

pub const GotIndirectionKey = struct {
    where: enum {
        local,
        undef,
    },
    where_index: u32,
};

/// When allocating, the ideal_capacity is calculated by
/// actual_capacity + (actual_capacity / ideal_factor)
const ideal_factor = 2;

/// Default path to dyld
const default_dyld_path: [*:0]const u8 = "/usr/lib/dyld";

/// In order for a slice of bytes to be considered eligible to keep metadata pointing at
/// it as a possible place to put new symbols, it must have enough room for this many bytes
/// (plus extra for reserved capacity).
const minimum_text_block_size = 64;
pub const min_text_capacity = padToIdeal(minimum_text_block_size);

/// Virtual memory offset corresponds to the size of __PAGEZERO segment and start of
/// __TEXT segment.
const pagezero_vmsize: u64 = 0x100000000;

pub const Export = struct {
    sym_index: ?u32 = null,
};

pub const SrcFn = struct {
    /// Offset from the beginning of the Debug Line Program header that contains this function.
    off: u32,
    /// Size of the line number program component belonging to this function, not
    /// including padding.
    len: u32,

    /// Points to the previous and next neighbors, based on the offset from .debug_line.
    /// This can be used to find, for example, the capacity of this `SrcFn`.
    prev: ?*SrcFn,
    next: ?*SrcFn,

    pub const empty: SrcFn = .{
        .off = 0,
        .len = 0,
        .prev = null,
        .next = null,
    };
};

pub fn openPath(allocator: *Allocator, sub_path: []const u8, options: link.Options) !*MachO {
    assert(options.object_format == .macho);

    if (build_options.have_llvm and options.use_llvm) {
        const self = try createEmpty(allocator, options);
        errdefer self.base.destroy();

        self.llvm_object = try LlvmObject.create(allocator, options);
        return self;
    }

    const file = try options.emit.?.directory.handle.createFile(sub_path, .{
        .truncate = false,
        .read = true,
        .mode = link.determineMode(options),
    });
    errdefer file.close();

    const self = try createEmpty(allocator, options);
    errdefer {
        self.base.file = null;
        self.base.destroy();
    }

    self.base.file = file;

    if (options.output_mode == .Lib and options.link_mode == .Static) {
        return self;
    }

    if (!options.strip and options.module != null) {
        // Create dSYM bundle.
        const dir = options.module.?.zig_cache_artifact_directory;
        log.debug("creating {s}.dSYM bundle in {s}", .{ sub_path, dir.path });

        const d_sym_path = try fmt.allocPrint(
            allocator,
            "{s}.dSYM" ++ fs.path.sep_str ++ "Contents" ++ fs.path.sep_str ++ "Resources" ++ fs.path.sep_str ++ "DWARF",
            .{sub_path},
        );
        defer allocator.free(d_sym_path);

        var d_sym_bundle = try dir.handle.makeOpenPath(d_sym_path, .{});
        defer d_sym_bundle.close();

        const d_sym_file = try d_sym_bundle.createFile(sub_path, .{
            .truncate = false,
            .read = true,
        });

        self.d_sym = .{
            .base = self,
            .file = d_sym_file,
        };
    }

    // Index 0 is always a null symbol.
    try self.locals.append(allocator, .{
        .n_strx = 0,
        .n_type = 0,
        .n_sect = 0,
        .n_desc = 0,
        .n_value = 0,
    });
    try self.strtab.append(allocator, 0);

    try self.populateMissingMetadata();

    if (self.d_sym) |*ds| {
        try ds.populateMissingMetadata(allocator);
    }

    return self;
}

pub fn createEmpty(gpa: *Allocator, options: link.Options) !*MachO {
    const self = try gpa.create(MachO);
    const cpu_arch = options.target.cpu.arch;
    const os_tag = options.target.os.tag;
    const abi = options.target.abi;
    const page_size: u16 = if (cpu_arch == .aarch64) 0x4000 else 0x1000;
    // Adhoc code signature is required when targeting aarch64-macos either directly or indirectly via the simulator
    // ABI such as aarch64-ios-simulator, etc.
    const requires_adhoc_codesig = cpu_arch == .aarch64 and (os_tag == .macos or abi == .simulator);

    self.* = .{
        .base = .{
            .tag = .macho,
            .options = options,
            .allocator = gpa,
            .file = null,
        },
        .page_size = page_size,
        .requires_adhoc_codesig = requires_adhoc_codesig,
    };

    return self;
}

pub fn flush(self: *MachO, comp: *Compilation) !void {
    if (self.base.options.output_mode == .Lib and self.base.options.link_mode == .Static) {
        if (build_options.have_llvm) {
            return self.base.linkAsArchive(comp);
        } else {
            log.err("TODO: non-LLVM archiver for MachO object files", .{});
            return error.TODOImplementWritingStaticLibFiles;
        }
    }

    const tracy = trace(@src());
    defer tracy.end();

    var arena_allocator = std.heap.ArenaAllocator.init(self.base.allocator);
    defer arena_allocator.deinit();
    const arena = &arena_allocator.allocator;

    const directory = self.base.options.emit.?.directory; // Just an alias to make it shorter to type.
    const use_stage1 = build_options.is_stage1 and self.base.options.use_stage1;

    // If there is no Zig code to compile, then we should skip flushing the output file because it
    // will not be part of the linker line anyway.
    const module_obj_path: ?[]const u8 = if (self.base.options.module) |module| blk: {
        if (use_stage1) {
            const obj_basename = try std.zig.binNameAlloc(arena, .{
                .root_name = self.base.options.root_name,
                .target = self.base.options.target,
                .output_mode = .Obj,
            });
            const o_directory = module.zig_cache_artifact_directory;
            const full_obj_path = try o_directory.join(arena, &[_][]const u8{obj_basename});
            break :blk full_obj_path;
        }

        const obj_basename = self.base.intermediary_basename orelse break :blk null;
        try self.flushModule(comp);
        const full_obj_path = try directory.join(arena, &[_][]const u8{obj_basename});
        break :blk full_obj_path;
    } else null;

    const is_lib = self.base.options.output_mode == .Lib;
    const is_dyn_lib = self.base.options.link_mode == .Dynamic and is_lib;
    const is_exe_or_dyn_lib = is_dyn_lib or self.base.options.output_mode == .Exe;
    const stack_size = self.base.options.stack_size_override orelse 0;

    const id_symlink_basename = "zld.id";

    var man: Cache.Manifest = undefined;
    defer if (!self.base.options.disable_lld_caching) man.deinit();

    var digest: [Cache.hex_digest_len]u8 = undefined;

    if (!self.base.options.disable_lld_caching) {
        man = comp.cache_parent.obtain();

        // We are about to obtain this lock, so here we give other processes a chance first.
        self.base.releaseLock();

        try man.addListOfFiles(self.base.options.objects);
        for (comp.c_object_table.keys()) |key| {
            _ = try man.addFile(key.status.success.object_path, null);
        }
        try man.addOptionalFile(module_obj_path);
        // We can skip hashing libc and libc++ components that we are in charge of building from Zig
        // installation sources because they are always a product of the compiler version + target information.
        man.hash.add(stack_size);
        man.hash.addListOfBytes(self.base.options.lib_dirs);
        man.hash.addListOfBytes(self.base.options.framework_dirs);
        man.hash.addListOfBytes(self.base.options.frameworks);
        man.hash.addListOfBytes(self.base.options.rpath_list);
        if (is_dyn_lib) {
            man.hash.addOptional(self.base.options.version);
        }
        man.hash.addStringSet(self.base.options.system_libs);
        man.hash.addOptionalBytes(self.base.options.sysroot);

        // We don't actually care whether it's a cache hit or miss; we just need the digest and the lock.
        _ = try man.hit();
        digest = man.final();

        var prev_digest_buf: [digest.len]u8 = undefined;
        const prev_digest: []u8 = Cache.readSmallFile(
            directory.handle,
            id_symlink_basename,
            &prev_digest_buf,
        ) catch |err| blk: {
            log.debug("MachO Zld new_digest={s} error: {s}", .{ std.fmt.fmtSliceHexLower(&digest), @errorName(err) });
            // Handle this as a cache miss.
            break :blk prev_digest_buf[0..0];
        };
        if (mem.eql(u8, prev_digest, &digest)) {
            log.debug("MachO Zld digest={s} match - skipping invocation", .{std.fmt.fmtSliceHexLower(&digest)});
            // Hot diggity dog! The output binary is already there.
            self.base.lock = man.toOwnedLock();
            return;
        }
        log.debug("MachO Zld prev_digest={s} new_digest={s}", .{ std.fmt.fmtSliceHexLower(prev_digest), std.fmt.fmtSliceHexLower(&digest) });

        // We are about to change the output file to be different, so we invalidate the build hash now.
        directory.handle.deleteFile(id_symlink_basename) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
    }

    const full_out_path = try directory.join(arena, &[_][]const u8{self.base.options.emit.?.sub_path});

    if (self.base.options.output_mode == .Obj) {
        // LLD's MachO driver does not support the equvialent of `-r` so we do a simple file copy
        // here. TODO: think carefully about how we can avoid this redundant operation when doing
        // build-obj. See also the corresponding TODO in linkAsArchive.
        const the_object_path = blk: {
            if (self.base.options.objects.len != 0)
                break :blk self.base.options.objects[0];

            if (comp.c_object_table.count() != 0)
                break :blk comp.c_object_table.keys()[0].status.success.object_path;

            if (module_obj_path) |p|
                break :blk p;

            // TODO I think this is unreachable. Audit this situation when solving the above TODO
            // regarding eliding redundant object -> object transformations.
            return error.NoObjectsToLink;
        };
        // This can happen when using --enable-cache and using the stage1 backend. In this case
        // we can skip the file copy.
        if (!mem.eql(u8, the_object_path, full_out_path)) {
            try fs.cwd().copyFile(the_object_path, fs.cwd(), full_out_path, .{});
        }
    } else {
        if (use_stage1) {
            const sub_path = self.base.options.emit.?.sub_path;
            self.base.file = try directory.handle.createFile(sub_path, .{
                .truncate = true,
                .read = true,
                .mode = link.determineMode(self.base.options),
            });
            try self.populateMissingMetadata();

            // TODO mimicking insertion of null symbol from incremental linker.
            // This will need to moved.
            try self.locals.append(self.base.allocator, .{
                .n_strx = 0,
                .n_type = macho.N_UNDF,
                .n_sect = 0,
                .n_desc = 0,
                .n_value = 0,
            });
            try self.strtab.append(self.base.allocator, 0);
        }

        // Positional arguments to the linker such as object files and static archives.
        var positionals = std.ArrayList([]const u8).init(arena);

        try positionals.appendSlice(self.base.options.objects);

        for (comp.c_object_table.keys()) |key| {
            try positionals.append(key.status.success.object_path);
        }

        if (module_obj_path) |p| {
            try positionals.append(p);
        }

        if (comp.compiler_rt_static_lib) |lib| {
            try positionals.append(lib.full_object_path);
        }

        // libc++ dep
        if (self.base.options.link_libcpp) {
            try positionals.append(comp.libcxxabi_static_lib.?.full_object_path);
            try positionals.append(comp.libcxx_static_lib.?.full_object_path);
        }

        // Shared and static libraries passed via `-l` flag.
        var search_lib_names = std.ArrayList([]const u8).init(arena);

        const system_libs = self.base.options.system_libs.keys();
        for (system_libs) |link_lib| {
            // By this time, we depend on these libs being dynamically linked libraries and not static libraries
            // (the check for that needs to be earlier), but they could be full paths to .dylib files, in which
            // case we want to avoid prepending "-l".
            if (Compilation.classifyFileExt(link_lib) == .shared_library) {
                try positionals.append(link_lib);
                continue;
            }

            try search_lib_names.append(link_lib);
        }

        var lib_dirs = std.ArrayList([]const u8).init(arena);
        for (self.base.options.lib_dirs) |dir| {
            if (try resolveSearchDir(arena, dir, self.base.options.sysroot)) |search_dir| {
                try lib_dirs.append(search_dir);
            } else {
                log.warn("directory not found for '-L{s}'", .{dir});
            }
        }

        var libs = std.ArrayList([]const u8).init(arena);
        var lib_not_found = false;
        for (search_lib_names.items) |lib_name| {
            // Assume ld64 default: -search_paths_first
            // Look in each directory for a dylib (stub first), and then for archive
            // TODO implement alternative: -search_dylibs_first
            for (&[_][]const u8{ ".tbd", ".dylib", ".a" }) |ext| {
                if (try resolveLib(arena, lib_dirs.items, lib_name, ext)) |full_path| {
                    try libs.append(full_path);
                    break;
                }
            } else {
                log.warn("library not found for '-l{s}'", .{lib_name});
                lib_not_found = true;
            }
        }

        if (lib_not_found) {
            log.warn("Library search paths:", .{});
            for (lib_dirs.items) |dir| {
                log.warn("  {s}", .{dir});
            }
        }

        // If we were given the sysroot, try to look there first for libSystem.B.{dylib, tbd}.
        var libsystem_available = false;
        if (self.base.options.sysroot != null) blk: {
            // Try stub file first. If we hit it, then we're done as the stub file
            // re-exports every single symbol definition.
            if (try resolveLib(arena, lib_dirs.items, "System", ".tbd")) |full_path| {
                try libs.append(full_path);
                libsystem_available = true;
                break :blk;
            }
            // If we didn't hit the stub file, try .dylib next. However, libSystem.dylib
            // doesn't export libc.dylib which we'll need to resolve subsequently also.
            if (try resolveLib(arena, lib_dirs.items, "System", ".dylib")) |libsystem_path| {
                if (try resolveLib(arena, lib_dirs.items, "c", ".dylib")) |libc_path| {
                    try libs.append(libsystem_path);
                    try libs.append(libc_path);
                    libsystem_available = true;
                    break :blk;
                }
            }
        }
        if (!libsystem_available) {
            const full_path = try comp.zig_lib_directory.join(arena, &[_][]const u8{
                "libc", "darwin", "libSystem.B.tbd",
            });
            try libs.append(full_path);
        }

        // frameworks
        var framework_dirs = std.ArrayList([]const u8).init(arena);
        for (self.base.options.framework_dirs) |dir| {
            if (try resolveSearchDir(arena, dir, self.base.options.sysroot)) |search_dir| {
                try framework_dirs.append(search_dir);
            } else {
                log.warn("directory not found for '-F{s}'", .{dir});
            }
        }

        var framework_not_found = false;
        for (self.base.options.frameworks) |framework| {
            for (&[_][]const u8{ ".tbd", ".dylib", "" }) |ext| {
                if (try resolveFramework(arena, framework_dirs.items, framework, ext)) |full_path| {
                    try libs.append(full_path);
                    break;
                }
            } else {
                log.warn("framework not found for '-framework {s}'", .{framework});
                framework_not_found = true;
            }
        }

        if (framework_not_found) {
            log.warn("Framework search paths:", .{});
            for (framework_dirs.items) |dir| {
                log.warn("  {s}", .{dir});
            }
        }

        // rpaths
        var rpath_table = std.StringArrayHashMap(void).init(arena);
        for (self.base.options.rpath_list) |rpath| {
            if (rpath_table.contains(rpath)) continue;
            try rpath_table.putNoClobber(rpath, {});
        }

        if (self.base.options.verbose_link) {
            var argv = std.ArrayList([]const u8).init(arena);

            try argv.append("zig");
            try argv.append("ld");

            if (is_exe_or_dyn_lib) {
                try argv.append("-dynamic");
            }

            if (is_dyn_lib) {
                try argv.append("-dylib");

                const install_name = try std.fmt.allocPrint(arena, "@rpath/{s}", .{
                    self.base.options.emit.?.sub_path,
                });
                try argv.append("-install_name");
                try argv.append(install_name);
            }

            if (self.base.options.sysroot) |syslibroot| {
                try argv.append("-syslibroot");
                try argv.append(syslibroot);
            }

            for (rpath_table.keys()) |rpath| {
                try argv.append("-rpath");
                try argv.append(rpath);
            }

            try argv.appendSlice(positionals.items);

            try argv.append("-o");
            try argv.append(full_out_path);

            try argv.append("-lSystem");
            try argv.append("-lc");

            for (search_lib_names.items) |l_name| {
                try argv.append(try std.fmt.allocPrint(arena, "-l{s}", .{l_name}));
            }

            for (self.base.options.lib_dirs) |lib_dir| {
                try argv.append(try std.fmt.allocPrint(arena, "-L{s}", .{lib_dir}));
            }

            for (self.base.options.frameworks) |framework| {
                try argv.append(try std.fmt.allocPrint(arena, "-framework {s}", .{framework}));
            }

            for (self.base.options.framework_dirs) |framework_dir| {
                try argv.append(try std.fmt.allocPrint(arena, "-F{s}", .{framework_dir}));
            }

            Compilation.dump_argv(argv.items);
        }

        try self.parseInputFiles(positionals.items, self.base.options.sysroot);
        try self.parseLibs(libs.items, self.base.options.sysroot);

        try self.resolveSymbols();
        try self.addRpathLCs(rpath_table.keys());
        try self.addLoadDylibLCs();
        try self.addDataInCodeLC();
        try self.addCodeSignatureLC();

        try self.parseTextBlocks();
        try self.allocateGlobalSymbols();
        {
            log.debug("locals:", .{});
            for (self.locals.items) |sym| {
                log.debug("  {s}: {}", .{ self.getString(sym.n_strx), sym });
            }
            log.debug("globals:", .{});
            for (self.globals.items) |sym| {
                log.debug("  {s}: {}", .{ self.getString(sym.n_strx), sym });
            }
            log.debug("undefs:", .{});
            for (self.undefs.items) |sym| {
                log.debug("  {s}: {}", .{ self.getString(sym.n_strx), sym });
            }
            log.debug("unresolved:", .{});
            for (self.unresolved.keys()) |key| {
                log.debug("  {d} => {s}", .{ key, self.unresolved.get(key).? });
            }
            log.debug("resolved:", .{});
            var it = self.symbol_resolver.iterator();
            while (it.next()) |entry| {
                log.debug("  {s} => {}", .{ self.getString(entry.key_ptr.*), entry.value_ptr.* });
            }
        }
        try self.writeAtoms();
        try self.flushModule(comp);
    }

    if (!self.base.options.disable_lld_caching) {
        // Update the file with the digest. If it fails we can continue; it only
        // means that the next invocation will have an unnecessary cache miss.
        Cache.writeSmallFile(directory.handle, id_symlink_basename, &digest) catch |err| {
            log.debug("failed to save linking hash digest file: {s}", .{@errorName(err)});
        };
        // Again failure here only means an unnecessary cache miss.
        man.writeManifest() catch |err| {
            log.debug("failed to write cache manifest when linking: {s}", .{@errorName(err)});
        };
        // We hang on to this lock so that the output file path can be used without
        // other processes clobbering it.
        self.base.lock = man.toOwnedLock();
    }
}

pub fn flushModule(self: *MachO, comp: *Compilation) !void {
    _ = comp;

    const tracy = trace(@src());
    defer tracy.end();

    try self.setEntryPoint();
    try self.updateSectionOrdinals();
    try self.writeLinkeditSegment();

    if (self.d_sym) |*ds| {
        // Flush debug symbols bundle.
        try ds.flushModule(self.base.allocator, self.base.options);
    }

    if (self.requires_adhoc_codesig) {
        // Preallocate space for the code signature.
        // We need to do this at this stage so that we have the load commands with proper values
        // written out to the file.
        // The most important here is to have the correct vm and filesize of the __LINKEDIT segment
        // where the code signature goes into.
        try self.writeCodeSignaturePadding();
    }

    try self.writeLoadCommands();
    try self.writeHeader();

    if (self.entry_addr == null and self.base.options.output_mode == .Exe) {
        log.debug("flushing. no_entry_point_found = true", .{});
        self.error_flags.no_entry_point_found = true;
    } else {
        log.debug("flushing. no_entry_point_found = false", .{});
        self.error_flags.no_entry_point_found = false;
    }

    assert(!self.load_commands_dirty);

    if (self.requires_adhoc_codesig) {
        try self.writeCodeSignature(); // code signing always comes last
    }
}

fn resolveSearchDir(
    arena: *Allocator,
    dir: []const u8,
    syslibroot: ?[]const u8,
) !?[]const u8 {
    var candidates = std.ArrayList([]const u8).init(arena);

    if (fs.path.isAbsolute(dir)) {
        if (syslibroot) |root| {
            const full_path = try fs.path.join(arena, &[_][]const u8{ root, dir });
            try candidates.append(full_path);
        }
    }

    try candidates.append(dir);

    for (candidates.items) |candidate| {
        // Verify that search path actually exists
        var tmp = fs.cwd().openDir(candidate, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        defer tmp.close();

        return candidate;
    }

    return null;
}

fn resolveLib(
    arena: *Allocator,
    search_dirs: []const []const u8,
    name: []const u8,
    ext: []const u8,
) !?[]const u8 {
    const search_name = try std.fmt.allocPrint(arena, "lib{s}{s}", .{ name, ext });

    for (search_dirs) |dir| {
        const full_path = try fs.path.join(arena, &[_][]const u8{ dir, search_name });

        // Check if the file exists.
        const tmp = fs.cwd().openFile(full_path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        defer tmp.close();

        return full_path;
    }

    return null;
}

fn resolveFramework(
    arena: *Allocator,
    search_dirs: []const []const u8,
    name: []const u8,
    ext: []const u8,
) !?[]const u8 {
    const search_name = try std.fmt.allocPrint(arena, "{s}{s}", .{ name, ext });
    const prefix_path = try std.fmt.allocPrint(arena, "{s}.framework", .{name});

    for (search_dirs) |dir| {
        const full_path = try fs.path.join(arena, &[_][]const u8{ dir, prefix_path, search_name });

        // Check if the file exists.
        const tmp = fs.cwd().openFile(full_path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        defer tmp.close();

        return full_path;
    }

    return null;
}

fn parseObject(self: *MachO, path: []const u8) !bool {
    const file = fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    errdefer file.close();

    const name = try self.base.allocator.dupe(u8, path);
    errdefer self.base.allocator.free(name);

    var object = Object{
        .name = name,
        .file = file,
    };

    object.parse(self.base.allocator, self.base.options.target) catch |err| switch (err) {
        error.EndOfStream, error.NotObject => {
            object.deinit(self.base.allocator);
            return false;
        },
        else => |e| return e,
    };

    try self.objects.append(self.base.allocator, object);

    return true;
}

fn parseArchive(self: *MachO, path: []const u8) !bool {
    const file = fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    errdefer file.close();

    const name = try self.base.allocator.dupe(u8, path);
    errdefer self.base.allocator.free(name);

    var archive = Archive{
        .name = name,
        .file = file,
    };

    archive.parse(self.base.allocator, self.base.options.target) catch |err| switch (err) {
        error.EndOfStream, error.NotArchive => {
            archive.deinit(self.base.allocator);
            return false;
        },
        else => |e| return e,
    };

    try self.archives.append(self.base.allocator, archive);

    return true;
}

const ParseDylibError = error{
    OutOfMemory,
    EmptyStubFile,
    MismatchedCpuArchitecture,
    UnsupportedCpuArchitecture,
} || fs.File.OpenError || std.os.PReadError || Dylib.Id.ParseError;

const DylibCreateOpts = struct {
    syslibroot: ?[]const u8 = null,
    id: ?Dylib.Id = null,
    is_dependent: bool = false,
};

pub fn parseDylib(self: *MachO, path: []const u8, opts: DylibCreateOpts) ParseDylibError!bool {
    const file = fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    errdefer file.close();

    const name = try self.base.allocator.dupe(u8, path);
    errdefer self.base.allocator.free(name);

    var dylib = Dylib{
        .name = name,
        .file = file,
    };

    dylib.parse(self.base.allocator, self.base.options.target) catch |err| switch (err) {
        error.EndOfStream, error.NotDylib => {
            try file.seekTo(0);

            var lib_stub = LibStub.loadFromFile(self.base.allocator, file) catch {
                dylib.deinit(self.base.allocator);
                return false;
            };
            defer lib_stub.deinit();

            try dylib.parseFromStub(self.base.allocator, self.base.options.target, lib_stub);
        },
        else => |e| return e,
    };

    if (opts.id) |id| {
        if (dylib.id.?.current_version < id.compatibility_version) {
            log.warn("found dylib is incompatible with the required minimum version", .{});
            log.warn("  dylib: {s}", .{id.name});
            log.warn("  required minimum version: {}", .{id.compatibility_version});
            log.warn("  dylib version: {}", .{dylib.id.?.current_version});

            // TODO maybe this should be an error and facilitate auto-cleanup?
            dylib.deinit(self.base.allocator);
            return false;
        }
    }

    const dylib_id = @intCast(u16, self.dylibs.items.len);
    try self.dylibs.append(self.base.allocator, dylib);
    try self.dylibs_map.putNoClobber(self.base.allocator, dylib.id.?.name, dylib_id);

    if (!(opts.is_dependent or self.referenced_dylibs.contains(dylib_id))) {
        try self.referenced_dylibs.putNoClobber(self.base.allocator, dylib_id, {});
    }

    // TODO this should not be performed if the user specifies `-flat_namespace` flag.
    // See ld64 manpages.
    try dylib.parseDependentLibs(self, opts.syslibroot);

    return true;
}

fn parseInputFiles(self: *MachO, files: []const []const u8, syslibroot: ?[]const u8) !void {
    for (files) |file_name| {
        const full_path = full_path: {
            var buffer: [fs.MAX_PATH_BYTES]u8 = undefined;
            const path = try std.fs.realpath(file_name, &buffer);
            break :full_path try self.base.allocator.dupe(u8, path);
        };
        defer self.base.allocator.free(full_path);
        log.debug("parsing input file path '{s}'", .{full_path});

        if (try self.parseObject(full_path)) continue;
        if (try self.parseArchive(full_path)) continue;
        if (try self.parseDylib(full_path, .{
            .syslibroot = syslibroot,
        })) continue;

        log.warn("unknown filetype for positional input file: '{s}'", .{file_name});
    }
}

fn parseLibs(self: *MachO, libs: []const []const u8, syslibroot: ?[]const u8) !void {
    for (libs) |lib| {
        log.debug("parsing lib path '{s}'", .{lib});
        if (try self.parseDylib(lib, .{
            .syslibroot = syslibroot,
        })) continue;
        if (try self.parseArchive(lib)) continue;

        log.warn("unknown filetype for a library: '{s}'", .{lib});
    }
}

pub const MatchingSection = struct {
    seg: u16,
    sect: u16,
};

pub fn getMatchingSection(self: *MachO, sect: macho.section_64) !?MatchingSection {
    const segname = commands.segmentName(sect);
    const sectname = commands.sectionName(sect);
    const res: ?MatchingSection = blk: {
        switch (commands.sectionType(sect)) {
            macho.S_4BYTE_LITERALS, macho.S_8BYTE_LITERALS, macho.S_16BYTE_LITERALS => {
                if (self.text_const_section_index == null) {
                    self.text_const_section_index = try self.allocateSection(
                        self.text_segment_cmd_index.?,
                        "__const",
                        sect.size,
                        sect.@"align",
                        .{},
                    );
                }

                break :blk .{
                    .seg = self.text_segment_cmd_index.?,
                    .sect = self.text_const_section_index.?,
                };
            },
            macho.S_CSTRING_LITERALS => {
                if (mem.eql(u8, sectname, "__objc_methname")) {
                    // TODO it seems the common values within the sections in objects are deduplicated/merged
                    // on merging the sections' contents.
                    if (self.objc_methname_section_index == null) {
                        self.objc_methname_section_index = try self.allocateSection(
                            self.text_segment_cmd_index.?,
                            "__objc_methname",
                            sect.size,
                            sect.@"align",
                            .{},
                        );
                    }

                    break :blk .{
                        .seg = self.text_segment_cmd_index.?,
                        .sect = self.objc_methname_section_index.?,
                    };
                } else if (mem.eql(u8, sectname, "__objc_methtype")) {
                    if (self.objc_methtype_section_index == null) {
                        self.objc_methtype_section_index = try self.allocateSection(
                            self.text_segment_cmd_index.?,
                            "__objc_methtype",
                            sect.size,
                            sect.@"align",
                            .{},
                        );
                    }

                    break :blk .{
                        .seg = self.text_segment_cmd_index.?,
                        .sect = self.objc_methtype_section_index.?,
                    };
                } else if (mem.eql(u8, sectname, "__objc_classname")) {
                    if (self.objc_classname_section_index == null) {
                        self.objc_classname_section_index = try self.allocateSection(
                            self.text_segment_cmd_index.?,
                            "__objc_classname",
                            sect.size,
                            sect.@"align",
                            .{},
                        );
                    }

                    break :blk .{
                        .seg = self.text_segment_cmd_index.?,
                        .sect = self.objc_classname_section_index.?,
                    };
                }

                if (self.cstring_section_index == null) {
                    self.cstring_section_index = try self.allocateSection(
                        self.text_segment_cmd_index.?,
                        "__cstring",
                        sect.size,
                        sect.@"align",
                        .{
                            .flags = macho.S_CSTRING_LITERALS,
                        },
                    );
                }

                break :blk .{
                    .seg = self.text_segment_cmd_index.?,
                    .sect = self.cstring_section_index.?,
                };
            },
            macho.S_LITERAL_POINTERS => {
                if (mem.eql(u8, segname, "__DATA") and mem.eql(u8, sectname, "__objc_selrefs")) {
                    if (self.objc_selrefs_section_index == null) {
                        self.objc_selrefs_section_index = try self.allocateSection(
                            self.data_segment_cmd_index.?,
                            "__objc_selrefs",
                            sect.size,
                            sect.@"align",
                            .{
                                .flags = macho.S_LITERAL_POINTERS,
                            },
                        );
                    }

                    break :blk .{
                        .seg = self.data_segment_cmd_index.?,
                        .sect = self.objc_selrefs_section_index.?,
                    };
                } else {
                    // TODO investigate
                    break :blk null;
                }
            },
            macho.S_MOD_INIT_FUNC_POINTERS => {
                if (self.mod_init_func_section_index == null) {
                    self.mod_init_func_section_index = try self.allocateSection(
                        self.data_const_segment_cmd_index.?,
                        "__mod_init_func",
                        sect.size,
                        sect.@"align",
                        .{
                            .flags = macho.S_MOD_INIT_FUNC_POINTERS,
                        },
                    );
                }

                break :blk .{
                    .seg = self.data_const_segment_cmd_index.?,
                    .sect = self.mod_init_func_section_index.?,
                };
            },
            macho.S_MOD_TERM_FUNC_POINTERS => {
                if (self.mod_term_func_section_index == null) {
                    self.mod_term_func_section_index = try self.allocateSection(
                        self.data_const_segment_cmd_index.?,
                        "__mod_term_func",
                        sect.size,
                        sect.@"align",
                        .{
                            .flags = macho.S_MOD_TERM_FUNC_POINTERS,
                        },
                    );
                }

                break :blk .{
                    .seg = self.data_const_segment_cmd_index.?,
                    .sect = self.mod_term_func_section_index.?,
                };
            },
            macho.S_ZEROFILL => {
                if (self.bss_section_index == null) {
                    self.bss_section_index = try self.allocateSection(
                        self.data_segment_cmd_index.?,
                        "__bss",
                        sect.size,
                        sect.@"align",
                        .{
                            .flags = macho.S_ZEROFILL,
                        },
                    );
                }

                break :blk .{
                    .seg = self.data_segment_cmd_index.?,
                    .sect = self.bss_section_index.?,
                };
            },
            macho.S_THREAD_LOCAL_VARIABLES => {
                if (self.tlv_section_index == null) {
                    self.tlv_section_index = try self.allocateSection(
                        self.data_segment_cmd_index.?,
                        "__thread_vars",
                        sect.size,
                        sect.@"align",
                        .{
                            .flags = macho.S_THREAD_LOCAL_VARIABLES,
                        },
                    );
                }

                break :blk .{
                    .seg = self.data_segment_cmd_index.?,
                    .sect = self.tlv_section_index.?,
                };
            },
            macho.S_THREAD_LOCAL_REGULAR => {
                if (self.tlv_data_section_index == null) {
                    self.tlv_data_section_index = try self.allocateSection(
                        self.data_segment_cmd_index.?,
                        "__thread_data",
                        sect.size,
                        sect.@"align",
                        .{
                            .flags = macho.S_THREAD_LOCAL_REGULAR,
                        },
                    );
                }

                break :blk .{
                    .seg = self.data_segment_cmd_index.?,
                    .sect = self.tlv_data_section_index.?,
                };
            },
            macho.S_THREAD_LOCAL_ZEROFILL => {
                if (self.tlv_bss_section_index == null) {
                    self.tlv_bss_section_index = try self.allocateSection(
                        self.data_segment_cmd_index.?,
                        "__thread_bss",
                        sect.size,
                        sect.@"align",
                        .{
                            .flags = macho.S_THREAD_LOCAL_ZEROFILL,
                        },
                    );
                }

                break :blk .{
                    .seg = self.data_segment_cmd_index.?,
                    .sect = self.tlv_bss_section_index.?,
                };
            },
            macho.S_COALESCED => {
                if (mem.eql(u8, "__TEXT", segname) and mem.eql(u8, "__eh_frame", sectname)) {
                    // TODO I believe __eh_frame is currently part of __unwind_info section
                    // in the latest ld64 output.
                    if (self.eh_frame_section_index == null) {
                        self.eh_frame_section_index = try self.allocateSection(
                            self.text_segment_cmd_index.?,
                            "__eh_frame",
                            sect.size,
                            sect.@"align",
                            .{},
                        );
                    }

                    break :blk .{
                        .seg = self.text_segment_cmd_index.?,
                        .sect = self.eh_frame_section_index.?,
                    };
                }

                // TODO audit this: is this the right mapping?
                if (self.data_const_section_index == null) {
                    self.data_const_section_index = try self.allocateSection(
                        self.data_const_segment_cmd_index.?,
                        "__const",
                        sect.size,
                        sect.@"align",
                        .{},
                    );
                }

                break :blk .{
                    .seg = self.data_const_segment_cmd_index.?,
                    .sect = self.data_const_section_index.?,
                };
            },
            macho.S_REGULAR => {
                if (commands.sectionIsCode(sect)) {
                    if (self.text_section_index == null) {
                        self.text_section_index = try self.allocateSection(
                            self.text_segment_cmd_index.?,
                            "__text",
                            sect.size,
                            sect.@"align",
                            .{
                                .flags = macho.S_REGULAR |
                                    macho.S_ATTR_PURE_INSTRUCTIONS |
                                    macho.S_ATTR_SOME_INSTRUCTIONS,
                            },
                        );
                    }

                    break :blk .{
                        .seg = self.text_segment_cmd_index.?,
                        .sect = self.text_section_index.?,
                    };
                }
                if (commands.sectionIsDebug(sect)) {
                    // TODO debug attributes
                    if (mem.eql(u8, "__LD", segname) and mem.eql(u8, "__compact_unwind", sectname)) {
                        log.debug("TODO compact unwind section: type 0x{x}, name '{s},{s}'", .{
                            sect.flags, segname, sectname,
                        });
                    }
                    break :blk null;
                }

                if (mem.eql(u8, segname, "__TEXT")) {
                    if (mem.eql(u8, sectname, "__ustring")) {
                        if (self.ustring_section_index == null) {
                            self.ustring_section_index = try self.allocateSection(
                                self.text_segment_cmd_index.?,
                                "__ustring",
                                sect.size,
                                sect.@"align",
                                .{},
                            );
                        }

                        break :blk .{
                            .seg = self.text_segment_cmd_index.?,
                            .sect = self.ustring_section_index.?,
                        };
                    } else if (mem.eql(u8, sectname, "__gcc_except_tab")) {
                        if (self.gcc_except_tab_section_index == null) {
                            self.gcc_except_tab_section_index = try self.allocateSection(
                                self.text_segment_cmd_index.?,
                                "__gcc_except_tab",
                                sect.size,
                                sect.@"align",
                                .{},
                            );
                        }

                        break :blk .{
                            .seg = self.text_segment_cmd_index.?,
                            .sect = self.gcc_except_tab_section_index.?,
                        };
                    } else if (mem.eql(u8, sectname, "__objc_methlist")) {
                        if (self.objc_methlist_section_index == null) {
                            self.objc_methlist_section_index = try self.allocateSection(
                                self.text_segment_cmd_index.?,
                                "__objc_methlist",
                                sect.size,
                                sect.@"align",
                                .{},
                            );
                        }

                        break :blk .{
                            .seg = self.text_segment_cmd_index.?,
                            .sect = self.objc_methlist_section_index.?,
                        };
                    } else if (mem.eql(u8, sectname, "__rodata") or
                        mem.eql(u8, sectname, "__typelink") or
                        mem.eql(u8, sectname, "__itablink") or
                        mem.eql(u8, sectname, "__gosymtab") or
                        mem.eql(u8, sectname, "__gopclntab"))
                    {
                        if (self.data_const_section_index == null) {
                            self.data_const_section_index = try self.allocateSection(
                                self.data_const_segment_cmd_index.?,
                                "__const",
                                sect.size,
                                sect.@"align",
                                .{},
                            );
                        }

                        break :blk .{
                            .seg = self.data_const_segment_cmd_index.?,
                            .sect = self.data_const_section_index.?,
                        };
                    } else {
                        if (self.text_const_section_index == null) {
                            self.text_const_section_index = try self.allocateSection(
                                self.text_segment_cmd_index.?,
                                "__const",
                                sect.size,
                                sect.@"align",
                                .{},
                            );
                        }

                        break :blk .{
                            .seg = self.text_segment_cmd_index.?,
                            .sect = self.text_const_section_index.?,
                        };
                    }
                }

                if (mem.eql(u8, segname, "__DATA_CONST")) {
                    if (self.data_const_section_index == null) {
                        self.data_const_section_index = try self.allocateSection(
                            self.data_const_segment_cmd_index.?,
                            "__const",
                            sect.size,
                            sect.@"align",
                            .{},
                        );
                    }

                    break :blk .{
                        .seg = self.data_const_segment_cmd_index.?,
                        .sect = self.data_const_section_index.?,
                    };
                }

                if (mem.eql(u8, segname, "__DATA")) {
                    if (mem.eql(u8, sectname, "__const")) {
                        if (self.data_const_section_index == null) {
                            self.data_const_section_index = try self.allocateSection(
                                self.data_const_segment_cmd_index.?,
                                "__const",
                                sect.size,
                                sect.@"align",
                                .{},
                            );
                        }

                        break :blk .{
                            .seg = self.data_const_segment_cmd_index.?,
                            .sect = self.data_const_section_index.?,
                        };
                    } else if (mem.eql(u8, sectname, "__cfstring")) {
                        if (self.objc_cfstring_section_index == null) {
                            self.objc_cfstring_section_index = try self.allocateSection(
                                self.data_const_segment_cmd_index.?,
                                "__cfstring",
                                sect.size,
                                sect.@"align",
                                .{},
                            );
                        }

                        break :blk .{
                            .seg = self.data_const_segment_cmd_index.?,
                            .sect = self.objc_cfstring_section_index.?,
                        };
                    } else if (mem.eql(u8, sectname, "__objc_classlist")) {
                        if (self.objc_classlist_section_index == null) {
                            self.objc_classlist_section_index = try self.allocateSection(
                                self.data_const_segment_cmd_index.?,
                                "__objc_classlist",
                                sect.size,
                                sect.@"align",
                                .{},
                            );
                        }

                        break :blk .{
                            .seg = self.data_const_segment_cmd_index.?,
                            .sect = self.objc_classlist_section_index.?,
                        };
                    } else if (mem.eql(u8, sectname, "__objc_imageinfo")) {
                        if (self.objc_imageinfo_section_index == null) {
                            self.objc_imageinfo_section_index = try self.allocateSection(
                                self.data_const_segment_cmd_index.?,
                                "__objc_imageinfo",
                                sect.size,
                                sect.@"align",
                                .{},
                            );
                        }

                        break :blk .{
                            .seg = self.data_const_segment_cmd_index.?,
                            .sect = self.objc_imageinfo_section_index.?,
                        };
                    } else if (mem.eql(u8, sectname, "__objc_const")) {
                        if (self.objc_const_section_index == null) {
                            self.objc_const_section_index = try self.allocateSection(
                                self.data_segment_cmd_index.?,
                                "__objc_const",
                                sect.size,
                                sect.@"align",
                                .{},
                            );
                        }

                        break :blk .{
                            .seg = self.data_segment_cmd_index.?,
                            .sect = self.objc_const_section_index.?,
                        };
                    } else if (mem.eql(u8, sectname, "__objc_classrefs")) {
                        if (self.objc_classrefs_section_index == null) {
                            self.objc_classrefs_section_index = try self.allocateSection(
                                self.data_segment_cmd_index.?,
                                "__objc_classrefs",
                                sect.size,
                                sect.@"align",
                                .{},
                            );
                        }

                        break :blk .{
                            .seg = self.data_segment_cmd_index.?,
                            .sect = self.objc_classrefs_section_index.?,
                        };
                    } else if (mem.eql(u8, sectname, "__objc_data")) {
                        if (self.objc_data_section_index == null) {
                            self.objc_data_section_index = try self.allocateSection(
                                self.data_segment_cmd_index.?,
                                "__objc_data",
                                sect.size,
                                sect.@"align",
                                .{},
                            );
                        }

                        break :blk .{
                            .seg = self.data_segment_cmd_index.?,
                            .sect = self.objc_data_section_index.?,
                        };
                    } else {
                        if (self.data_section_index == null) {
                            self.data_section_index = try self.allocateSection(
                                self.data_segment_cmd_index.?,
                                "__data",
                                sect.size,
                                sect.@"align",
                                .{},
                            );
                        }

                        break :blk .{
                            .seg = self.data_segment_cmd_index.?,
                            .sect = self.data_section_index.?,
                        };
                    }
                }

                if (mem.eql(u8, "__LLVM", segname) and mem.eql(u8, "__asm", sectname)) {
                    log.debug("TODO LLVM asm section: type 0x{x}, name '{s},{s}'", .{
                        sect.flags, segname, sectname,
                    });
                }

                break :blk null;
            },
            else => break :blk null,
        }
    };
    return res;
}

pub fn createEmptyAtom(self: *MachO, local_sym_index: u32, size: u64, alignment: u32) !*TextBlock {
    const code = try self.base.allocator.alloc(u8, size);
    defer self.base.allocator.free(code);
    mem.set(u8, code, 0);

    const atom = try self.base.allocator.create(TextBlock);
    errdefer self.base.allocator.destroy(atom);
    atom.* = TextBlock.empty;
    atom.local_sym_index = local_sym_index;
    atom.size = size;
    atom.alignment = alignment;
    try atom.code.appendSlice(self.base.allocator, code);
    try self.managed_blocks.append(self.base.allocator, atom);

    return atom;
}

pub fn allocateAtom(self: *MachO, atom: *TextBlock, match: MatchingSection) !u64 {
    const seg = &self.load_commands.items[match.seg].Segment;
    const sect = &seg.sections.items[match.sect];

    const sym = &self.locals.items[atom.local_sym_index];
    const needs_padding = match.seg == self.text_segment_cmd_index.? and match.sect == self.text_section_index.?;

    var atom_placement: ?*TextBlock = null;

    // TODO converge with `allocateTextBlock` and handle free list
    var vaddr = if (self.blocks.get(match)) |last| blk: {
        const last_atom_sym = self.locals.items[last.local_sym_index];
        const ideal_capacity = if (needs_padding) padToIdeal(last.size) else last.size;
        const ideal_capacity_end_vaddr = last_atom_sym.n_value + ideal_capacity;
        const last_atom_alignment = try math.powi(u32, 2, atom.alignment);
        const new_start_vaddr = mem.alignForwardGeneric(u64, ideal_capacity_end_vaddr, last_atom_alignment);
        atom_placement = last;
        break :blk new_start_vaddr;
    } else sect.addr;

    log.debug("allocating atom for symbol {s} at address 0x{x}", .{ self.getString(sym.n_strx), vaddr });

    const expand_section = atom_placement == null or atom_placement.?.next == null;
    if (expand_section) {
        const needed_size = (vaddr + atom.size) - sect.addr;
        const sect_offset = self.getPtrToSectionOffset(match);
        const file_offset = sect_offset.* + vaddr - sect.addr;
        const max_size = seg.allocatedSize(file_offset);
        log.debug("  (section {s},{s} needed size 0x{x}, max available size 0x{x})", .{
            commands.segmentName(sect.*),
            commands.sectionName(sect.*),
            needed_size,
            max_size,
        });

        if (needed_size > max_size) {
            const old_base_addr = sect.addr;
            sect.size = 0;
            const padding: ?u64 = if (match.seg == self.text_segment_cmd_index.?) self.header_pad else null;
            const atom_alignment = try math.powi(u64, 2, atom.alignment);
            const new_offset = @intCast(u32, seg.findFreeSpace(needed_size, atom_alignment, padding));

            if (new_offset + needed_size >= seg.inner.fileoff + seg.inner.filesize) {
                // Bummer, need to move all segments below down...
                // TODO is this the right estimate?
                const new_seg_size = mem.alignForwardGeneric(
                    u64,
                    padToIdeal(seg.inner.filesize + needed_size),
                    self.page_size,
                );
                // TODO actually, we're always required to move in a number of pages so I guess all we need
                // to know here is the number of pages to shift downwards.
                const offset_amt = @intCast(u32, @intCast(i64, new_seg_size) - @intCast(i64, seg.inner.filesize));
                seg.inner.filesize = new_seg_size;
                seg.inner.vmsize = new_seg_size;
                log.debug("  (new {s} segment file offsets from 0x{x} to 0x{x} (in memory 0x{x} to 0x{x}))", .{
                    seg.inner.segname,
                    seg.inner.fileoff,
                    seg.inner.fileoff + seg.inner.filesize,
                    seg.inner.vmaddr,
                    seg.inner.vmaddr + seg.inner.vmsize,
                });
                // TODO We should probably nop the expanded by distance, or put 0s.

                // TODO copyRangeAll doesn't automatically extend the file on macOS.
                const ledit_seg = &self.load_commands.items[self.linkedit_segment_cmd_index.?].Segment;
                const new_filesize = offset_amt + ledit_seg.inner.fileoff + ledit_seg.inner.filesize;
                try self.base.file.?.pwriteAll(&[_]u8{0}, new_filesize - 1);

                var next: usize = match.seg + 1;
                while (next < self.linkedit_segment_cmd_index.? + 1) : (next += 1) {
                    const next_seg = &self.load_commands.items[next].Segment;
                    _ = try self.base.file.?.copyRangeAll(
                        next_seg.inner.fileoff,
                        self.base.file.?,
                        next_seg.inner.fileoff + offset_amt,
                        next_seg.inner.filesize,
                    );
                    next_seg.inner.fileoff += offset_amt;
                    next_seg.inner.vmaddr += offset_amt;
                    log.debug("  (new {s} segment file offsets from 0x{x} to 0x{x} (in memory 0x{x} to 0x{x}))", .{
                        next_seg.inner.segname,
                        next_seg.inner.fileoff,
                        next_seg.inner.fileoff + next_seg.inner.filesize,
                        next_seg.inner.vmaddr,
                        next_seg.inner.vmaddr + next_seg.inner.vmsize,
                    });

                    for (next_seg.sections.items) |*moved_sect, moved_sect_id| {
                        const moved_match = MatchingSection{
                            .seg = @intCast(u16, next),
                            .sect = @intCast(u16, moved_sect_id),
                        };
                        const ptr_sect_offset = self.getPtrToSectionOffset(moved_match);
                        ptr_sect_offset.* += offset_amt;
                        moved_sect.addr += offset_amt;
                        log.debug("  (new {s},{s} file offsets from 0x{x} to 0x{x} (in memory 0x{x} to 0x{x}))", .{
                            commands.segmentName(moved_sect.*),
                            commands.sectionName(moved_sect.*),
                            ptr_sect_offset.*,
                            ptr_sect_offset.* + moved_sect.size,
                            moved_sect.addr,
                            moved_sect.addr + moved_sect.size,
                        });

                        try self.allocateLocalSymbols(moved_match, offset_amt);
                    }
                }
            }
            sect_offset.* = new_offset;
            sect.addr = seg.inner.vmaddr + sect_offset.* - seg.inner.fileoff;
            log.debug("  (found new {s},{s} free space from 0x{x} to 0x{x})", .{
                commands.segmentName(sect.*),
                commands.sectionName(sect.*),
                new_offset,
                new_offset + needed_size,
            });
            const offset_amt = @intCast(i64, sect.addr) - @intCast(i64, old_base_addr);
            try self.allocateLocalSymbols(match, offset_amt);
            vaddr = @intCast(u64, @intCast(i64, vaddr) + offset_amt);
        }

        sect.size = needed_size;
        self.load_commands_dirty = true;
    }
    const n_sect = @intCast(u8, self.section_ordinals.getIndex(match).? + 1);
    sym.n_value = vaddr;
    sym.n_sect = n_sect;

    // Update each alias (if any)
    for (atom.aliases.items) |index| {
        const alias_sym = &self.locals.items[index];
        alias_sym.n_value = vaddr;
        alias_sym.n_sect = n_sect;
    }

    // Update each symbol contained within the TextBlock
    for (atom.contained.items) |sym_at_off| {
        const contained_sym = &self.locals.items[sym_at_off.local_sym_index];
        contained_sym.n_value = vaddr + sym_at_off.offset;
        contained_sym.n_sect = n_sect;
    }

    if (self.blocks.getPtr(match)) |last| {
        last.*.next = atom;
        atom.prev = last.*;
        last.* = atom;
    } else {
        try self.blocks.putNoClobber(self.base.allocator, match, atom);
    }

    return vaddr;
}

pub fn writeAtom(self: *MachO, atom: *TextBlock, match: MatchingSection) !void {
    const seg = self.load_commands.items[match.seg].Segment;
    const sect = seg.sections.items[match.sect];
    const sym = self.locals.items[atom.local_sym_index];
    const sect_offset = self.getPtrToSectionOffset(match).*;
    const file_offset = sect_offset + sym.n_value - sect.addr;
    try atom.resolveRelocs(self);
    log.debug("writing atom for symbol {s} at file offset 0x{x}", .{ self.getString(sym.n_strx), file_offset });
    try self.base.file.?.pwriteAll(atom.code.items, file_offset);
}

fn allocateLocalSymbols(self: *MachO, match: MatchingSection, offset: i64) !void {
    var atom = self.blocks.get(match) orelse return;

    while (true) {
        const atom_sym = &self.locals.items[atom.local_sym_index];
        atom_sym.n_value = @intCast(u64, @intCast(i64, atom_sym.n_value) + offset);

        for (atom.aliases.items) |index| {
            const alias_sym = &self.locals.items[index];
            alias_sym.n_value = @intCast(u64, @intCast(i64, alias_sym.n_value) + offset);
        }

        for (atom.contained.items) |sym_at_off| {
            const contained_sym = &self.locals.items[sym_at_off.local_sym_index];
            contained_sym.n_value = @intCast(u64, @intCast(i64, contained_sym.n_value) + offset);
        }

        if (atom.prev) |prev| {
            atom = prev;
        } else break;
    }
}

fn allocateGlobalSymbols(self: *MachO) !void {
    // TODO should we do this in `allocateAtom` (or similar)? Then, we would need to
    // store the link atom -> globals somewhere.
    var sym_it = self.symbol_resolver.valueIterator();
    while (sym_it.next()) |resolv| {
        if (resolv.where != .global) continue;

        assert(resolv.local_sym_index != 0);
        const local_sym = self.locals.items[resolv.local_sym_index];
        const sym = &self.globals.items[resolv.where_index];
        sym.n_value = local_sym.n_value;
        sym.n_sect = local_sym.n_sect;
    }
}

fn writeAtoms(self: *MachO) !void {
    var it = self.blocks.iterator();
    while (it.next()) |entry| {
        const match = entry.key_ptr.*;
        var atom: *TextBlock = entry.value_ptr.*;

        while (atom.prev) |prev| {
            try self.writeAtom(atom, match);
            atom = prev;
        }
        try self.writeAtom(atom, match);
    }
}

pub fn createGotAtom(self: *MachO, key: GotIndirectionKey) !*TextBlock {
    const local_sym_index = @intCast(u32, self.locals.items.len);
    try self.locals.append(self.base.allocator, .{
        .n_strx = try self.makeString("l_zld_got_entry"),
        .n_type = macho.N_SECT,
        .n_sect = 0,
        .n_desc = 0,
        .n_value = 0,
    });
    const atom = try self.createEmptyAtom(local_sym_index, @sizeOf(u64), 3);
    switch (key.where) {
        .local => {
            try atom.relocs.append(self.base.allocator, .{
                .offset = 0,
                .where = .local,
                .where_index = key.where_index,
                .payload = .{
                    .unsigned = .{
                        .subtractor = null,
                        .addend = 0,
                        .is_64bit = true,
                    },
                },
            });
            try atom.rebases.append(self.base.allocator, 0);
        },
        .undef => {
            try atom.bindings.append(self.base.allocator, .{
                .local_sym_index = key.where_index,
                .offset = 0,
            });
        },
    }
    return atom;
}

fn createDyldPrivateAtom(self: *MachO) !*TextBlock {
    const local_sym_index = @intCast(u32, self.locals.items.len);
    try self.locals.append(self.base.allocator, .{
        .n_strx = try self.makeString("l_zld_dyld_private"),
        .n_type = macho.N_SECT,
        .n_sect = 0,
        .n_desc = 0,
        .n_value = 0,
    });
    self.dyld_private_sym_index = local_sym_index;
    return self.createEmptyAtom(local_sym_index, @sizeOf(u64), 3);
}

fn createStubHelperPreambleAtom(self: *MachO) !*TextBlock {
    const arch = self.base.options.target.cpu.arch;
    const size: u64 = switch (arch) {
        .x86_64 => 15,
        .aarch64 => 6 * @sizeOf(u32),
        else => unreachable,
    };
    const alignment: u32 = switch (arch) {
        .x86_64 => 0,
        .aarch64 => 2,
        else => unreachable,
    };
    const local_sym_index = @intCast(u32, self.locals.items.len);
    try self.locals.append(self.base.allocator, .{
        .n_strx = try self.makeString("l_zld_stub_preamble"),
        .n_type = macho.N_SECT,
        .n_sect = 0,
        .n_desc = 0,
        .n_value = 0,
    });
    const atom = try self.createEmptyAtom(local_sym_index, size, alignment);
    switch (arch) {
        .x86_64 => {
            try atom.relocs.ensureUnusedCapacity(self.base.allocator, 2);
            // lea %r11, [rip + disp]
            atom.code.items[0] = 0x4c;
            atom.code.items[1] = 0x8d;
            atom.code.items[2] = 0x1d;
            atom.relocs.appendAssumeCapacity(.{
                .offset = 3,
                .where = .local,
                .where_index = self.dyld_private_sym_index.?,
                .payload = .{
                    .signed = .{
                        .addend = 0,
                        .correction = 0,
                    },
                },
            });
            // push %r11
            atom.code.items[7] = 0x41;
            atom.code.items[8] = 0x53;
            // jmp [rip + disp]
            atom.code.items[9] = 0xff;
            atom.code.items[10] = 0x25;
            atom.relocs.appendAssumeCapacity(.{
                .offset = 11,
                .where = .undef,
                .where_index = self.dyld_stub_binder_index.?,
                .payload = .{
                    .load = .{
                        .kind = .got,
                        .addend = 0,
                    },
                },
            });
        },
        .aarch64 => {
            try atom.relocs.ensureUnusedCapacity(self.base.allocator, 4);
            // adrp x17, 0
            mem.writeIntLittle(u32, atom.code.items[0..][0..4], aarch64.Instruction.adrp(.x17, 0).toU32());
            atom.relocs.appendAssumeCapacity(.{
                .offset = 0,
                .where = .local,
                .where_index = self.dyld_private_sym_index.?,
                .payload = .{
                    .page = .{
                        .kind = .page,
                        .addend = 0,
                    },
                },
            });
            // add x17, x17, 0
            mem.writeIntLittle(u32, atom.code.items[4..][0..4], aarch64.Instruction.add(.x17, .x17, 0, false).toU32());
            atom.relocs.appendAssumeCapacity(.{
                .offset = 4,
                .where = .local,
                .where_index = self.dyld_private_sym_index.?,
                .payload = .{
                    .page_off = .{
                        .kind = .page,
                        .addend = 0,
                        .op_kind = .arithmetic,
                    },
                },
            });
            // stp x16, x17, [sp, #-16]!
            mem.writeIntLittle(u32, atom.code.items[8..][0..4], aarch64.Instruction.stp(
                .x16,
                .x17,
                aarch64.Register.sp,
                aarch64.Instruction.LoadStorePairOffset.pre_index(-16),
            ).toU32());
            // adrp x16, 0
            mem.writeIntLittle(u32, atom.code.items[12..][0..4], aarch64.Instruction.adrp(.x16, 0).toU32());
            atom.relocs.appendAssumeCapacity(.{
                .offset = 12,
                .where = .undef,
                .where_index = self.dyld_stub_binder_index.?,
                .payload = .{
                    .page = .{
                        .kind = .got,
                        .addend = 0,
                    },
                },
            });
            // ldr x16, [x16, 0]
            mem.writeIntLittle(u32, atom.code.items[16..][0..4], aarch64.Instruction.ldr(.x16, .{
                .register = .{
                    .rn = .x16,
                    .offset = aarch64.Instruction.LoadStoreOffset.imm(0),
                },
            }).toU32());
            atom.relocs.appendAssumeCapacity(.{
                .offset = 16,
                .where = .undef,
                .where_index = self.dyld_stub_binder_index.?,
                .payload = .{
                    .page_off = .{
                        .kind = .got,
                        .addend = 0,
                    },
                },
            });
            // br x16
            mem.writeIntLittle(u32, atom.code.items[20..][0..4], aarch64.Instruction.br(.x16).toU32());
        },
        else => unreachable,
    }
    self.stub_preamble_sym_index = local_sym_index;
    return atom;
}

pub fn createStubHelperAtom(self: *MachO) !*TextBlock {
    const arch = self.base.options.target.cpu.arch;
    const stub_size: u4 = switch (arch) {
        .x86_64 => 10,
        .aarch64 => 3 * @sizeOf(u32),
        else => unreachable,
    };
    const alignment: u2 = switch (arch) {
        .x86_64 => 0,
        .aarch64 => 2,
        else => unreachable,
    };
    const local_sym_index = @intCast(u32, self.locals.items.len);
    try self.locals.append(self.base.allocator, .{
        .n_strx = try self.makeString("l_zld_stub_in_stub_helper"),
        .n_type = macho.N_SECT,
        .n_sect = 0,
        .n_desc = 0,
        .n_value = 0,
    });
    const atom = try self.createEmptyAtom(local_sym_index, stub_size, alignment);
    try atom.relocs.ensureTotalCapacity(self.base.allocator, 1);

    switch (arch) {
        .x86_64 => {
            // pushq
            atom.code.items[0] = 0x68;
            // Next 4 bytes 1..4 are just a placeholder populated in `populateLazyBindOffsetsInStubHelper`.
            // jmpq
            atom.code.items[5] = 0xe9;
            atom.relocs.appendAssumeCapacity(.{
                .offset = 6,
                .where = .local,
                .where_index = self.stub_preamble_sym_index.?,
                .payload = .{
                    .branch = .{ .arch = arch },
                },
            });
        },
        .aarch64 => {
            const literal = blk: {
                const div_res = try math.divExact(u64, stub_size - @sizeOf(u32), 4);
                break :blk try math.cast(u18, div_res);
            };
            // ldr w16, literal
            mem.writeIntLittle(u32, atom.code.items[0..4], aarch64.Instruction.ldr(.w16, .{
                .literal = literal,
            }).toU32());
            // b disp
            mem.writeIntLittle(u32, atom.code.items[4..8], aarch64.Instruction.b(0).toU32());
            atom.relocs.appendAssumeCapacity(.{
                .offset = 4,
                .where = .local,
                .where_index = self.stub_preamble_sym_index.?,
                .payload = .{
                    .branch = .{ .arch = arch },
                },
            });
            // Next 4 bytes 8..12 are just a placeholder populated in `populateLazyBindOffsetsInStubHelper`.
        },
        else => unreachable,
    }

    return atom;
}

pub fn createLazyPointerAtom(self: *MachO, stub_sym_index: u32, lazy_binding_sym_index: u32) !*TextBlock {
    const local_sym_index = @intCast(u32, self.locals.items.len);
    try self.locals.append(self.base.allocator, .{
        .n_strx = try self.makeString("l_zld_lazy_ptr"),
        .n_type = macho.N_SECT,
        .n_sect = 0,
        .n_desc = 0,
        .n_value = 0,
    });
    const atom = try self.createEmptyAtom(local_sym_index, @sizeOf(u64), 3);
    try atom.relocs.append(self.base.allocator, .{
        .offset = 0,
        .where = .local,
        .where_index = stub_sym_index,
        .payload = .{
            .unsigned = .{
                .subtractor = null,
                .addend = 0,
                .is_64bit = true,
            },
        },
    });
    try atom.rebases.append(self.base.allocator, 0);
    try atom.lazy_bindings.append(self.base.allocator, .{
        .local_sym_index = lazy_binding_sym_index,
        .offset = 0,
    });
    return atom;
}

pub fn createStubAtom(self: *MachO, laptr_sym_index: u32) !*TextBlock {
    const arch = self.base.options.target.cpu.arch;
    const alignment: u2 = switch (arch) {
        .x86_64 => 0,
        .aarch64 => 2,
        else => unreachable, // unhandled architecture type
    };
    const stub_size: u4 = switch (arch) {
        .x86_64 => 6,
        .aarch64 => 3 * @sizeOf(u32),
        else => unreachable, // unhandled architecture type
    };
    const local_sym_index = @intCast(u32, self.locals.items.len);
    try self.locals.append(self.base.allocator, .{
        .n_strx = try self.makeString("l_zld_stub"),
        .n_type = macho.N_SECT,
        .n_sect = 0,
        .n_desc = 0,
        .n_value = 0,
    });
    const atom = try self.createEmptyAtom(local_sym_index, stub_size, alignment);
    switch (arch) {
        .x86_64 => {
            // jmp
            atom.code.items[0] = 0xff;
            atom.code.items[1] = 0x25;
            try atom.relocs.append(self.base.allocator, .{
                .offset = 2,
                .where = .local,
                .where_index = laptr_sym_index,
                .payload = .{
                    .branch = .{ .arch = arch },
                },
            });
        },
        .aarch64 => {
            try atom.relocs.ensureTotalCapacity(self.base.allocator, 2);
            // adrp x16, pages
            mem.writeIntLittle(u32, atom.code.items[0..4], aarch64.Instruction.adrp(.x16, 0).toU32());
            atom.relocs.appendAssumeCapacity(.{
                .offset = 0,
                .where = .local,
                .where_index = laptr_sym_index,
                .payload = .{
                    .page = .{
                        .kind = .page,
                        .addend = 0,
                    },
                },
            });
            // ldr x16, x16, offset
            mem.writeIntLittle(u32, atom.code.items[4..8], aarch64.Instruction.ldr(.x16, .{
                .register = .{
                    .rn = .x16,
                    .offset = aarch64.Instruction.LoadStoreOffset.imm(0),
                },
            }).toU32());
            atom.relocs.appendAssumeCapacity(.{
                .offset = 4,
                .where = .local,
                .where_index = laptr_sym_index,
                .payload = .{
                    .page_off = .{
                        .kind = .page,
                        .addend = 0,
                        .op_kind = .load,
                    },
                },
            });
            // br x16
            mem.writeIntLittle(u32, atom.code.items[8..12], aarch64.Instruction.br(.x16).toU32());
        },
        else => unreachable,
    }
    return atom;
}

fn resolveSymbolsInObject(
    self: *MachO,
    object_id: u16,
    tentatives: *std.AutoArrayHashMap(u32, void),
) !void {
    const object = &self.objects.items[object_id];

    log.debug("resolving symbols in '{s}'", .{object.name});

    for (object.symtab.items) |sym, id| {
        const sym_id = @intCast(u32, id);
        const sym_name = object.getString(sym.n_strx);

        if (symbolIsStab(sym)) {
            log.err("unhandled symbol type: stab", .{});
            log.err("  symbol '{s}'", .{sym_name});
            log.err("  first definition in '{s}'", .{object.name});
            return error.UnhandledSymbolType;
        }

        if (symbolIsIndr(sym)) {
            log.err("unhandled symbol type: indirect", .{});
            log.err("  symbol '{s}'", .{sym_name});
            log.err("  first definition in '{s}'", .{object.name});
            return error.UnhandledSymbolType;
        }

        if (symbolIsAbs(sym)) {
            log.err("unhandled symbol type: absolute", .{});
            log.err("  symbol '{s}'", .{sym_name});
            log.err("  first definition in '{s}'", .{object.name});
            return error.UnhandledSymbolType;
        }

        const n_strx = try self.makeString(sym_name);
        if (symbolIsSect(sym)) {
            // Defined symbol regardless of scope lands in the locals symbol table.
            const local_sym_index = @intCast(u32, self.locals.items.len);
            try self.locals.append(self.base.allocator, .{
                .n_strx = n_strx,
                .n_type = macho.N_SECT,
                .n_sect = 0,
                .n_desc = 0,
                .n_value = sym.n_value,
            });
            try object.symbol_mapping.putNoClobber(self.base.allocator, sym_id, local_sym_index);
            try object.reverse_symbol_mapping.putNoClobber(self.base.allocator, local_sym_index, sym_id);

            // If the symbol's scope is not local aka translation unit, then we need work out
            // if we should save the symbol as a global, or potentially flag the error.
            if (!symbolIsExt(sym)) continue;

            const local = self.locals.items[local_sym_index];
            const resolv = self.symbol_resolver.getPtr(n_strx) orelse {
                const global_sym_index = @intCast(u32, self.globals.items.len);
                try self.globals.append(self.base.allocator, .{
                    .n_strx = n_strx,
                    .n_type = sym.n_type,
                    .n_sect = 0,
                    .n_desc = sym.n_desc,
                    .n_value = sym.n_value,
                });
                try self.symbol_resolver.putNoClobber(self.base.allocator, n_strx, .{
                    .where = .global,
                    .where_index = global_sym_index,
                    .local_sym_index = local_sym_index,
                    .file = object_id,
                });
                continue;
            };

            switch (resolv.where) {
                .global => {
                    const global = &self.globals.items[resolv.where_index];

                    if (symbolIsTentative(global.*)) {
                        _ = tentatives.fetchSwapRemove(resolv.where_index);
                    } else if (!(symbolIsWeakDef(sym) or symbolIsPext(sym)) and
                        !(symbolIsWeakDef(global.*) or symbolIsPext(global.*)))
                    {
                        log.err("symbol '{s}' defined multiple times", .{sym_name});
                        log.err("  first definition in '{s}'", .{self.objects.items[resolv.file].name});
                        log.err("  next definition in '{s}'", .{object.name});
                        return error.MultipleSymbolDefinitions;
                    } else if (symbolIsWeakDef(sym) or symbolIsPext(sym)) continue; // Current symbol is weak, so skip it.

                    // Otherwise, update the resolver and the global symbol.
                    global.n_type = sym.n_type;
                    resolv.local_sym_index = local_sym_index;
                    resolv.file = object_id;

                    continue;
                },
                .undef => {
                    // const undef = &self.undefs.items[resolv.where_index];
                    // undef.* = .{
                    //     .n_strx = 0,
                    //     .n_type = macho.N_UNDF,
                    //     .n_sect = 0,
                    //     .n_desc = 0,
                    //     .n_value = 0,
                    // };
                    _ = self.unresolved.fetchSwapRemove(resolv.where_index);
                },
            }

            const global_sym_index = @intCast(u32, self.globals.items.len);
            try self.globals.append(self.base.allocator, .{
                .n_strx = local.n_strx,
                .n_type = sym.n_type,
                .n_sect = 0,
                .n_desc = sym.n_desc,
                .n_value = sym.n_value,
            });
            resolv.* = .{
                .where = .global,
                .where_index = global_sym_index,
                .local_sym_index = local_sym_index,
                .file = object_id,
            };
        } else if (symbolIsTentative(sym)) {
            // Symbol is a tentative definition.
            const resolv = self.symbol_resolver.getPtr(n_strx) orelse {
                const global_sym_index = @intCast(u32, self.globals.items.len);
                try self.globals.append(self.base.allocator, .{
                    .n_strx = try self.makeString(sym_name),
                    .n_type = sym.n_type,
                    .n_sect = 0,
                    .n_desc = sym.n_desc,
                    .n_value = sym.n_value,
                });
                try self.symbol_resolver.putNoClobber(self.base.allocator, n_strx, .{
                    .where = .global,
                    .where_index = global_sym_index,
                    .file = object_id,
                });
                _ = try tentatives.getOrPut(global_sym_index);
                continue;
            };

            switch (resolv.where) {
                .global => {
                    const global = &self.globals.items[resolv.where_index];
                    if (!symbolIsTentative(global.*)) continue;
                    if (global.n_value >= sym.n_value) continue;

                    global.n_desc = sym.n_desc;
                    global.n_value = sym.n_value;
                    resolv.file = object_id;
                },
                .undef => {
                    const undef = &self.undefs.items[resolv.where_index];
                    const global_sym_index = @intCast(u32, self.globals.items.len);
                    try self.globals.append(self.base.allocator, .{
                        .n_strx = undef.n_strx,
                        .n_type = sym.n_type,
                        .n_sect = 0,
                        .n_desc = sym.n_desc,
                        .n_value = sym.n_value,
                    });
                    _ = try tentatives.getOrPut(global_sym_index);
                    resolv.* = .{
                        .where = .global,
                        .where_index = global_sym_index,
                        .file = object_id,
                    };
                    undef.* = .{
                        .n_strx = 0,
                        .n_type = macho.N_UNDF,
                        .n_sect = 0,
                        .n_desc = 0,
                        .n_value = 0,
                    };
                    _ = self.unresolved.fetchSwapRemove(resolv.where_index);
                },
            }
        } else {
            // Symbol is undefined.
            if (self.symbol_resolver.contains(n_strx)) continue;

            const undef_sym_index = @intCast(u32, self.undefs.items.len);
            try self.undefs.append(self.base.allocator, .{
                .n_strx = try self.makeString(sym_name),
                .n_type = macho.N_UNDF,
                .n_sect = 0,
                .n_desc = 0,
                .n_value = 0,
            });
            try self.symbol_resolver.putNoClobber(self.base.allocator, n_strx, .{
                .where = .undef,
                .where_index = undef_sym_index,
                .file = object_id,
            });
            try self.unresolved.putNoClobber(self.base.allocator, undef_sym_index, .none);
        }
    }
}

fn resolveSymbols(self: *MachO) !void {
    var tentatives = std.AutoArrayHashMap(u32, void).init(self.base.allocator);
    defer tentatives.deinit();

    // First pass, resolve symbols in provided objects.
    for (self.objects.items) |_, object_id| {
        try self.resolveSymbolsInObject(@intCast(u16, object_id), &tentatives);
    }

    // Second pass, resolve symbols in static libraries.
    var next_sym: usize = 0;
    loop: while (next_sym < self.unresolved.count()) {
        const sym = self.undefs.items[self.unresolved.keys()[next_sym]];
        const sym_name = self.getString(sym.n_strx);

        for (self.archives.items) |archive| {
            // Check if the entry exists in a static archive.
            const offsets = archive.toc.get(sym_name) orelse {
                // No hit.
                continue;
            };
            assert(offsets.items.len > 0);

            const object_id = @intCast(u16, self.objects.items.len);
            const object = try self.objects.addOne(self.base.allocator);
            object.* = try archive.parseObject(self.base.allocator, self.base.options.target, offsets.items[0]);
            try self.resolveSymbolsInObject(object_id, &tentatives);

            continue :loop;
        }

        next_sym += 1;
    }

    // Convert any tentative definition into a regular symbol and allocate
    // text blocks for each tentative defintion.
    while (tentatives.popOrNull()) |entry| {
        const sym = &self.globals.items[entry.key];
        const match = MatchingSection{
            .seg = self.data_segment_cmd_index.?,
            .sect = self.bss_section_index.?,
        };
        _ = try self.section_ordinals.getOrPut(self.base.allocator, match);

        const size = sym.n_value;
        const alignment = (sym.n_desc >> 8) & 0x0f;

        sym.n_value = 0;
        sym.n_desc = 0;
        sym.n_sect = @intCast(u8, self.section_ordinals.getIndex(match).? + 1);
        var local_sym = sym.*;
        local_sym.n_type = macho.N_SECT;

        const local_sym_index = @intCast(u32, self.locals.items.len);
        try self.locals.append(self.base.allocator, local_sym);

        const resolv = self.symbol_resolver.getPtr(sym.n_strx) orelse unreachable;
        resolv.local_sym_index = local_sym_index;

        const atom = try self.createEmptyAtom(local_sym_index, size, alignment);
        _ = try self.allocateAtom(atom, match);
    }

    try self.resolveDyldStubBinder();
    {
        const atom = try self.createDyldPrivateAtom();
        _ = try self.allocateAtom(atom, .{
            .seg = self.data_segment_cmd_index.?,
            .sect = self.data_section_index.?,
        });
    }
    {
        const atom = try self.createStubHelperPreambleAtom();
        _ = try self.allocateAtom(atom, .{
            .seg = self.text_segment_cmd_index.?,
            .sect = self.stub_helper_section_index.?,
        });
    }

    // Third pass, resolve symbols in dynamic libraries.
    next_sym = 0;
    loop: while (next_sym < self.unresolved.count()) {
        const sym = self.undefs.items[self.unresolved.keys()[next_sym]];
        const sym_name = self.getString(sym.n_strx);

        for (self.dylibs.items) |dylib, id| {
            if (!dylib.symbols.contains(sym_name)) continue;

            const dylib_id = @intCast(u16, id);
            if (!self.referenced_dylibs.contains(dylib_id)) {
                try self.referenced_dylibs.putNoClobber(self.base.allocator, dylib_id, {});
            }

            const ordinal = self.referenced_dylibs.getIndex(dylib_id) orelse unreachable;
            const resolv = self.symbol_resolver.getPtr(sym.n_strx) orelse unreachable;
            const undef = &self.undefs.items[resolv.where_index];
            undef.n_type |= macho.N_EXT;
            undef.n_desc = @intCast(u16, ordinal + 1) * macho.N_SYMBOL_RESOLVER;

            if (self.unresolved.fetchSwapRemove(resolv.where_index)) |entry| outer_blk: {
                switch (entry.value) {
                    .none => {},
                    .got => return error.TODOGotHint,
                    .stub => {
                        if (self.stubs_map.contains(resolv.where_index)) break :outer_blk;
                        const stub_helper_atom = blk: {
                            const atom = try self.createStubHelperAtom();
                            _ = try self.allocateAtom(atom, .{
                                .seg = self.text_segment_cmd_index.?,
                                .sect = self.stub_helper_section_index.?,
                            });
                            break :blk atom;
                        };
                        const laptr_atom = blk: {
                            const atom = try self.createLazyPointerAtom(
                                stub_helper_atom.local_sym_index,
                                resolv.where_index,
                            );
                            _ = try self.allocateAtom(atom, .{
                                .seg = self.data_segment_cmd_index.?,
                                .sect = self.la_symbol_ptr_section_index.?,
                            });
                            break :blk atom;
                        };
                        const stub_atom = blk: {
                            const atom = try self.createStubAtom(laptr_atom.local_sym_index);
                            _ = try self.allocateAtom(atom, .{
                                .seg = self.text_segment_cmd_index.?,
                                .sect = self.stubs_section_index.?,
                            });
                            break :blk atom;
                        };
                        try self.stubs_map.putNoClobber(self.base.allocator, resolv.where_index, stub_atom);
                    },
                }
            }

            continue :loop;
        }

        next_sym += 1;
    }

    // Fourth pass, handle synthetic symbols and flag any undefined references.
    if (self.strtab_dir.getAdapted(@as([]const u8, "___dso_handle"), StringSliceAdapter{
        .strtab = &self.strtab,
    })) |n_strx| blk: {
        const resolv = self.symbol_resolver.getPtr(n_strx) orelse break :blk;
        if (resolv.where != .undef) break :blk;

        const undef = &self.undefs.items[resolv.where_index];
        const match: MatchingSection = .{
            .seg = self.text_segment_cmd_index.?,
            .sect = self.text_section_index.?,
        };
        const local_sym_index = @intCast(u32, self.locals.items.len);
        var nlist = macho.nlist_64{
            .n_strx = undef.n_strx,
            .n_type = macho.N_SECT,
            .n_sect = @intCast(u8, self.section_ordinals.getIndex(match).? + 1),
            .n_desc = 0,
            .n_value = 0,
        };
        try self.locals.append(self.base.allocator, nlist);
        const global_sym_index = @intCast(u32, self.globals.items.len);
        nlist.n_type |= macho.N_EXT;
        nlist.n_desc = macho.N_WEAK_DEF;
        try self.globals.append(self.base.allocator, nlist);

        _ = self.unresolved.fetchSwapRemove(resolv.where_index);

        undef.* = .{
            .n_strx = 0,
            .n_type = macho.N_UNDF,
            .n_sect = 0,
            .n_desc = 0,
            .n_value = 0,
        };
        resolv.* = .{
            .where = .global,
            .where_index = global_sym_index,
            .local_sym_index = local_sym_index,
        };

        // We create an empty atom for this symbol.
        // TODO perhaps we should special-case special symbols? Create a separate
        // linked list of atoms?
        const atom = try self.createEmptyAtom(local_sym_index, 0, 0);
        _ = try self.allocateAtom(atom, match);
    }

    for (self.unresolved.keys()) |index| {
        const sym = self.undefs.items[index];
        const sym_name = self.getString(sym.n_strx);
        const resolv = self.symbol_resolver.get(sym.n_strx) orelse unreachable;

        log.err("undefined reference to symbol '{s}'", .{sym_name});
        log.err("  first referenced in '{s}'", .{self.objects.items[resolv.file].name});
    }

    if (self.unresolved.count() > 0)
        return error.UndefinedSymbolReference;
}

fn resolveDyldStubBinder(self: *MachO) !void {
    if (self.dyld_stub_binder_index != null) return;

    const n_strx = try self.makeString("dyld_stub_binder");
    const sym_index = @intCast(u32, self.undefs.items.len);
    try self.undefs.append(self.base.allocator, .{
        .n_strx = n_strx,
        .n_type = macho.N_UNDF,
        .n_sect = 0,
        .n_desc = 0,
        .n_value = 0,
    });
    try self.symbol_resolver.putNoClobber(self.base.allocator, n_strx, .{
        .where = .undef,
        .where_index = sym_index,
    });
    const sym = &self.undefs.items[sym_index];
    const sym_name = self.getString(n_strx);

    for (self.dylibs.items) |dylib, id| {
        if (!dylib.symbols.contains(sym_name)) continue;

        const dylib_id = @intCast(u16, id);
        if (!self.referenced_dylibs.contains(dylib_id)) {
            try self.referenced_dylibs.putNoClobber(self.base.allocator, dylib_id, {});
        }

        const ordinal = self.referenced_dylibs.getIndex(dylib_id) orelse unreachable;
        sym.n_type |= macho.N_EXT;
        sym.n_desc = @intCast(u16, ordinal + 1) * macho.N_SYMBOL_RESOLVER;
        self.dyld_stub_binder_index = sym_index;

        break;
    }

    if (self.dyld_stub_binder_index == null) {
        log.err("undefined reference to symbol '{s}'", .{sym_name});
        return error.UndefinedSymbolReference;
    }

    // Add dyld_stub_binder as the final GOT entry.
    const got_entry = GotIndirectionKey{
        .where = .undef,
        .where_index = self.dyld_stub_binder_index.?,
    };
    const atom = try self.createGotAtom(got_entry);
    try self.got_entries_map.putNoClobber(self.base.allocator, got_entry, atom);
    const match = MatchingSection{
        .seg = self.data_const_segment_cmd_index.?,
        .sect = self.got_section_index.?,
    };
    _ = try self.allocateAtom(atom, match);
}

fn parseTextBlocks(self: *MachO) !void {
    for (self.objects.items) |*object, object_id| {
        try object.parseTextBlocks(self.base.allocator, @intCast(u16, object_id), self);
    }
}

fn addDataInCodeLC(self: *MachO) !void {
    if (self.data_in_code_cmd_index != null) return;
    self.data_in_code_cmd_index = @intCast(u16, self.load_commands.items.len);
    try self.load_commands.append(self.base.allocator, .{
        .LinkeditData = .{
            .cmd = macho.LC_DATA_IN_CODE,
            .cmdsize = @sizeOf(macho.linkedit_data_command),
            .dataoff = 0,
            .datasize = 0,
        },
    });
    self.load_commands_dirty = true;
}

fn addCodeSignatureLC(self: *MachO) !void {
    if (self.code_signature_cmd_index != null or !self.requires_adhoc_codesig) return;
    self.code_signature_cmd_index = @intCast(u16, self.load_commands.items.len);
    try self.load_commands.append(self.base.allocator, .{
        .LinkeditData = .{
            .cmd = macho.LC_CODE_SIGNATURE,
            .cmdsize = @sizeOf(macho.linkedit_data_command),
            .dataoff = 0,
            .datasize = 0,
        },
    });
    self.load_commands_dirty = true;
}

fn addRpathLCs(self: *MachO, rpaths: []const []const u8) !void {
    for (rpaths) |rpath| {
        const cmdsize = @intCast(u32, mem.alignForwardGeneric(
            u64,
            @sizeOf(macho.rpath_command) + rpath.len + 1,
            @sizeOf(u64),
        ));
        var rpath_cmd = commands.emptyGenericCommandWithData(macho.rpath_command{
            .cmd = macho.LC_RPATH,
            .cmdsize = cmdsize,
            .path = @sizeOf(macho.rpath_command),
        });
        rpath_cmd.data = try self.base.allocator.alloc(u8, cmdsize - rpath_cmd.inner.path);
        mem.set(u8, rpath_cmd.data, 0);
        mem.copy(u8, rpath_cmd.data, rpath);
        try self.load_commands.append(self.base.allocator, .{ .Rpath = rpath_cmd });
        self.load_commands_dirty = true;
    }
}

fn addLoadDylibLCs(self: *MachO) !void {
    for (self.referenced_dylibs.keys()) |id| {
        const dylib = self.dylibs.items[id];
        const dylib_id = dylib.id orelse unreachable;
        var dylib_cmd = try commands.createLoadDylibCommand(
            self.base.allocator,
            dylib_id.name,
            dylib_id.timestamp,
            dylib_id.current_version,
            dylib_id.compatibility_version,
        );
        errdefer dylib_cmd.deinit(self.base.allocator);
        try self.load_commands.append(self.base.allocator, .{ .Dylib = dylib_cmd });
        self.load_commands_dirty = true;
    }
}

fn setEntryPoint(self: *MachO) !void {
    if (self.base.options.output_mode != .Exe) return;

    // TODO we should respect the -entry flag passed in by the user to set a custom
    // entrypoint. For now, assume default of `_main`.
    const seg = self.load_commands.items[self.text_segment_cmd_index.?].Segment;
    const n_strx = self.strtab_dir.getAdapted(@as([]const u8, "_main"), StringSliceAdapter{
        .strtab = &self.strtab,
    }) orelse {
        log.err("'_main' export not found", .{});
        return error.MissingMainEntrypoint;
    };
    const resolv = self.symbol_resolver.get(n_strx) orelse unreachable;
    assert(resolv.where == .global);
    const sym = self.globals.items[resolv.where_index];
    const ec = &self.load_commands.items[self.main_cmd_index.?].Main;
    ec.entryoff = @intCast(u32, sym.n_value - seg.inner.vmaddr);
    ec.stacksize = self.base.options.stack_size_override orelse 0;
    self.entry_addr = sym.n_value;
    self.load_commands_dirty = true;
}

pub fn deinit(self: *MachO) void {
    if (build_options.have_llvm) {
        if (self.llvm_object) |llvm_object| llvm_object.destroy(self.base.allocator);
    }

    if (self.d_sym) |*ds| {
        ds.deinit(self.base.allocator);
    }

    self.section_ordinals.deinit(self.base.allocator);
    self.got_entries_map.deinit(self.base.allocator);
    self.stubs_map.deinit(self.base.allocator);
    self.strtab_dir.deinit(self.base.allocator);
    self.strtab.deinit(self.base.allocator);
    self.undefs.deinit(self.base.allocator);
    self.globals.deinit(self.base.allocator);
    self.globals_free_list.deinit(self.base.allocator);
    self.locals.deinit(self.base.allocator);
    self.locals_free_list.deinit(self.base.allocator);
    self.symbol_resolver.deinit(self.base.allocator);
    self.unresolved.deinit(self.base.allocator);

    for (self.objects.items) |*object| {
        object.deinit(self.base.allocator);
    }
    self.objects.deinit(self.base.allocator);

    for (self.archives.items) |*archive| {
        archive.deinit(self.base.allocator);
    }
    self.archives.deinit(self.base.allocator);

    for (self.dylibs.items) |*dylib| {
        dylib.deinit(self.base.allocator);
    }
    self.dylibs.deinit(self.base.allocator);
    self.dylibs_map.deinit(self.base.allocator);
    self.referenced_dylibs.deinit(self.base.allocator);

    for (self.load_commands.items) |*lc| {
        lc.deinit(self.base.allocator);
    }
    self.load_commands.deinit(self.base.allocator);

    for (self.managed_blocks.items) |block| {
        block.deinit(self.base.allocator);
        self.base.allocator.destroy(block);
    }
    self.managed_blocks.deinit(self.base.allocator);
    self.blocks.deinit(self.base.allocator);
    {
        var it = self.block_free_lists.valueIterator();
        while (it.next()) |free_list| {
            free_list.deinit(self.base.allocator);
        }
        self.block_free_lists.deinit(self.base.allocator);
    }
    for (self.decls.keys()) |decl| {
        decl.link.macho.deinit(self.base.allocator);
    }
    self.decls.deinit(self.base.allocator);
}

pub fn closeFiles(self: MachO) void {
    for (self.objects.items) |object| {
        object.file.close();
    }
    for (self.archives.items) |archive| {
        archive.file.close();
    }
    for (self.dylibs.items) |dylib| {
        dylib.file.close();
    }
}

fn freeTextBlock(self: *MachO, text_block: *TextBlock) void {
    log.debug("freeTextBlock {*}", .{text_block});
    text_block.deinit(self.base.allocator);

    const match = MatchingSection{
        .seg = self.text_segment_cmd_index.?,
        .sect = self.text_section_index.?,
    };
    const text_block_free_list = self.block_free_lists.getPtr(match).?;
    var already_have_free_list_node = false;
    {
        var i: usize = 0;
        // TODO turn text_block_free_list into a hash map
        while (i < text_block_free_list.items.len) {
            if (text_block_free_list.items[i] == text_block) {
                _ = text_block_free_list.swapRemove(i);
                continue;
            }
            if (text_block_free_list.items[i] == text_block.prev) {
                already_have_free_list_node = true;
            }
            i += 1;
        }
    }
    // TODO process free list for dbg info just like we do above for vaddrs

    if (self.blocks.getPtr(match)) |last_text_block| {
        if (last_text_block.* == text_block) {
            if (text_block.prev) |prev| {
                // TODO shrink the __text section size here
                last_text_block.* = prev;
            }
        }
    }

    if (self.d_sym) |*ds| {
        if (ds.dbg_info_decl_first == text_block) {
            ds.dbg_info_decl_first = text_block.dbg_info_next;
        }
        if (ds.dbg_info_decl_last == text_block) {
            // TODO shrink the .debug_info section size here
            ds.dbg_info_decl_last = text_block.dbg_info_prev;
        }
    }

    if (text_block.prev) |prev| {
        prev.next = text_block.next;

        if (!already_have_free_list_node and prev.freeListEligible(self.*)) {
            // The free list is heuristics, it doesn't have to be perfect, so we can ignore
            // the OOM here.
            text_block_free_list.append(self.base.allocator, prev) catch {};
        }
    } else {
        text_block.prev = null;
    }

    if (text_block.next) |next| {
        next.prev = text_block.prev;
    } else {
        text_block.next = null;
    }

    if (text_block.dbg_info_prev) |prev| {
        prev.dbg_info_next = text_block.dbg_info_next;

        // TODO the free list logic like we do for text blocks above
    } else {
        text_block.dbg_info_prev = null;
    }

    if (text_block.dbg_info_next) |next| {
        next.dbg_info_prev = text_block.dbg_info_prev;
    } else {
        text_block.dbg_info_next = null;
    }
}

fn shrinkTextBlock(self: *MachO, text_block: *TextBlock, new_block_size: u64) void {
    _ = self;
    _ = text_block;
    _ = new_block_size;
    // TODO check the new capacity, and if it crosses the size threshold into a big enough
    // capacity, insert a free list node for it.
}

fn growTextBlock(self: *MachO, text_block: *TextBlock, new_block_size: u64, alignment: u64) !u64 {
    const sym = self.locals.items[text_block.local_sym_index];
    const align_ok = mem.alignBackwardGeneric(u64, sym.n_value, alignment) == sym.n_value;
    const need_realloc = !align_ok or new_block_size > text_block.capacity(self.*);
    if (!need_realloc) return sym.n_value;
    return self.allocateTextBlock(text_block, new_block_size, alignment);
}

pub fn allocateDeclIndexes(self: *MachO, decl: *Module.Decl) !void {
    if (decl.link.macho.local_sym_index != 0) return;

    try self.locals.ensureUnusedCapacity(self.base.allocator, 1);
    try self.decls.putNoClobber(self.base.allocator, decl, {});

    if (self.locals_free_list.popOrNull()) |i| {
        log.debug("reusing symbol index {d} for {s}", .{ i, decl.name });
        decl.link.macho.local_sym_index = i;
    } else {
        log.debug("allocating symbol index {d} for {s}", .{ self.locals.items.len, decl.name });
        decl.link.macho.local_sym_index = @intCast(u32, self.locals.items.len);
        _ = self.locals.addOneAssumeCapacity();
    }

    self.locals.items[decl.link.macho.local_sym_index] = .{
        .n_strx = 0,
        .n_type = 0,
        .n_sect = 0,
        .n_desc = 0,
        .n_value = 0,
    };

    // TODO try popping from free list first before allocating a new GOT atom.
    const key = GotIndirectionKey{
        .where = .local,
        .where_index = decl.link.macho.local_sym_index,
    };
    const got_atom = try self.createGotAtom(key);
    try self.got_entries_map.put(self.base.allocator, key, got_atom);
}

pub fn updateFunc(self: *MachO, module: *Module, func: *Module.Fn, air: Air, liveness: Liveness) !void {
    if (build_options.skip_non_native and builtin.object_format != .macho) {
        @panic("Attempted to compile for object format that was disabled by build configuration");
    }
    if (build_options.have_llvm) {
        if (self.llvm_object) |llvm_object| return llvm_object.updateFunc(module, func, air, liveness);
    }
    const tracy = trace(@src());
    defer tracy.end();

    const decl = func.owner_decl;

    var code_buffer = std.ArrayList(u8).init(self.base.allocator);
    defer code_buffer.deinit();

    var debug_buffers_buf: DebugSymbols.DeclDebugBuffers = undefined;
    const debug_buffers = if (self.d_sym) |*ds| blk: {
        debug_buffers_buf = try ds.initDeclDebugBuffers(self.base.allocator, module, decl);
        break :blk &debug_buffers_buf;
    } else null;
    defer {
        if (debug_buffers) |dbg| {
            dbg.dbg_line_buffer.deinit();
            dbg.dbg_info_buffer.deinit();
            var it = dbg.dbg_info_type_relocs.valueIterator();
            while (it.next()) |value| {
                value.relocs.deinit(self.base.allocator);
            }
            dbg.dbg_info_type_relocs.deinit(self.base.allocator);
        }
    }

    self.active_decl = decl;

    const res = if (debug_buffers) |dbg|
        try codegen.generateFunction(&self.base, decl.srcLoc(), func, air, liveness, &code_buffer, .{
            .dwarf = .{
                .dbg_line = &dbg.dbg_line_buffer,
                .dbg_info = &dbg.dbg_info_buffer,
                .dbg_info_type_relocs = &dbg.dbg_info_type_relocs,
            },
        })
    else
        try codegen.generateFunction(&self.base, decl.srcLoc(), func, air, liveness, &code_buffer, .none);
    switch (res) {
        .appended => {
            // TODO clearing the code and relocs buffer should probably be orchestrated
            // in a different, smarter, more automatic way somewhere else, in a more centralised
            // way than this.
            // If we don't clear the buffers here, we are up for some nasty surprises when
            // this TextBlock is reused later on and was not freed by freeTextBlock().
            decl.link.macho.code.clearAndFree(self.base.allocator);
            try decl.link.macho.code.appendSlice(self.base.allocator, code_buffer.items);
        },
        .fail => |em| {
            decl.analysis = .codegen_failure;
            try module.failed_decls.put(module.gpa, decl, em);
            return;
        },
    }

    _ = try self.placeDecl(decl, decl.link.macho.code.items.len);

    if (debug_buffers) |db| {
        try self.d_sym.?.commitDeclDebugInfo(
            self.base.allocator,
            module,
            decl,
            db,
            self.base.options.target,
        );
    }

    // Since we updated the vaddr and the size, each corresponding export symbol also
    // needs to be updated.
    const decl_exports = module.decl_exports.get(decl) orelse &[0]*Module.Export{};
    try self.updateDeclExports(module, decl, decl_exports);
}

pub fn updateDecl(self: *MachO, module: *Module, decl: *Module.Decl) !void {
    if (build_options.skip_non_native and builtin.object_format != .macho) {
        @panic("Attempted to compile for object format that was disabled by build configuration");
    }
    if (build_options.have_llvm) {
        if (self.llvm_object) |llvm_object| return llvm_object.updateDecl(module, decl);
    }
    const tracy = trace(@src());
    defer tracy.end();

    if (decl.val.tag() == .extern_fn) {
        return; // TODO Should we do more when front-end analyzed extern decl?
    }

    var code_buffer = std.ArrayList(u8).init(self.base.allocator);
    defer code_buffer.deinit();

    var debug_buffers_buf: DebugSymbols.DeclDebugBuffers = undefined;
    const debug_buffers = if (self.d_sym) |*ds| blk: {
        debug_buffers_buf = try ds.initDeclDebugBuffers(self.base.allocator, module, decl);
        break :blk &debug_buffers_buf;
    } else null;
    defer {
        if (debug_buffers) |dbg| {
            dbg.dbg_line_buffer.deinit();
            dbg.dbg_info_buffer.deinit();
            var it = dbg.dbg_info_type_relocs.valueIterator();
            while (it.next()) |value| {
                value.relocs.deinit(self.base.allocator);
            }
            dbg.dbg_info_type_relocs.deinit(self.base.allocator);
        }
    }

    self.active_decl = decl;

    const res = if (debug_buffers) |dbg|
        try codegen.generateSymbol(&self.base, decl.srcLoc(), .{
            .ty = decl.ty,
            .val = decl.val,
        }, &code_buffer, .{
            .dwarf = .{
                .dbg_line = &dbg.dbg_line_buffer,
                .dbg_info = &dbg.dbg_info_buffer,
                .dbg_info_type_relocs = &dbg.dbg_info_type_relocs,
            },
        })
    else
        try codegen.generateSymbol(&self.base, decl.srcLoc(), .{
            .ty = decl.ty,
            .val = decl.val,
        }, &code_buffer, .none);

    const code = blk: {
        switch (res) {
            .externally_managed => |x| break :blk x,
            .appended => {
                // TODO clearing the code and relocs buffer should probably be orchestrated
                // in a different, smarter, more automatic way somewhere else, in a more centralised
                // way than this.
                // If we don't clear the buffers here, we are up for some nasty surprises when
                // this TextBlock is reused later on and was not freed by freeTextBlock().
                decl.link.macho.code.clearAndFree(self.base.allocator);
                try decl.link.macho.code.appendSlice(self.base.allocator, code_buffer.items);
                break :blk decl.link.macho.code.items;
            },
            .fail => |em| {
                decl.analysis = .codegen_failure;
                try module.failed_decls.put(module.gpa, decl, em);
                return;
            },
        }
    };
    _ = try self.placeDecl(decl, code.len);

    // Since we updated the vaddr and the size, each corresponding export symbol also
    // needs to be updated.
    const decl_exports = module.decl_exports.get(decl) orelse &[0]*Module.Export{};
    try self.updateDeclExports(module, decl, decl_exports);
}

fn placeDecl(self: *MachO, decl: *Module.Decl, code_len: usize) !*macho.nlist_64 {
    const required_alignment = decl.ty.abiAlignment(self.base.options.target);
    assert(decl.link.macho.local_sym_index != 0); // Caller forgot to call allocateDeclIndexes()
    const symbol = &self.locals.items[decl.link.macho.local_sym_index];

    if (decl.link.macho.size != 0) {
        const capacity = decl.link.macho.capacity(self.*);
        const need_realloc = code_len > capacity or !mem.isAlignedGeneric(u64, symbol.n_value, required_alignment);
        if (need_realloc) {
            const vaddr = try self.growTextBlock(&decl.link.macho, code_len, required_alignment);

            log.debug("growing {s} and moving from 0x{x} to 0x{x}", .{ decl.name, symbol.n_value, vaddr });

            if (vaddr != symbol.n_value) {
                log.debug(" (writing new GOT entry)", .{});
                const got_atom = self.got_entries_map.get(.{
                    .where = .local,
                    .where_index = decl.link.macho.local_sym_index,
                }) orelse unreachable;
                _ = try self.allocateAtom(got_atom, .{
                    .seg = self.data_const_segment_cmd_index.?,
                    .sect = self.got_section_index.?,
                });
            }

            symbol.n_value = vaddr;
        } else if (code_len < decl.link.macho.size) {
            self.shrinkTextBlock(&decl.link.macho, code_len);
        }
        decl.link.macho.size = code_len;

        const new_name = try std.fmt.allocPrint(self.base.allocator, "_{s}", .{mem.spanZ(decl.name)});
        defer self.base.allocator.free(new_name);

        symbol.n_strx = try self.makeString(new_name);
        symbol.n_type = macho.N_SECT;
        symbol.n_sect = @intCast(u8, self.text_section_index.?) + 1;
        symbol.n_desc = 0;
    } else {
        const decl_name = try std.fmt.allocPrint(self.base.allocator, "_{s}", .{mem.spanZ(decl.name)});
        defer self.base.allocator.free(decl_name);

        const name_str_index = try self.makeString(decl_name);
        const addr = try self.allocateTextBlock(&decl.link.macho, code_len, required_alignment);

        log.debug("allocated text block for {s} at 0x{x}", .{ decl_name, addr });

        errdefer self.freeTextBlock(&decl.link.macho);

        symbol.* = .{
            .n_strx = name_str_index,
            .n_type = macho.N_SECT,
            .n_sect = @intCast(u8, self.text_section_index.?) + 1,
            .n_desc = 0,
            .n_value = addr,
        };
        const got_atom = self.got_entries_map.get(.{
            .where = .local,
            .where_index = decl.link.macho.local_sym_index,
        }) orelse unreachable;
        _ = try self.allocateAtom(got_atom, .{
            .seg = self.data_const_segment_cmd_index.?,
            .sect = self.got_section_index.?,
        });
    }

    return symbol;
}

pub fn updateDeclLineNumber(self: *MachO, module: *Module, decl: *const Module.Decl) !void {
    if (self.d_sym) |*ds| {
        try ds.updateDeclLineNumber(module, decl);
    }
}

pub fn updateDeclExports(
    self: *MachO,
    module: *Module,
    decl: *Module.Decl,
    exports: []const *Module.Export,
) !void {
    if (build_options.skip_non_native and builtin.object_format != .macho) {
        @panic("Attempted to compile for object format that was disabled by build configuration");
    }
    if (build_options.have_llvm) {
        if (self.llvm_object) |llvm_object| return llvm_object.updateDeclExports(module, decl, exports);
    }
    const tracy = trace(@src());
    defer tracy.end();

    try self.globals.ensureCapacity(self.base.allocator, self.globals.items.len + exports.len);
    if (decl.link.macho.local_sym_index == 0) return;
    const decl_sym = &self.locals.items[decl.link.macho.local_sym_index];

    for (exports) |exp| {
        const exp_name = try std.fmt.allocPrint(self.base.allocator, "_{s}", .{exp.options.name});
        defer self.base.allocator.free(exp_name);

        if (exp.options.section) |section_name| {
            if (!mem.eql(u8, section_name, "__text")) {
                try module.failed_exports.ensureCapacity(module.gpa, module.failed_exports.count() + 1);
                module.failed_exports.putAssumeCapacityNoClobber(
                    exp,
                    try Module.ErrorMsg.create(self.base.allocator, decl.srcLoc(), "Unimplemented: ExportOptions.section", .{}),
                );
                continue;
            }
        }

        var n_type: u8 = macho.N_SECT | macho.N_EXT;
        var n_desc: u16 = 0;

        switch (exp.options.linkage) {
            .Internal => {
                // Symbol should be hidden, or in MachO lingo, private extern.
                // We should also mark the symbol as Weak: n_desc == N_WEAK_DEF.
                // TODO work out when to add N_WEAK_REF.
                n_type |= macho.N_PEXT;
                n_desc |= macho.N_WEAK_DEF;
            },
            .Strong => {},
            .Weak => {
                // Weak linkage is specified as part of n_desc field.
                // Symbol's n_type is like for a symbol with strong linkage.
                n_desc |= macho.N_WEAK_DEF;
            },
            .LinkOnce => {
                try module.failed_exports.ensureCapacity(module.gpa, module.failed_exports.count() + 1);
                module.failed_exports.putAssumeCapacityNoClobber(
                    exp,
                    try Module.ErrorMsg.create(self.base.allocator, decl.srcLoc(), "Unimplemented: GlobalLinkage.LinkOnce", .{}),
                );
                continue;
            },
        }

        if (exp.link.macho.sym_index) |i| {
            const sym = &self.globals.items[i];
            sym.* = .{
                .n_strx = sym.n_strx,
                .n_type = n_type,
                .n_sect = @intCast(u8, self.text_section_index.?) + 1,
                .n_desc = n_desc,
                .n_value = decl_sym.n_value,
            };
        } else {
            const name_str_index = try self.makeString(exp_name);
            const i = if (self.globals_free_list.popOrNull()) |i| i else blk: {
                _ = self.globals.addOneAssumeCapacity();
                break :blk @intCast(u32, self.globals.items.len - 1);
            };
            self.globals.items[i] = .{
                .n_strx = name_str_index,
                .n_type = n_type,
                .n_sect = @intCast(u8, self.text_section_index.?) + 1,
                .n_desc = n_desc,
                .n_value = decl_sym.n_value,
            };
            const resolv = try self.symbol_resolver.getOrPut(self.base.allocator, name_str_index);
            resolv.value_ptr.* = .{
                .where = .global,
                .where_index = i,
                .local_sym_index = decl.link.macho.local_sym_index,
            };

            exp.link.macho.sym_index = @intCast(u32, i);
        }
    }
}

pub fn deleteExport(self: *MachO, exp: Export) void {
    const sym_index = exp.sym_index orelse return;
    self.globals_free_list.append(self.base.allocator, sym_index) catch {};
    self.globals.items[sym_index].n_type = 0;
}

pub fn freeDecl(self: *MachO, decl: *Module.Decl) void {
    log.debug("freeDecl {*}", .{decl});
    _ = self.decls.swapRemove(decl);
    // Appending to free lists is allowed to fail because the free lists are heuristics based anyway.
    self.freeTextBlock(&decl.link.macho);
    if (decl.link.macho.local_sym_index != 0) {
        self.locals_free_list.append(self.base.allocator, decl.link.macho.local_sym_index) catch {};

        // TODO free GOT atom here.

        self.locals.items[decl.link.macho.local_sym_index].n_type = 0;
        decl.link.macho.local_sym_index = 0;
    }
    if (self.d_sym) |*ds| {
        // TODO make this logic match freeTextBlock. Maybe abstract the logic
        // out since the same thing is desired for both.
        _ = ds.dbg_line_fn_free_list.remove(&decl.fn_link.macho);
        if (decl.fn_link.macho.prev) |prev| {
            ds.dbg_line_fn_free_list.put(self.base.allocator, prev, {}) catch {};
            prev.next = decl.fn_link.macho.next;
            if (decl.fn_link.macho.next) |next| {
                next.prev = prev;
            } else {
                ds.dbg_line_fn_last = prev;
            }
        } else if (decl.fn_link.macho.next) |next| {
            ds.dbg_line_fn_first = next;
            next.prev = null;
        }
        if (ds.dbg_line_fn_first == &decl.fn_link.macho) {
            ds.dbg_line_fn_first = decl.fn_link.macho.next;
        }
        if (ds.dbg_line_fn_last == &decl.fn_link.macho) {
            ds.dbg_line_fn_last = decl.fn_link.macho.prev;
        }
    }
}

pub fn getDeclVAddr(self: *MachO, decl: *const Module.Decl) u64 {
    assert(decl.link.macho.local_sym_index != 0);
    return self.locals.items[decl.link.macho.local_sym_index].n_value;
}

pub fn populateMissingMetadata(self: *MachO) !void {
    if (self.pagezero_segment_cmd_index == null) {
        self.pagezero_segment_cmd_index = @intCast(u16, self.load_commands.items.len);
        try self.load_commands.append(self.base.allocator, .{
            .Segment = .{
                .inner = .{
                    .segname = makeStaticString("__PAGEZERO"),
                    .vmsize = pagezero_vmsize,
                },
            },
        });
        self.load_commands_dirty = true;
    }

    if (self.text_segment_cmd_index == null) {
        self.text_segment_cmd_index = @intCast(u16, self.load_commands.items.len);
        const program_code_size_hint = self.base.options.program_code_size_hint;
        const got_size_hint = @sizeOf(u64) * self.base.options.symbol_count_hint;
        const ideal_size = self.header_pad + program_code_size_hint + got_size_hint;
        const needed_size = mem.alignForwardGeneric(u64, padToIdeal(ideal_size), self.page_size);

        log.debug("found __TEXT segment free space 0x{x} to 0x{x}", .{ 0, needed_size });

        try self.load_commands.append(self.base.allocator, .{
            .Segment = .{
                .inner = .{
                    .segname = makeStaticString("__TEXT"),
                    .vmaddr = pagezero_vmsize,
                    .vmsize = needed_size,
                    .filesize = needed_size,
                    .maxprot = macho.VM_PROT_READ | macho.VM_PROT_EXECUTE,
                    .initprot = macho.VM_PROT_READ | macho.VM_PROT_EXECUTE,
                },
            },
        });
        self.load_commands_dirty = true;
    }

    if (self.text_section_index == null) {
        const alignment: u2 = switch (self.base.options.target.cpu.arch) {
            .x86_64 => 0,
            .aarch64 => 2,
            else => unreachable, // unhandled architecture type
        };
        const needed_size = self.base.options.program_code_size_hint;
        // const needed_size = 10;
        self.text_section_index = try self.allocateSection(
            self.text_segment_cmd_index.?,
            "__text",
            needed_size,
            alignment,
            .{
                .flags = macho.S_REGULAR | macho.S_ATTR_PURE_INSTRUCTIONS | macho.S_ATTR_SOME_INSTRUCTIONS,
            },
        );
    }

    if (self.stubs_section_index == null) {
        const alignment: u2 = switch (self.base.options.target.cpu.arch) {
            .x86_64 => 0,
            .aarch64 => 2,
            else => unreachable, // unhandled architecture type
        };
        const stub_size: u4 = switch (self.base.options.target.cpu.arch) {
            .x86_64 => 6,
            .aarch64 => 3 * @sizeOf(u32),
            else => unreachable, // unhandled architecture type
        };
        const needed_size = stub_size * self.base.options.symbol_count_hint;
        self.stubs_section_index = try self.allocateSection(
            self.text_segment_cmd_index.?,
            "__stubs",
            needed_size,
            alignment,
            .{
                .flags = macho.S_SYMBOL_STUBS | macho.S_ATTR_PURE_INSTRUCTIONS | macho.S_ATTR_SOME_INSTRUCTIONS,
                .reserved2 = stub_size,
            },
        );
    }

    if (self.stub_helper_section_index == null) {
        const alignment: u2 = switch (self.base.options.target.cpu.arch) {
            .x86_64 => 0,
            .aarch64 => 2,
            else => unreachable, // unhandled architecture type
        };
        const preamble_size: u6 = switch (self.base.options.target.cpu.arch) {
            .x86_64 => 15,
            .aarch64 => 6 * @sizeOf(u32),
            else => unreachable,
        };
        const stub_size: u4 = switch (self.base.options.target.cpu.arch) {
            .x86_64 => 10,
            .aarch64 => 3 * @sizeOf(u32),
            else => unreachable,
        };
        const needed_size = stub_size * self.base.options.symbol_count_hint + preamble_size;
        self.stub_helper_section_index = try self.allocateSection(
            self.text_segment_cmd_index.?,
            "__stub_helper",
            needed_size,
            alignment,
            .{
                .flags = macho.S_REGULAR | macho.S_ATTR_PURE_INSTRUCTIONS | macho.S_ATTR_SOME_INSTRUCTIONS,
            },
        );
    }

    if (self.data_const_segment_cmd_index == null) {
        self.data_const_segment_cmd_index = @intCast(u16, self.load_commands.items.len);
        const address_and_offset = self.nextSegmentAddressAndOffset();
        const ideal_size = @sizeOf(u64) * self.base.options.symbol_count_hint;
        const needed_size = mem.alignForwardGeneric(u64, padToIdeal(ideal_size), self.page_size);

        log.debug("found __DATA_CONST segment free space 0x{x} to 0x{x}", .{
            address_and_offset.offset,
            address_and_offset.offset + needed_size,
        });

        try self.load_commands.append(self.base.allocator, .{
            .Segment = .{
                .inner = .{
                    .segname = makeStaticString("__DATA_CONST"),
                    .vmaddr = address_and_offset.address,
                    .vmsize = needed_size,
                    .fileoff = address_and_offset.offset,
                    .filesize = needed_size,
                    .maxprot = macho.VM_PROT_READ | macho.VM_PROT_WRITE,
                    .initprot = macho.VM_PROT_READ | macho.VM_PROT_WRITE,
                },
            },
        });
        self.load_commands_dirty = true;
    }

    if (self.got_section_index == null) {
        const needed_size = @sizeOf(u64) * self.base.options.symbol_count_hint;
        const alignment: u16 = 3; // 2^3 = @sizeOf(u64)
        self.got_section_index = try self.allocateSection(
            self.data_const_segment_cmd_index.?,
            "__got",
            needed_size,
            alignment,
            .{
                .flags = macho.S_NON_LAZY_SYMBOL_POINTERS,
            },
        );
    }

    if (self.data_segment_cmd_index == null) {
        self.data_segment_cmd_index = @intCast(u16, self.load_commands.items.len);
        const address_and_offset = self.nextSegmentAddressAndOffset();
        const ideal_size = 2 * @sizeOf(u64) * self.base.options.symbol_count_hint;
        const needed_size = mem.alignForwardGeneric(u64, padToIdeal(ideal_size), self.page_size);

        log.debug("found __DATA segment free space 0x{x} to 0x{x}", .{ address_and_offset.offset, address_and_offset.offset + needed_size });

        try self.load_commands.append(self.base.allocator, .{
            .Segment = .{
                .inner = .{
                    .segname = makeStaticString("__DATA"),
                    .vmaddr = address_and_offset.address,
                    .vmsize = needed_size,
                    .fileoff = address_and_offset.offset,
                    .filesize = needed_size,
                    .maxprot = macho.VM_PROT_READ | macho.VM_PROT_WRITE,
                    .initprot = macho.VM_PROT_READ | macho.VM_PROT_WRITE,
                },
            },
        });
        self.load_commands_dirty = true;
    }

    if (self.la_symbol_ptr_section_index == null) {
        const needed_size = @sizeOf(u64) * self.base.options.symbol_count_hint;
        const alignment: u16 = 3; // 2^3 = @sizeOf(u64)
        self.la_symbol_ptr_section_index = try self.allocateSection(
            self.data_segment_cmd_index.?,
            "__la_symbol_ptr",
            needed_size,
            alignment,
            .{
                .flags = macho.S_LAZY_SYMBOL_POINTERS,
            },
        );
    }

    if (self.data_section_index == null) {
        const needed_size = @sizeOf(u64) * self.base.options.symbol_count_hint;
        const alignment: u16 = 3; // 2^3 = @sizeOf(u64)
        self.data_section_index = try self.allocateSection(
            self.data_segment_cmd_index.?,
            "__data",
            needed_size,
            alignment,
            .{},
        );
    }

    if (self.tlv_section_index == null) {
        const needed_size = @sizeOf(u64) * self.base.options.symbol_count_hint;
        const alignment: u16 = 3; // 2^3 = @sizeOf(u64)
        self.tlv_section_index = try self.allocateSection(
            self.data_segment_cmd_index.?,
            "__thread_vars",
            needed_size,
            alignment,
            .{
                .flags = macho.S_THREAD_LOCAL_VARIABLES,
            },
        );
    }

    if (self.tlv_data_section_index == null) {
        const needed_size = @sizeOf(u64) * self.base.options.symbol_count_hint;
        const alignment: u16 = 3; // 2^3 = @sizeOf(u64)
        self.tlv_data_section_index = try self.allocateSection(
            self.data_segment_cmd_index.?,
            "__thread_data",
            needed_size,
            alignment,
            .{
                .flags = macho.S_THREAD_LOCAL_REGULAR,
            },
        );
    }

    if (self.tlv_bss_section_index == null) {
        const needed_size = @sizeOf(u64) * self.base.options.symbol_count_hint;
        const alignment: u16 = 3; // 2^3 = @sizeOf(u64)
        self.tlv_bss_section_index = try self.allocateSection(
            self.data_segment_cmd_index.?,
            "__thread_bss",
            needed_size,
            alignment,
            .{
                .flags = macho.S_THREAD_LOCAL_ZEROFILL,
            },
        );

        // We keep offset to the section in a separate variable as the actual section is usually pointing at the
        // beginning of the file.
        const seg = &self.load_commands.items[self.data_segment_cmd_index.?].Segment;
        const out_sect = &seg.sections.items[self.tlv_bss_section_index.?];
        self.tlv_bss_file_offset = out_sect.offset;
        out_sect.offset = 0;
    }

    if (self.bss_section_index == null) {
        const needed_size = @sizeOf(u64) * self.base.options.symbol_count_hint;
        const alignment: u16 = 3; // 2^3 = @sizeOf(u64)
        self.bss_section_index = try self.allocateSection(
            self.data_segment_cmd_index.?,
            "__bss",
            needed_size,
            alignment,
            .{
                .flags = macho.S_ZEROFILL,
            },
        );

        // We keep offset to the section in a separate variable as the actual section is usually pointing at the
        // beginning of the file.
        const seg = &self.load_commands.items[self.data_segment_cmd_index.?].Segment;
        const out_sect = &seg.sections.items[self.bss_section_index.?];
        self.bss_file_offset = out_sect.offset;
        out_sect.offset = 0;
    }

    if (self.linkedit_segment_cmd_index == null) {
        self.linkedit_segment_cmd_index = @intCast(u16, self.load_commands.items.len);
        const address_and_offset = self.nextSegmentAddressAndOffset();

        log.debug("found __LINKEDIT segment free space at 0x{x}", .{address_and_offset.offset});

        try self.load_commands.append(self.base.allocator, .{
            .Segment = .{
                .inner = .{
                    .segname = makeStaticString("__LINKEDIT"),
                    .vmaddr = address_and_offset.address,
                    .fileoff = address_and_offset.offset,
                    .maxprot = macho.VM_PROT_READ,
                    .initprot = macho.VM_PROT_READ,
                },
            },
        });
        self.load_commands_dirty = true;
    }

    if (self.dyld_info_cmd_index == null) {
        self.dyld_info_cmd_index = @intCast(u16, self.load_commands.items.len);
        try self.load_commands.append(self.base.allocator, .{
            .DyldInfoOnly = .{
                .cmd = macho.LC_DYLD_INFO_ONLY,
                .cmdsize = @sizeOf(macho.dyld_info_command),
                .rebase_off = 0,
                .rebase_size = 0,
                .bind_off = 0,
                .bind_size = 0,
                .weak_bind_off = 0,
                .weak_bind_size = 0,
                .lazy_bind_off = 0,
                .lazy_bind_size = 0,
                .export_off = 0,
                .export_size = 0,
            },
        });
        self.load_commands_dirty = true;
    }

    if (self.symtab_cmd_index == null) {
        self.symtab_cmd_index = @intCast(u16, self.load_commands.items.len);
        try self.load_commands.append(self.base.allocator, .{
            .Symtab = .{
                .cmd = macho.LC_SYMTAB,
                .cmdsize = @sizeOf(macho.symtab_command),
                .symoff = 0,
                .nsyms = 0,
                .stroff = 0,
                .strsize = 0,
            },
        });
        self.load_commands_dirty = true;
    }

    if (self.dysymtab_cmd_index == null) {
        self.dysymtab_cmd_index = @intCast(u16, self.load_commands.items.len);
        try self.load_commands.append(self.base.allocator, .{
            .Dysymtab = .{
                .cmd = macho.LC_DYSYMTAB,
                .cmdsize = @sizeOf(macho.dysymtab_command),
                .ilocalsym = 0,
                .nlocalsym = 0,
                .iextdefsym = 0,
                .nextdefsym = 0,
                .iundefsym = 0,
                .nundefsym = 0,
                .tocoff = 0,
                .ntoc = 0,
                .modtaboff = 0,
                .nmodtab = 0,
                .extrefsymoff = 0,
                .nextrefsyms = 0,
                .indirectsymoff = 0,
                .nindirectsyms = 0,
                .extreloff = 0,
                .nextrel = 0,
                .locreloff = 0,
                .nlocrel = 0,
            },
        });
        self.load_commands_dirty = true;
    }

    if (self.dylinker_cmd_index == null) {
        self.dylinker_cmd_index = @intCast(u16, self.load_commands.items.len);
        const cmdsize = @intCast(u32, mem.alignForwardGeneric(
            u64,
            @sizeOf(macho.dylinker_command) + mem.lenZ(default_dyld_path),
            @sizeOf(u64),
        ));
        var dylinker_cmd = commands.emptyGenericCommandWithData(macho.dylinker_command{
            .cmd = macho.LC_LOAD_DYLINKER,
            .cmdsize = cmdsize,
            .name = @sizeOf(macho.dylinker_command),
        });
        dylinker_cmd.data = try self.base.allocator.alloc(u8, cmdsize - dylinker_cmd.inner.name);
        mem.set(u8, dylinker_cmd.data, 0);
        mem.copy(u8, dylinker_cmd.data, mem.spanZ(default_dyld_path));
        try self.load_commands.append(self.base.allocator, .{ .Dylinker = dylinker_cmd });
        self.load_commands_dirty = true;
    }

    if (self.main_cmd_index == null and self.base.options.output_mode == .Exe) {
        self.main_cmd_index = @intCast(u16, self.load_commands.items.len);
        try self.load_commands.append(self.base.allocator, .{
            .Main = .{
                .cmd = macho.LC_MAIN,
                .cmdsize = @sizeOf(macho.entry_point_command),
                .entryoff = 0x0,
                .stacksize = 0,
            },
        });
        self.load_commands_dirty = true;
    }

    if (self.dylib_id_cmd_index == null and self.base.options.output_mode == .Lib) {
        self.dylib_id_cmd_index = @intCast(u16, self.load_commands.items.len);
        const install_name = try std.fmt.allocPrint(self.base.allocator, "@rpath/{s}", .{
            self.base.options.emit.?.sub_path,
        });
        defer self.base.allocator.free(install_name);
        var dylib_cmd = try commands.createLoadDylibCommand(
            self.base.allocator,
            install_name,
            2,
            0x10000, // TODO forward user-provided versions
            0x10000,
        );
        errdefer dylib_cmd.deinit(self.base.allocator);
        dylib_cmd.inner.cmd = macho.LC_ID_DYLIB;
        try self.load_commands.append(self.base.allocator, .{ .Dylib = dylib_cmd });
        self.load_commands_dirty = true;
    }

    if (self.source_version_cmd_index == null) {
        self.source_version_cmd_index = @intCast(u16, self.load_commands.items.len);
        try self.load_commands.append(self.base.allocator, .{
            .SourceVersion = .{
                .cmd = macho.LC_SOURCE_VERSION,
                .cmdsize = @sizeOf(macho.source_version_command),
                .version = 0x0,
            },
        });
        self.load_commands_dirty = true;
    }

    if (self.build_version_cmd_index == null) {
        self.build_version_cmd_index = @intCast(u16, self.load_commands.items.len);
        const cmdsize = @intCast(u32, mem.alignForwardGeneric(
            u64,
            @sizeOf(macho.build_version_command) + @sizeOf(macho.build_tool_version),
            @sizeOf(u64),
        ));
        const ver = self.base.options.target.os.version_range.semver.min;
        const version = ver.major << 16 | ver.minor << 8 | ver.patch;
        const is_simulator_abi = self.base.options.target.abi == .simulator;
        var cmd = commands.emptyGenericCommandWithData(macho.build_version_command{
            .cmd = macho.LC_BUILD_VERSION,
            .cmdsize = cmdsize,
            .platform = switch (self.base.options.target.os.tag) {
                .macos => macho.PLATFORM_MACOS,
                .ios => if (is_simulator_abi) macho.PLATFORM_IOSSIMULATOR else macho.PLATFORM_IOS,
                .watchos => if (is_simulator_abi) macho.PLATFORM_WATCHOSSIMULATOR else macho.PLATFORM_WATCHOS,
                .tvos => if (is_simulator_abi) macho.PLATFORM_TVOSSIMULATOR else macho.PLATFORM_TVOS,
                else => unreachable,
            },
            .minos = version,
            .sdk = version,
            .ntools = 1,
        });
        const ld_ver = macho.build_tool_version{
            .tool = macho.TOOL_LD,
            .version = 0x0,
        };
        cmd.data = try self.base.allocator.alloc(u8, cmdsize - @sizeOf(macho.build_version_command));
        mem.set(u8, cmd.data, 0);
        mem.copy(u8, cmd.data, mem.asBytes(&ld_ver));
        try self.load_commands.append(self.base.allocator, .{ .BuildVersion = cmd });
        self.load_commands_dirty = true;
    }

    if (self.uuid_cmd_index == null) {
        self.uuid_cmd_index = @intCast(u16, self.load_commands.items.len);
        var uuid_cmd: macho.uuid_command = .{
            .cmd = macho.LC_UUID,
            .cmdsize = @sizeOf(macho.uuid_command),
            .uuid = undefined,
        };
        std.crypto.random.bytes(&uuid_cmd.uuid);
        try self.load_commands.append(self.base.allocator, .{ .Uuid = uuid_cmd });
        self.load_commands_dirty = true;
    }
}

const AllocateSectionOpts = struct {
    flags: u32 = macho.S_REGULAR,
    reserved1: u32 = 0,
    reserved2: u32 = 0,
};

fn allocateSection(
    self: *MachO,
    segment_id: u16,
    sectname: []const u8,
    size: u64,
    alignment: u32,
    opts: AllocateSectionOpts,
) !u16 {
    const seg = &self.load_commands.items[segment_id].Segment;
    var sect = macho.section_64{
        .sectname = makeStaticString(sectname),
        .segname = seg.inner.segname,
        .size = @intCast(u32, size),
        .@"align" = alignment,
        .flags = opts.flags,
        .reserved1 = opts.reserved1,
        .reserved2 = opts.reserved2,
    };

    const alignment_pow_2 = try math.powi(u32, 2, alignment);
    const padding: ?u64 = if (segment_id == self.text_segment_cmd_index.?) self.header_pad else null;
    const off = seg.findFreeSpace(size, alignment_pow_2, padding);

    log.debug("found {s},{s} section free space 0x{x} to 0x{x}", .{
        commands.segmentName(sect),
        commands.sectionName(sect),
        off,
        off + size,
    });

    sect.addr = seg.inner.vmaddr + off - seg.inner.fileoff;
    sect.offset = @intCast(u32, off);

    const index = @intCast(u16, seg.sections.items.len);
    try seg.sections.append(self.base.allocator, sect);
    seg.inner.cmdsize += @sizeOf(macho.section_64);
    seg.inner.nsects += 1;

    const match = MatchingSection{
        .seg = segment_id,
        .sect = index,
    };
    _ = try self.section_ordinals.getOrPut(self.base.allocator, match);
    try self.block_free_lists.putNoClobber(self.base.allocator, match, .{});

    self.load_commands_dirty = true;
    self.sections_order_dirty = true;

    return index;
}

fn getPtrToSectionOffset(self: *MachO, match: MatchingSection) *u32 {
    if (self.data_segment_cmd_index.? == match.seg) {
        if (self.bss_section_index) |idx| {
            if (idx == match.sect) {
                return &self.bss_file_offset.?;
            }
        }
        if (self.tlv_bss_section_index) |idx| {
            if (idx == match.sect) {
                return &self.tlv_bss_file_offset.?;
            }
        }
    }

    const seg = &self.load_commands.items[match.seg].Segment;
    const sect = &seg.sections.items[match.sect];
    return &sect.offset;
}

fn allocateTextBlock(self: *MachO, text_block: *TextBlock, new_block_size: u64, alignment: u64) !u64 {
    const text_segment = &self.load_commands.items[self.text_segment_cmd_index.?].Segment;
    const text_section = &text_segment.sections.items[self.text_section_index.?];
    const match = MatchingSection{
        .seg = self.text_segment_cmd_index.?,
        .sect = self.text_section_index.?,
    };
    var text_block_free_list = self.block_free_lists.get(match).?;
    const new_block_ideal_capacity = padToIdeal(new_block_size);

    // We use these to indicate our intention to update metadata, placing the new block,
    // and possibly removing a free list node.
    // It would be simpler to do it inside the for loop below, but that would cause a
    // problem if an error was returned later in the function. So this action
    // is actually carried out at the end of the function, when errors are no longer possible.
    var block_placement: ?*TextBlock = null;
    var free_list_removal: ?usize = null;

    // First we look for an appropriately sized free list node.
    // The list is unordered. We'll just take the first thing that works.
    var vaddr = blk: {
        var i: usize = 0;
        while (i < text_block_free_list.items.len) {
            const big_block = text_block_free_list.items[i];
            // We now have a pointer to a live text block that has too much capacity.
            // Is it enough that we could fit this new text block?
            const sym = self.locals.items[big_block.local_sym_index];
            const capacity = big_block.capacity(self.*);
            const ideal_capacity = padToIdeal(capacity);
            const ideal_capacity_end_vaddr = sym.n_value + ideal_capacity;
            const capacity_end_vaddr = sym.n_value + capacity;
            const new_start_vaddr_unaligned = capacity_end_vaddr - new_block_ideal_capacity;
            const new_start_vaddr = mem.alignBackwardGeneric(u64, new_start_vaddr_unaligned, alignment);
            if (new_start_vaddr < ideal_capacity_end_vaddr) {
                // Additional bookkeeping here to notice if this free list node
                // should be deleted because the block that it points to has grown to take up
                // more of the extra capacity.
                if (!big_block.freeListEligible(self.*)) {
                    const bl = text_block_free_list.swapRemove(i);
                    bl.deinit(self.base.allocator);
                } else {
                    i += 1;
                }
                continue;
            }
            // At this point we know that we will place the new block here. But the
            // remaining question is whether there is still yet enough capacity left
            // over for there to still be a free list node.
            const remaining_capacity = new_start_vaddr - ideal_capacity_end_vaddr;
            const keep_free_list_node = remaining_capacity >= min_text_capacity;

            // Set up the metadata to be updated, after errors are no longer possible.
            block_placement = big_block;
            if (!keep_free_list_node) {
                free_list_removal = i;
            }
            break :blk new_start_vaddr;
        } else if (self.blocks.get(match)) |last| {
            const last_symbol = self.locals.items[last.local_sym_index];
            // TODO We should pad out the excess capacity with NOPs. For executables,
            // no padding seems to be OK, but it will probably not be for objects.
            const ideal_capacity = padToIdeal(last.size);
            const ideal_capacity_end_vaddr = last_symbol.n_value + ideal_capacity;
            const new_start_vaddr = mem.alignForwardGeneric(u64, ideal_capacity_end_vaddr, alignment);
            block_placement = last;
            break :blk new_start_vaddr;
        } else {
            break :blk text_section.addr;
        }
    };

    const expand_text_section = block_placement == null or block_placement.?.next == null;
    if (expand_text_section) {
        const needed_size = (vaddr + new_block_size) - text_section.addr;
        const max_size = text_segment.allocatedSize(vaddr - pagezero_vmsize);
        log.debug("  (section __TEXT,__text needed size 0x{x}, max available size 0x{x})", .{ needed_size, max_size });

        if (needed_size > max_size) {
            const old_base_addr = text_section.addr;
            text_section.size = 0;
            const new_offset = @intCast(u32, text_segment.findFreeSpace(needed_size, alignment, self.header_pad));

            if (new_offset + needed_size >= text_segment.inner.fileoff + text_segment.inner.filesize) {
                // Bummer, need to move all segments below down...
                // TODO is this the right estimate?
                const new_seg_size = mem.alignForwardGeneric(
                    u64,
                    padToIdeal(text_segment.inner.filesize + needed_size),
                    self.page_size,
                );
                // TODO actually, we're always required to move in a number of pages so I guess all we need
                // to know here is the number of pages to shift downwards.
                const offset_amt = @intCast(
                    u32,
                    @intCast(i64, new_seg_size) - @intCast(i64, text_segment.inner.filesize),
                );
                text_segment.inner.filesize = new_seg_size;
                text_segment.inner.vmsize = new_seg_size;
                log.debug("  (new __TEXT segment file offsets from 0x{x} to 0x{x} (in memory 0x{x} to 0x{x}))", .{
                    text_segment.inner.fileoff,
                    text_segment.inner.fileoff + text_segment.inner.filesize,
                    text_segment.inner.vmaddr,
                    text_segment.inner.vmaddr + text_segment.inner.vmsize,
                });
                // TODO We should probably nop the expanded by distance, or put 0s.

                // TODO copyRangeAll doesn't automatically extend the file on macOS.
                const ledit_seg = &self.load_commands.items[self.linkedit_segment_cmd_index.?].Segment;
                const new_filesize = offset_amt + ledit_seg.inner.fileoff + ledit_seg.inner.filesize;
                try self.base.file.?.pwriteAll(&[_]u8{0}, new_filesize - 1);

                var next: usize = match.seg + 1;
                while (next < self.linkedit_segment_cmd_index.? + 1) : (next += 1) {
                    const next_seg = &self.load_commands.items[next].Segment;
                    _ = try self.base.file.?.copyRangeAll(
                        next_seg.inner.fileoff,
                        self.base.file.?,
                        next_seg.inner.fileoff + offset_amt,
                        next_seg.inner.filesize,
                    );
                    next_seg.inner.fileoff += offset_amt;
                    next_seg.inner.vmaddr += offset_amt;
                    log.debug("  (new {s} segment file offsets from 0x{x} to 0x{x} (in memory 0x{x} to 0x{x}))", .{
                        next_seg.inner.segname,
                        next_seg.inner.fileoff,
                        next_seg.inner.fileoff + next_seg.inner.filesize,
                        next_seg.inner.vmaddr,
                        next_seg.inner.vmaddr + next_seg.inner.vmsize,
                    });

                    for (next_seg.sections.items) |*moved_sect, moved_sect_id| {
                        // TODO put below snippet in a function.
                        const moved_match = MatchingSection{
                            .seg = @intCast(u16, next),
                            .sect = @intCast(u16, moved_sect_id),
                        };
                        const ptr_sect_offset = self.getPtrToSectionOffset(moved_match);
                        ptr_sect_offset.* += offset_amt;
                        moved_sect.addr += offset_amt;
                        log.debug("  (new {s},{s} file offsets from 0x{x} to 0x{x} (in memory 0x{x} to 0x{x}))", .{
                            commands.segmentName(moved_sect.*),
                            commands.sectionName(moved_sect.*),
                            ptr_sect_offset.*,
                            ptr_sect_offset.* + moved_sect.size,
                            moved_sect.addr,
                            moved_sect.addr + moved_sect.size,
                        });

                        try self.allocateLocalSymbols(moved_match, offset_amt);
                    }
                }
            }

            text_section.offset = new_offset;
            text_section.addr = text_segment.inner.vmaddr + text_section.offset - text_segment.inner.fileoff;
            log.debug("  (found new __TEXT,__text free space from 0x{x} to 0x{x})", .{
                new_offset,
                new_offset + needed_size,
            });
            const offset_amt = @intCast(i64, text_section.addr) - @intCast(i64, old_base_addr);
            try self.allocateLocalSymbols(.{
                .seg = self.text_segment_cmd_index.?,
                .sect = self.text_section_index.?,
            }, offset_amt);
            vaddr = @intCast(u64, @intCast(i64, vaddr) + offset_amt);
        }

        text_section.size = needed_size;
        self.load_commands_dirty = true;

        _ = try self.blocks.put(self.base.allocator, match, text_block);
    }
    text_block.size = new_block_size;

    if (text_block.prev) |prev| {
        prev.next = text_block.next;
    }
    if (text_block.next) |next| {
        next.prev = text_block.prev;
    }

    if (block_placement) |big_block| {
        text_block.prev = big_block;
        text_block.next = big_block.next;
        big_block.next = text_block;
    } else {
        text_block.prev = null;
        text_block.next = null;
    }
    if (free_list_removal) |i| {
        _ = text_block_free_list.swapRemove(i);
    }

    return vaddr;
}

pub fn addExternFn(self: *MachO, name: []const u8) !u32 {
    const sym_name = try std.fmt.allocPrint(self.base.allocator, "_{s}", .{name});
    defer self.base.allocator.free(sym_name);

    if (self.strtab_dir.getAdapted(@as([]const u8, sym_name), StringSliceAdapter{
        .strtab = &self.strtab,
    })) |n_strx| {
        const resolv = self.symbol_resolver.get(n_strx) orelse unreachable;
        return resolv.where_index;
    }

    log.debug("adding new extern function '{s}'", .{sym_name});
    const sym_index = @intCast(u32, self.undefs.items.len);
    const n_strx = try self.makeString(sym_name);
    try self.undefs.append(self.base.allocator, .{
        .n_strx = n_strx,
        .n_type = macho.N_UNDF,
        .n_sect = 0,
        .n_desc = 0,
        .n_value = 0,
    });
    try self.symbol_resolver.putNoClobber(self.base.allocator, n_strx, .{
        .where = .undef,
        .where_index = sym_index,
    });
    try self.unresolved.putNoClobber(self.base.allocator, sym_index, .stub);

    return sym_index;
}

const NextSegmentAddressAndOffset = struct {
    address: u64,
    offset: u64,
};

fn nextSegmentAddressAndOffset(self: *MachO) NextSegmentAddressAndOffset {
    var prev_segment_idx: ?usize = null; // We use optional here for safety.
    for (self.load_commands.items) |cmd, i| {
        if (cmd == .Segment) {
            prev_segment_idx = i;
        }
    }
    const prev_segment = self.load_commands.items[prev_segment_idx.?].Segment;
    const address = prev_segment.inner.vmaddr + prev_segment.inner.vmsize;
    const offset = prev_segment.inner.fileoff + prev_segment.inner.filesize;
    return .{
        .address = address,
        .offset = offset,
    };
}

fn updateSectionOrdinals(self: *MachO) !void {
    if (!self.sections_order_dirty) return;

    const tracy = trace(@src());
    defer tracy.end();

    var ordinal_remap = std.AutoHashMap(u8, u8).init(self.base.allocator);
    defer ordinal_remap.deinit();
    var ordinals: std.AutoArrayHashMapUnmanaged(MatchingSection, void) = .{};

    var new_ordinal: u8 = 0;
    for (self.load_commands.items) |lc, lc_id| {
        if (lc != .Segment) break;

        for (lc.Segment.sections.items) |_, sect_id| {
            const match = MatchingSection{
                .seg = @intCast(u16, lc_id),
                .sect = @intCast(u16, sect_id),
            };
            const old_ordinal = @intCast(u8, self.section_ordinals.getIndex(match).? + 1);
            new_ordinal += 1;
            try ordinal_remap.putNoClobber(old_ordinal, new_ordinal);
            try ordinals.putNoClobber(self.base.allocator, match, {});
        }
    }

    for (self.locals.items) |*sym| {
        if (sym.n_sect == 0) continue;
        sym.n_sect = ordinal_remap.get(sym.n_sect).?;
    }
    for (self.globals.items) |*sym| {
        sym.n_sect = ordinal_remap.get(sym.n_sect).?;
    }

    self.section_ordinals.deinit(self.base.allocator);
    self.section_ordinals = ordinals;
}

fn writeDyldInfoData(self: *MachO) !void {
    const tracy = trace(@src());
    defer tracy.end();

    var rebase_pointers = std.ArrayList(bind.Pointer).init(self.base.allocator);
    defer rebase_pointers.deinit();
    var bind_pointers = std.ArrayList(bind.Pointer).init(self.base.allocator);
    defer bind_pointers.deinit();
    var lazy_bind_pointers = std.ArrayList(bind.Pointer).init(self.base.allocator);
    defer lazy_bind_pointers.deinit();

    {
        var it = self.blocks.iterator();
        while (it.next()) |entry| {
            const match = entry.key_ptr.*;
            var atom: *TextBlock = entry.value_ptr.*;

            if (match.seg == self.text_segment_cmd_index.?) continue; // __TEXT is non-writable

            const seg = self.load_commands.items[match.seg].Segment;

            while (true) {
                const sym = self.locals.items[atom.local_sym_index];
                const base_offset = sym.n_value - seg.inner.vmaddr;

                for (atom.rebases.items) |offset| {
                    try rebase_pointers.append(.{
                        .offset = base_offset + offset,
                        .segment_id = match.seg,
                    });
                }

                for (atom.bindings.items) |binding| {
                    const bind_sym = self.undefs.items[binding.local_sym_index];
                    try bind_pointers.append(.{
                        .offset = binding.offset + base_offset,
                        .segment_id = match.seg,
                        .dylib_ordinal = @divExact(bind_sym.n_desc, macho.N_SYMBOL_RESOLVER),
                        .name = self.getString(bind_sym.n_strx),
                    });
                }

                for (atom.lazy_bindings.items) |binding| {
                    const bind_sym = self.undefs.items[binding.local_sym_index];
                    try lazy_bind_pointers.append(.{
                        .offset = binding.offset + base_offset,
                        .segment_id = match.seg,
                        .dylib_ordinal = @divExact(bind_sym.n_desc, macho.N_SYMBOL_RESOLVER),
                        .name = self.getString(bind_sym.n_strx),
                    });
                }

                if (atom.prev) |prev| {
                    atom = prev;
                } else break;
            }
        }
    }

    var trie: Trie = .{};
    defer trie.deinit(self.base.allocator);

    {
        // TODO handle macho.EXPORT_SYMBOL_FLAGS_REEXPORT and macho.EXPORT_SYMBOL_FLAGS_STUB_AND_RESOLVER.
        log.debug("generating export trie", .{});
        const text_segment = self.load_commands.items[self.text_segment_cmd_index.?].Segment;
        const base_address = text_segment.inner.vmaddr;

        for (self.globals.items) |sym| {
            const sym_name = self.getString(sym.n_strx);
            log.debug("  (putting '{s}' defined at 0x{x})", .{ sym_name, sym.n_value });

            try trie.put(self.base.allocator, .{
                .name = sym_name,
                .vmaddr_offset = sym.n_value - base_address,
                .export_flags = macho.EXPORT_SYMBOL_FLAGS_KIND_REGULAR,
            });
        }

        try trie.finalize(self.base.allocator);
    }

    const seg = &self.load_commands.items[self.linkedit_segment_cmd_index.?].Segment;
    const dyld_info = &self.load_commands.items[self.dyld_info_cmd_index.?].DyldInfoOnly;
    const rebase_size = try bind.rebaseInfoSize(rebase_pointers.items);
    const bind_size = try bind.bindInfoSize(bind_pointers.items);
    const lazy_bind_size = try bind.lazyBindInfoSize(lazy_bind_pointers.items);
    const export_size = trie.size;

    dyld_info.rebase_off = @intCast(u32, seg.inner.fileoff);
    dyld_info.rebase_size = @intCast(u32, mem.alignForwardGeneric(u64, rebase_size, @alignOf(u64)));
    seg.inner.filesize += dyld_info.rebase_size;

    dyld_info.bind_off = dyld_info.rebase_off + dyld_info.rebase_size;
    dyld_info.bind_size = @intCast(u32, mem.alignForwardGeneric(u64, bind_size, @alignOf(u64)));
    seg.inner.filesize += dyld_info.bind_size;

    dyld_info.lazy_bind_off = dyld_info.bind_off + dyld_info.bind_size;
    dyld_info.lazy_bind_size = @intCast(u32, mem.alignForwardGeneric(u64, lazy_bind_size, @alignOf(u64)));
    seg.inner.filesize += dyld_info.lazy_bind_size;

    dyld_info.export_off = dyld_info.lazy_bind_off + dyld_info.lazy_bind_size;
    dyld_info.export_size = @intCast(u32, mem.alignForwardGeneric(u64, export_size, @alignOf(u64)));
    seg.inner.filesize += dyld_info.export_size;

    const needed_size = dyld_info.rebase_size + dyld_info.bind_size + dyld_info.lazy_bind_size + dyld_info.export_size;
    var buffer = try self.base.allocator.alloc(u8, needed_size);
    defer self.base.allocator.free(buffer);
    mem.set(u8, buffer, 0);

    var stream = std.io.fixedBufferStream(buffer);
    const writer = stream.writer();

    try bind.writeRebaseInfo(rebase_pointers.items, writer);
    try stream.seekBy(@intCast(i64, dyld_info.rebase_size) - @intCast(i64, rebase_size));

    try bind.writeBindInfo(bind_pointers.items, writer);
    try stream.seekBy(@intCast(i64, dyld_info.bind_size) - @intCast(i64, bind_size));

    try bind.writeLazyBindInfo(lazy_bind_pointers.items, writer);
    try stream.seekBy(@intCast(i64, dyld_info.lazy_bind_size) - @intCast(i64, lazy_bind_size));

    _ = try trie.write(writer);

    log.debug("writing dyld info from 0x{x} to 0x{x}", .{
        dyld_info.rebase_off,
        dyld_info.rebase_off + needed_size,
    });

    try self.base.file.?.pwriteAll(buffer, dyld_info.rebase_off);
    try self.populateLazyBindOffsetsInStubHelper(
        buffer[dyld_info.rebase_size + dyld_info.bind_size ..][0..dyld_info.lazy_bind_size],
    );
    self.load_commands_dirty = true;
}

fn populateLazyBindOffsetsInStubHelper(self: *MachO, buffer: []const u8) !void {
    const last_atom = self.blocks.get(.{
        .seg = self.text_segment_cmd_index.?,
        .sect = self.stub_helper_section_index.?,
    }) orelse return;
    if (last_atom.local_sym_index == self.stub_preamble_sym_index.?) return;

    // Because we insert lazy binding opcodes in reverse order (from last to the first atom),
    // we need reverse the order of atom traversal here as well.
    // TODO figure out a less error prone mechanims for this!
    var atom = last_atom;
    while (atom.prev) |prev| {
        atom = prev;
    }
    atom = atom.next.?;

    var stream = std.io.fixedBufferStream(buffer);
    var reader = stream.reader();
    var offsets = std.ArrayList(u32).init(self.base.allocator);
    try offsets.append(0);
    defer offsets.deinit();
    var valid_block = false;

    while (true) {
        const inst = reader.readByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        const opcode: u8 = inst & macho.BIND_OPCODE_MASK;

        switch (opcode) {
            macho.BIND_OPCODE_DO_BIND => {
                valid_block = true;
            },
            macho.BIND_OPCODE_DONE => {
                if (valid_block) {
                    const offset = try stream.getPos();
                    try offsets.append(@intCast(u32, offset));
                }
                valid_block = false;
            },
            macho.BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM => {
                var next = try reader.readByte();
                while (next != @as(u8, 0)) {
                    next = try reader.readByte();
                }
            },
            macho.BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB => {
                _ = try std.leb.readULEB128(u64, reader);
            },
            macho.BIND_OPCODE_SET_DYLIB_ORDINAL_ULEB => {
                _ = try std.leb.readULEB128(u64, reader);
            },
            macho.BIND_OPCODE_SET_ADDEND_SLEB => {
                _ = try std.leb.readILEB128(i64, reader);
            },
            else => {},
        }
    }

    const seg = self.load_commands.items[self.text_segment_cmd_index.?].Segment;
    const sect = seg.sections.items[self.stub_helper_section_index.?];
    const stub_offset: u4 = switch (self.base.options.target.cpu.arch) {
        .x86_64 => 1,
        .aarch64 => 2 * @sizeOf(u32),
        else => unreachable,
    };
    var buf: [@sizeOf(u32)]u8 = undefined;
    _ = offsets.pop();
    while (offsets.popOrNull()) |bind_offset| {
        const sym = self.locals.items[atom.local_sym_index];
        const file_offset = sect.offset + sym.n_value - sect.addr + stub_offset;
        mem.writeIntLittle(u32, &buf, bind_offset);
        log.debug("writing lazy bind offset in stub helper of 0x{x} for symbol {s} at offset 0x{x}", .{
            bind_offset,
            self.getString(sym.n_strx),
            file_offset,
        });
        try self.base.file.?.pwriteAll(&buf, file_offset);

        if (atom.next) |next| {
            atom = next;
        } else break;
    }
}

fn writeDices(self: *MachO) !void {
    if (!self.has_dices) return;

    const tracy = trace(@src());
    defer tracy.end();

    var buf = std.ArrayList(u8).init(self.base.allocator);
    defer buf.deinit();

    var block: *TextBlock = self.blocks.get(.{
        .seg = self.text_segment_cmd_index orelse return,
        .sect = self.text_section_index orelse return,
    }) orelse return;

    while (block.prev) |prev| {
        block = prev;
    }

    const text_seg = self.load_commands.items[self.text_segment_cmd_index.?].Segment;
    const text_sect = text_seg.sections.items[self.text_section_index.?];

    while (true) {
        if (block.dices.items.len > 0) {
            const sym = self.locals.items[block.local_sym_index];
            const base_off = try math.cast(u32, sym.n_value - text_sect.addr + text_sect.offset);

            try buf.ensureUnusedCapacity(block.dices.items.len * @sizeOf(macho.data_in_code_entry));
            for (block.dices.items) |dice| {
                const rebased_dice = macho.data_in_code_entry{
                    .offset = base_off + dice.offset,
                    .length = dice.length,
                    .kind = dice.kind,
                };
                buf.appendSliceAssumeCapacity(mem.asBytes(&rebased_dice));
            }
        }

        if (block.next) |next| {
            block = next;
        } else break;
    }

    const seg = &self.load_commands.items[self.linkedit_segment_cmd_index.?].Segment;
    const dice_cmd = &self.load_commands.items[self.data_in_code_cmd_index.?].LinkeditData;
    const needed_size = @intCast(u32, buf.items.len);

    dice_cmd.dataoff = @intCast(u32, seg.inner.fileoff + seg.inner.filesize);
    dice_cmd.datasize = needed_size;
    seg.inner.filesize += needed_size;

    log.debug("writing data-in-code from 0x{x} to 0x{x}", .{
        dice_cmd.dataoff,
        dice_cmd.dataoff + dice_cmd.datasize,
    });

    try self.base.file.?.pwriteAll(buf.items, dice_cmd.dataoff);
    self.load_commands_dirty = true;
}

fn writeSymbolTable(self: *MachO) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const seg = &self.load_commands.items[self.linkedit_segment_cmd_index.?].Segment;
    const symtab = &self.load_commands.items[self.symtab_cmd_index.?].Symtab;
    symtab.symoff = @intCast(u32, seg.inner.fileoff + seg.inner.filesize);

    var locals = std.ArrayList(macho.nlist_64).init(self.base.allocator);
    defer locals.deinit();
    try locals.appendSlice(self.locals.items);

    if (self.has_stabs) {
        for (self.objects.items) |object| {
            if (object.debug_info == null) continue;

            // Open scope
            try locals.ensureUnusedCapacity(3);
            locals.appendAssumeCapacity(.{
                .n_strx = try self.makeString(object.tu_comp_dir.?),
                .n_type = macho.N_SO,
                .n_sect = 0,
                .n_desc = 0,
                .n_value = 0,
            });
            locals.appendAssumeCapacity(.{
                .n_strx = try self.makeString(object.tu_name.?),
                .n_type = macho.N_SO,
                .n_sect = 0,
                .n_desc = 0,
                .n_value = 0,
            });
            locals.appendAssumeCapacity(.{
                .n_strx = try self.makeString(object.name),
                .n_type = macho.N_OSO,
                .n_sect = 0,
                .n_desc = 1,
                .n_value = object.mtime orelse 0,
            });

            for (object.text_blocks.items) |block| {
                if (block.stab) |stab| {
                    const nlists = try stab.asNlists(block.local_sym_index, self);
                    defer self.base.allocator.free(nlists);
                    try locals.appendSlice(nlists);
                } else {
                    for (block.contained.items) |sym_at_off| {
                        const stab = sym_at_off.stab orelse continue;
                        const nlists = try stab.asNlists(sym_at_off.local_sym_index, self);
                        defer self.base.allocator.free(nlists);
                        try locals.appendSlice(nlists);
                    }
                }
            }

            // Close scope
            try locals.append(.{
                .n_strx = 0,
                .n_type = macho.N_SO,
                .n_sect = 0,
                .n_desc = 0,
                .n_value = 0,
            });
        }
    }

    const nlocals = locals.items.len;
    const nexports = self.globals.items.len;
    const nundefs = self.undefs.items.len;

    const locals_off = symtab.symoff;
    const locals_size = nlocals * @sizeOf(macho.nlist_64);
    log.debug("writing local symbols from 0x{x} to 0x{x}", .{ locals_off, locals_size + locals_off });
    try self.base.file.?.pwriteAll(mem.sliceAsBytes(locals.items), locals_off);

    const exports_off = locals_off + locals_size;
    const exports_size = nexports * @sizeOf(macho.nlist_64);
    log.debug("writing exported symbols from 0x{x} to 0x{x}", .{ exports_off, exports_size + exports_off });
    try self.base.file.?.pwriteAll(mem.sliceAsBytes(self.globals.items), exports_off);

    const undefs_off = exports_off + exports_size;
    const undefs_size = nundefs * @sizeOf(macho.nlist_64);
    log.debug("writing undefined symbols from 0x{x} to 0x{x}", .{ undefs_off, undefs_size + undefs_off });
    try self.base.file.?.pwriteAll(mem.sliceAsBytes(self.undefs.items), undefs_off);

    symtab.nsyms = @intCast(u32, nlocals + nexports + nundefs);
    seg.inner.filesize += locals_size + exports_size + undefs_size;

    // Update dynamic symbol table.
    const dysymtab = &self.load_commands.items[self.dysymtab_cmd_index.?].Dysymtab;
    dysymtab.nlocalsym = @intCast(u32, nlocals);
    dysymtab.iextdefsym = dysymtab.nlocalsym;
    dysymtab.nextdefsym = @intCast(u32, nexports);
    dysymtab.iundefsym = dysymtab.nlocalsym + dysymtab.nextdefsym;
    dysymtab.nundefsym = @intCast(u32, nundefs);

    const text_segment = &self.load_commands.items[self.text_segment_cmd_index.?].Segment;
    const stubs = &text_segment.sections.items[self.stubs_section_index.?];
    const data_const_segment = &self.load_commands.items[self.data_const_segment_cmd_index.?].Segment;
    const got = &data_const_segment.sections.items[self.got_section_index.?];
    const data_segment = &self.load_commands.items[self.data_segment_cmd_index.?].Segment;
    const la_symbol_ptr = &data_segment.sections.items[self.la_symbol_ptr_section_index.?];

    const nstubs = @intCast(u32, self.stubs_map.keys().len);
    const ngot_entries = @intCast(u32, self.got_entries_map.keys().len);

    dysymtab.indirectsymoff = @intCast(u32, seg.inner.fileoff + seg.inner.filesize);
    dysymtab.nindirectsyms = nstubs * 2 + ngot_entries;

    const needed_size = dysymtab.nindirectsyms * @sizeOf(u32);
    seg.inner.filesize += needed_size;

    log.debug("writing indirect symbol table from 0x{x} to 0x{x}", .{
        dysymtab.indirectsymoff,
        dysymtab.indirectsymoff + needed_size,
    });

    var buf = try self.base.allocator.alloc(u8, needed_size);
    defer self.base.allocator.free(buf);

    var stream = std.io.fixedBufferStream(buf);
    var writer = stream.writer();

    stubs.reserved1 = 0;
    for (self.stubs_map.keys()) |key| {
        try writer.writeIntLittle(u32, dysymtab.iundefsym + key);
    }

    got.reserved1 = nstubs;
    for (self.got_entries_map.keys()) |key| {
        switch (key.where) {
            .undef => {
                try writer.writeIntLittle(u32, dysymtab.iundefsym + key.where_index);
            },
            .local => {
                try writer.writeIntLittle(u32, macho.INDIRECT_SYMBOL_LOCAL);
            },
        }
    }

    la_symbol_ptr.reserved1 = got.reserved1 + ngot_entries;
    for (self.stubs_map.keys()) |key| {
        try writer.writeIntLittle(u32, dysymtab.iundefsym + key);
    }

    try self.base.file.?.pwriteAll(buf, dysymtab.indirectsymoff);
    self.load_commands_dirty = true;
}

fn writeStringTable(self: *MachO) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const seg = &self.load_commands.items[self.linkedit_segment_cmd_index.?].Segment;
    const symtab = &self.load_commands.items[self.symtab_cmd_index.?].Symtab;
    symtab.stroff = @intCast(u32, seg.inner.fileoff + seg.inner.filesize);
    symtab.strsize = @intCast(u32, mem.alignForwardGeneric(u64, self.strtab.items.len, @alignOf(u64)));
    seg.inner.filesize += symtab.strsize;

    log.debug("writing string table from 0x{x} to 0x{x}", .{ symtab.stroff, symtab.stroff + symtab.strsize });

    try self.base.file.?.pwriteAll(self.strtab.items, symtab.stroff);

    if (symtab.strsize > self.strtab.items.len) {
        // This is potentially the last section, so we need to pad it out.
        try self.base.file.?.pwriteAll(&[_]u8{0}, seg.inner.fileoff + seg.inner.filesize - 1);
    }
    self.load_commands_dirty = true;
}

fn writeLinkeditSegment(self: *MachO) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const seg = &self.load_commands.items[self.linkedit_segment_cmd_index.?].Segment;
    seg.inner.filesize = 0;

    try self.writeDyldInfoData();
    try self.writeDices();
    try self.writeSymbolTable();
    try self.writeStringTable();

    seg.inner.vmsize = mem.alignForwardGeneric(u64, seg.inner.filesize, self.page_size);
}

fn writeCodeSignaturePadding(self: *MachO) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const linkedit_segment = &self.load_commands.items[self.linkedit_segment_cmd_index.?].Segment;
    const code_sig_cmd = &self.load_commands.items[self.code_signature_cmd_index.?].LinkeditData;
    const fileoff = linkedit_segment.inner.fileoff + linkedit_segment.inner.filesize;
    const needed_size = CodeSignature.calcCodeSignaturePaddingSize(
        self.base.options.emit.?.sub_path,
        fileoff,
        self.page_size,
    );
    code_sig_cmd.dataoff = @intCast(u32, fileoff);
    code_sig_cmd.datasize = needed_size;

    // Advance size of __LINKEDIT segment
    linkedit_segment.inner.filesize += needed_size;
    if (linkedit_segment.inner.vmsize < linkedit_segment.inner.filesize) {
        linkedit_segment.inner.vmsize = mem.alignForwardGeneric(u64, linkedit_segment.inner.filesize, self.page_size);
    }
    log.debug("writing code signature padding from 0x{x} to 0x{x}", .{ fileoff, fileoff + needed_size });
    // Pad out the space. We need to do this to calculate valid hashes for everything in the file
    // except for code signature data.
    try self.base.file.?.pwriteAll(&[_]u8{0}, fileoff + needed_size - 1);
    self.load_commands_dirty = true;
}

fn writeCodeSignature(self: *MachO) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const text_segment = self.load_commands.items[self.text_segment_cmd_index.?].Segment;
    const code_sig_cmd = self.load_commands.items[self.code_signature_cmd_index.?].LinkeditData;

    var code_sig: CodeSignature = .{};
    defer code_sig.deinit(self.base.allocator);

    try code_sig.calcAdhocSignature(
        self.base.allocator,
        self.base.file.?,
        self.base.options.emit.?.sub_path,
        text_segment.inner,
        code_sig_cmd,
        self.base.options.output_mode,
        self.page_size,
    );

    var buffer = try self.base.allocator.alloc(u8, code_sig.size());
    defer self.base.allocator.free(buffer);
    var stream = std.io.fixedBufferStream(buffer);
    try code_sig.write(stream.writer());

    log.debug("writing code signature from 0x{x} to 0x{x}", .{ code_sig_cmd.dataoff, code_sig_cmd.dataoff + buffer.len });

    try self.base.file.?.pwriteAll(buffer, code_sig_cmd.dataoff);
}

/// Writes all load commands and section headers.
fn writeLoadCommands(self: *MachO) !void {
    if (!self.load_commands_dirty) return;

    var sizeofcmds: u32 = 0;
    for (self.load_commands.items) |lc| {
        sizeofcmds += lc.cmdsize();
    }

    var buffer = try self.base.allocator.alloc(u8, sizeofcmds);
    defer self.base.allocator.free(buffer);
    var writer = std.io.fixedBufferStream(buffer).writer();
    for (self.load_commands.items) |lc| {
        try lc.write(writer);
    }

    const off = @sizeOf(macho.mach_header_64);

    log.debug("writing {} load commands from 0x{x} to 0x{x}", .{ self.load_commands.items.len, off, off + sizeofcmds });

    try self.base.file.?.pwriteAll(buffer, off);
    self.load_commands_dirty = false;
}

/// Writes Mach-O file header.
fn writeHeader(self: *MachO) !void {
    var header = commands.emptyHeader(.{
        .flags = macho.MH_NOUNDEFS | macho.MH_DYLDLINK | macho.MH_PIE | macho.MH_TWOLEVEL,
    });

    switch (self.base.options.target.cpu.arch) {
        .aarch64 => {
            header.cputype = macho.CPU_TYPE_ARM64;
            header.cpusubtype = macho.CPU_SUBTYPE_ARM_ALL;
        },
        .x86_64 => {
            header.cputype = macho.CPU_TYPE_X86_64;
            header.cpusubtype = macho.CPU_SUBTYPE_X86_64_ALL;
        },
        else => return error.UnsupportedCpuArchitecture,
    }

    switch (self.base.options.output_mode) {
        .Exe => {
            header.filetype = macho.MH_EXECUTE;
        },
        .Lib => {
            // By this point, it can only be a dylib.
            header.filetype = macho.MH_DYLIB;
            header.flags |= macho.MH_NO_REEXPORTED_DYLIBS;
        },
        else => unreachable,
    }

    if (self.tlv_section_index) |_| {
        header.flags |= macho.MH_HAS_TLV_DESCRIPTORS;
    }

    header.ncmds = @intCast(u32, self.load_commands.items.len);
    header.sizeofcmds = 0;

    for (self.load_commands.items) |cmd| {
        header.sizeofcmds += cmd.cmdsize();
    }

    log.debug("writing Mach-O header {}", .{header});

    try self.base.file.?.pwriteAll(mem.asBytes(&header), 0);
}

pub fn padToIdeal(actual_size: anytype) @TypeOf(actual_size) {
    // TODO https://github.com/ziglang/zig/issues/1284
    return std.math.add(@TypeOf(actual_size), actual_size, actual_size / ideal_factor) catch
        std.math.maxInt(@TypeOf(actual_size));
}

pub fn makeStaticString(bytes: []const u8) [16]u8 {
    var buf = [_]u8{0} ** 16;
    assert(bytes.len <= buf.len);
    mem.copy(u8, &buf, bytes);
    return buf;
}

pub fn makeString(self: *MachO, string: []const u8) !u32 {
    if (self.strtab_dir.getAdapted(@as([]const u8, string), StringSliceAdapter{ .strtab = &self.strtab })) |off| {
        log.debug("reusing string '{s}' at offset 0x{x}", .{ string, off });
        return off;
    }

    try self.strtab.ensureUnusedCapacity(self.base.allocator, string.len + 1);
    const new_off = @intCast(u32, self.strtab.items.len);

    log.debug("writing new string '{s}' at offset 0x{x}", .{ string, new_off });

    self.strtab.appendSliceAssumeCapacity(string);
    self.strtab.appendAssumeCapacity(0);

    try self.strtab_dir.putContext(self.base.allocator, new_off, new_off, StringIndexContext{
        .strtab = &self.strtab,
    });

    return new_off;
}

pub fn getString(self: *MachO, off: u32) []const u8 {
    assert(off < self.strtab.items.len);
    return mem.spanZ(@ptrCast([*:0]const u8, self.strtab.items.ptr + off));
}

pub fn symbolIsStab(sym: macho.nlist_64) bool {
    return (macho.N_STAB & sym.n_type) != 0;
}

pub fn symbolIsPext(sym: macho.nlist_64) bool {
    return (macho.N_PEXT & sym.n_type) != 0;
}

pub fn symbolIsExt(sym: macho.nlist_64) bool {
    return (macho.N_EXT & sym.n_type) != 0;
}

pub fn symbolIsSect(sym: macho.nlist_64) bool {
    const type_ = macho.N_TYPE & sym.n_type;
    return type_ == macho.N_SECT;
}

pub fn symbolIsUndf(sym: macho.nlist_64) bool {
    const type_ = macho.N_TYPE & sym.n_type;
    return type_ == macho.N_UNDF;
}

pub fn symbolIsIndr(sym: macho.nlist_64) bool {
    const type_ = macho.N_TYPE & sym.n_type;
    return type_ == macho.N_INDR;
}

pub fn symbolIsAbs(sym: macho.nlist_64) bool {
    const type_ = macho.N_TYPE & sym.n_type;
    return type_ == macho.N_ABS;
}

pub fn symbolIsWeakDef(sym: macho.nlist_64) bool {
    return (sym.n_desc & macho.N_WEAK_DEF) != 0;
}

pub fn symbolIsWeakRef(sym: macho.nlist_64) bool {
    return (sym.n_desc & macho.N_WEAK_REF) != 0;
}

pub fn symbolIsTentative(sym: macho.nlist_64) bool {
    if (!symbolIsUndf(sym)) return false;
    return sym.n_value != 0;
}

pub fn symbolIsTemp(sym: macho.nlist_64, sym_name: []const u8) bool {
    if (!symbolIsSect(sym)) return false;
    if (symbolIsExt(sym)) return false;
    return mem.startsWith(u8, sym_name, "l") or mem.startsWith(u8, sym_name, "L");
}

pub fn findFirst(comptime T: type, haystack: []T, start: usize, predicate: anytype) usize {
    if (!@hasDecl(@TypeOf(predicate), "predicate"))
        @compileError("Predicate is required to define fn predicate(@This(), T) bool");

    if (start == haystack.len) return start;

    var i = start;
    while (i < haystack.len) : (i += 1) {
        if (predicate.predicate(haystack[i])) break;
    }
    return i;
}
