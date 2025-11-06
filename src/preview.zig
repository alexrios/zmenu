const std = @import("std");

/// Preview state indicates what kind of content is being shown
pub const PreviewState = enum {
    none, // No preview available
    loading, // Preview is being loaded
    text, // Text preview loaded successfully
    binary, // Binary file detected
    not_found, // File not found
    permission_denied, // Cannot read file
    too_large, // File exceeds size limit
};

pub const PreviewConfig = struct {
    enable_preview: bool = false, // Toggle with Ctrl+P
    preview_width_percent: u8 = 70, // Percentage of window width for preview pane
    max_preview_bytes: usize = 1024 * 1024, // 1MB max file size to preview
};

/// Check if a file path has a known text file extension
pub fn isTextFile(path: []const u8) bool {
    // Check file extension for known text types
    const text_extensions = [_][]const u8{
        ".txt",  ".md",   ".markdown", ".rst",  ".log",  ".csv",  ".tsv",
        ".zig",  ".c",    ".h",        ".cpp",  ".hpp",  ".cc",   ".cxx",
        ".rs",   ".go",   ".py",       ".rb",   ".lua",  ".sh",   ".bash",
        ".zsh",  ".fish", ".js",       ".ts",   ".jsx",  ".tsx",  ".json",
        ".xml",  ".html", ".htm",      ".css",  ".scss", ".sass", ".less",
        ".yaml", ".yml",  ".toml",     ".ini",  ".conf", ".cfg",  ".config",
        ".java", ".kt",   ".kts",      ".scala", ".clj", ".ex",   ".exs",
        ".el",   ".vim",  ".vimrc",    ".diff", ".patch", ".sql", ".pl",
        ".pm",   ".r",    ".R",        ".m",    ".mm",   ".swift", ".dart",
        ".php",  ".cs",   ".fs",       ".fsx",  ".ml",   ".mli",  ".hs",
    };

    // Check if path ends with any text extension (case-insensitive)
    for (text_extensions) |ext| {
        if (path.len >= ext.len) {
            const path_end = path[path.len - ext.len ..];
            if (std.ascii.eqlIgnoreCase(path_end, ext)) {
                return true;
            }
        }
    }

    // Special case: files without extension might be text (e.g., Makefile, Dockerfile)
    // We'll check content in loadPreview
    return false;
}

/// Check if a file path has a known binary file extension
pub fn isBinaryFile(path: []const u8) bool {
    // Check for known binary extensions
    const binary_extensions = [_][]const u8{
        ".exe",  ".dll",  ".so",   ".dylib", ".a",    ".o",    ".bin",
        ".pdf",  ".doc",  ".docx", ".xls",   ".xlsx", ".ppt",  ".pptx",
        ".zip",  ".tar",  ".gz",   ".bz2",   ".xz",   ".7z",   ".rar",
        ".png",  ".jpg",  ".jpeg", ".gif",   ".bmp",  ".ico",  ".svg",
        ".mp3",  ".mp4",  ".avi",  ".mkv",   ".mov",  ".wav",  ".flac",
        ".ttf",  ".otf",  ".woff", ".woff2", ".eot",
        ".class", ".jar", ".pyc",  ".pyo",   ".wasm",
    };

    for (binary_extensions) |ext| {
        if (path.len >= ext.len) {
            const path_end = path[path.len - ext.len ..];
            if (std.ascii.eqlIgnoreCase(path_end, ext)) {
                return true;
            }
        }
    }

    return false;
}

/// Check if data contains null bytes (indicating binary content)
pub fn containsNullByte(data: []const u8) bool {
    for (data) |byte| {
        if (byte == 0) return true;
    }
    return false;
}

/// Count the number of lines in content
/// Handles files with and without trailing newlines correctly
pub fn countLines(content: []const u8) usize {
    if (content.len == 0) return 0;

    var count: usize = 0;
    for (content) |byte| {
        if (byte == '\n') count += 1;
    }

    // Add 1 if content doesn't end with newline
    if (content[content.len - 1] != '\n') {
        count += 1;
    }

    return count;
}

/// Read file contents up to max_bytes limit
pub fn readFileContent(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    if (stat.size > max_bytes) {
        return error.FileTooLarge;
    }

    const content = try file.readToEndAlloc(allocator, max_bytes);
    return content;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "countLines - empty content" {
    try testing.expectEqual(@as(usize, 0), countLines(""));
}

test "countLines - single line without newline" {
    try testing.expectEqual(@as(usize, 1), countLines("hello"));
}

test "countLines - single line with newline" {
    try testing.expectEqual(@as(usize, 1), countLines("hello\n"));
}

test "countLines - multiple lines" {
    try testing.expectEqual(@as(usize, 3), countLines("line1\nline2\nline3"));
    try testing.expectEqual(@as(usize, 3), countLines("line1\nline2\nline3\n"));
}

test "countLines - UTF-8 content" {
    try testing.expectEqual(@as(usize, 3), countLines("日本語\nCafé\n🎉\n"));
}

test "isTextFile - text extensions" {
    try testing.expect(isTextFile("file.txt"));
    try testing.expect(isTextFile("file.zig"));
    try testing.expect(isTextFile("file.c"));
    try testing.expect(isTextFile("file.py"));
    try testing.expect(isTextFile("file.json"));
}

test "isTextFile - case insensitive" {
    try testing.expect(isTextFile("FILE.TXT"));
    try testing.expect(isTextFile("File.Zig"));
}

test "isTextFile - with paths" {
    try testing.expect(isTextFile("/home/user/file.zig"));
    try testing.expect(isTextFile("./src/main.c"));
}

test "isTextFile - binary extensions" {
    try testing.expect(!isTextFile("file.exe"));
    try testing.expect(!isTextFile("file.png"));
}

test "isBinaryFile - binary extensions" {
    try testing.expect(isBinaryFile("file.exe"));
    try testing.expect(isBinaryFile("file.pdf"));
    try testing.expect(isBinaryFile("file.png"));
    try testing.expect(isBinaryFile("file.zip"));
}

test "isBinaryFile - case insensitive" {
    try testing.expect(isBinaryFile("FILE.EXE"));
    try testing.expect(isBinaryFile("Image.PNG"));
}

test "isBinaryFile - text files" {
    try testing.expect(!isBinaryFile("file.txt"));
    try testing.expect(!isBinaryFile("file.zig"));
}

test "containsNullByte - pure text" {
    try testing.expect(!containsNullByte("Hello, World!"));
}

test "containsNullByte - with null" {
    const data = [_]u8{ 'h', 'e', 0, 'l', 'o' };
    try testing.expect(containsNullByte(&data));
}

test "containsNullByte - empty" {
    try testing.expect(!containsNullByte(""));
}

test "PreviewConfig - defaults" {
    const config = PreviewConfig{};
    try testing.expect(!config.enable_preview);
    try testing.expectEqual(@as(u8, 70), config.preview_width_percent);
    try testing.expectEqual(@as(usize, 1024 * 1024), config.max_preview_bytes);
}

test "readFileContent - file too large" {
    const allocator = testing.allocator;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a 2KB file
    var buffer: [2000]u8 = undefined;
    @memset(&buffer, 'x');
    const file = try tmp_dir.dir.createFile("large.txt", .{});
    defer file.close();
    try file.writeAll(&buffer);

    const path = try tmp_dir.dir.realpathAlloc(allocator, "large.txt");
    defer allocator.free(path);

    // Try to read with 1KB limit
    try testing.expectError(error.FileTooLarge, readFileContent(allocator, path, 1000));
}

test "readFileContent - successful read" {
    const allocator = testing.allocator;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_content = "Hello, World!";
    const file = try tmp_dir.dir.createFile("test.txt", .{});
    defer file.close();
    try file.writeAll(test_content);

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.txt");
    defer allocator.free(path);

    const content = try readFileContent(allocator, path, 1024);
    defer allocator.free(content);

    try testing.expectEqualStrings(test_content, content);
}
