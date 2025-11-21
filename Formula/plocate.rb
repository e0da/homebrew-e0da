class Plocate < Formula
  desc "Much faster locate based on posting lists"
  homepage "https://plocate.sesse.net/"
  url "https://plocate.sesse.net/download/plocate-1.1.23.tar.gz"
  sha256 "06bd3b284d5d077b441bef74edb0cc6f8e3f0a6f58b4c15ef865d3c460733783"
  license "GPL-2.0-or-later"

  depends_on "meson" => :build
  depends_on "ninja" => :build
  depends_on "pkg-config" => :build
  depends_on "libuv"
  depends_on "zstd"

  # Patch for macOS compatibility and libuv integration
  patch :DATA

  def install
    # Copy libuv shim files into source directory
    libuv_shim_h = <<~EOS
#ifndef LIBUV_SHIM_H
#define LIBUV_SHIM_H

#include <functional>
#include <queue>
#include <stddef.h>
#include <string_view>

// Forward declarations to avoid including uv.h in header
struct uv_loop_s;
struct uv_fs_s;

// libuv-based shim for io_uring on macOS
// Provides the same interface as IOUringEngine but uses libuv for async I/O

class LibuvShim {
public:
    LibuvShim(size_t slop_bytes);
    ~LibuvShim();

    void submit_read(int fd, size_t len, off_t offset, std::function<void(std::string_view)> cb);
    void submit_stat(const char *path, std::function<void(bool ok)> cb);
    bool get_supports_stat() const { return true; } // libuv always supports stat

    void finish();
    size_t get_waiting_reads() const { return pending_ops + queued_reads.size(); }

private:
    static constexpr size_t queue_depth = 256;
    const size_t slop_bytes;

    uv_loop_s *loop;  // Use pointer to avoid including uv.h
    bool loop_initialized = false;
    size_t pending_ops = 0;

    struct QueuedRead {
        int fd;
        size_t len;
        off_t offset;
        std::function<void(std::string_view)> cb;
    };
    std::queue<QueuedRead> queued_reads;

    struct QueuedStat {
        char *pathname;  // Owned by us
        std::function<void(bool)> cb;
    };
    std::queue<QueuedStat> queued_stats;

    struct PendingOp {
        enum Type { READ, STAT };
        Type type;
        LibuvShim *shim;  // Back pointer to shim instance

        std::function<void(std::string_view)> read_cb;
        std::function<void(bool)> stat_cb;

        union {
            struct {
                void *buf;         // Current read position
                void *buf_start;   // Original buffer start (for cleanup)
                size_t len;        // Remaining bytes to read
                size_t len_original; // Original requested length (for callback)
                int fd;
                off_t offset;
            } read;
            struct {
                char *pathname;
            } stat;
        };
    };

    void process_queued_ops();
    static void read_callback(uv_fs_s *req);
    static void stat_callback(uv_fs_s *req);
};

#endif // LIBUV_SHIM_H
EOS

    libuv_shim_cpp = <<~EOS
#include "libuv_shim.h"
#include <uv.h>
#include <cassert>
#include <cstring>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

LibuvShim::LibuvShim(size_t slop_bytes)
    : slop_bytes(slop_bytes), loop(nullptr)
{
    loop = new uv_loop_t;
    int ret = uv_loop_init(loop);
    if (ret == 0) {
        loop_initialized = true;
    } else {
        fprintf(stderr, "uv_loop_init() failed: %s\\n", uv_strerror(ret));
        delete loop;
        loop = nullptr;
    }
}

LibuvShim::~LibuvShim()
{
    if (loop_initialized && loop) {
        // Process any remaining operations
        finish();
        uv_loop_close(loop);
        delete loop;
        loop = nullptr;
    }
}

void LibuvShim::submit_read(int fd, size_t len, off_t offset, std::function<void(std::string_view)> cb)
{
    if (!loop_initialized || pending_ops >= queue_depth) {
        // Queue for later if at capacity
        queued_reads.push(QueuedRead{ fd, len, offset, cb });
        return;
    }

    // Allocate buffer (aligned for performance)
    void *buf;
    if (posix_memalign(&buf, 4096, len + slop_bytes)) {
        fprintf(stderr, "Couldn't allocate %zu bytes: %s\\n", len, strerror(errno));
        exit(1);
    }

    // Create pending operation
    PendingOp *pending = new PendingOp;
    pending->type = PendingOp::READ;
    pending->shim = this;
    pending->read_cb = cb;
    pending->read.buf = buf;
    pending->read.buf_start = buf;  // Store original for cleanup
    pending->read.len = len;
    pending->read.len_original = len;  // Store original length for callback
    pending->read.fd = fd;
    pending->read.offset = offset;

    // Create libuv request (uv_fs_t is typedef for uv_fs_s, but we use the struct name)
    uv_fs_t *req = static_cast<uv_fs_t*>(malloc(sizeof(uv_fs_t)));
    memset(req, 0, sizeof(uv_fs_t));
    req->data = pending;

    // Submit async read
    uv_buf_t uv_buf = uv_buf_init(static_cast<char*>(buf), len);
    int ret = uv_fs_read(loop, req, fd, &uv_buf, 1, offset, read_callback);

    if (ret < 0) {
        fprintf(stderr, "uv_fs_read() failed: %s\\n", uv_strerror(ret));
        free(buf);
        delete pending;
        uv_fs_req_cleanup(req);
        free(req);
        exit(1);
    }

    ++pending_ops;
}

void LibuvShim::submit_stat(const char *path, std::function<void(bool ok)> cb)
{
    if (!loop_initialized || pending_ops >= queue_depth) {
        // Queue for later if at capacity
        queued_stats.push(QueuedStat{ strdup(path), cb });
        return;
    }

    // Create pending operation
    PendingOp *pending = new PendingOp;
    pending->type = PendingOp::STAT;
    pending->shim = this;
    pending->stat_cb = cb;
    pending->stat.pathname = strdup(path);

    // Create libuv request
    uv_fs_t *req = static_cast<uv_fs_t*>(malloc(sizeof(uv_fs_t)));
    memset(req, 0, sizeof(uv_fs_t));
    req->data = pending;

    // Submit async stat
    int ret = uv_fs_stat(loop, req, path, stat_callback);

    if (ret < 0) {
        fprintf(stderr, "uv_fs_stat() failed: %s\\n", uv_strerror(ret));
        free(pending->stat.pathname);
        delete pending;
        uv_fs_req_cleanup(req);
        free(req);
        exit(1);
    }

    ++pending_ops;
}

void LibuvShim::read_callback(uv_fs_s *req)
{
    PendingOp *pending = static_cast<PendingOp*>(req->data);
    LibuvShim *shim = pending->shim;

    assert(pending->type == PendingOp::READ);

    if (req->result < 0) {
        fprintf(stderr, "async read failed: %s\\n", uv_strerror(req->result));
        free(pending->read.buf_start);  // Use original buffer for cleanup
        delete pending;
        uv_fs_req_cleanup(req);
        free(req);
        shim->pending_ops--;
        exit(1);
    }

    size_t bytes_read = req->result;

    if (bytes_read < pending->read.len) {
        // Incomplete read - resubmit for remaining data
        pending->read.buf = static_cast<char*>(pending->read.buf) + bytes_read;
        pending->read.len -= bytes_read;
        pending->read.offset += bytes_read;

        uv_buf_t uv_buf = uv_buf_init(static_cast<char*>(pending->read.buf), pending->read.len);
        int ret = uv_fs_read(shim->loop, req, pending->read.fd, &uv_buf, 1, pending->read.offset, read_callback);

        if (ret < 0) {
            fprintf(stderr, "uv_fs_read() resubmit failed: %s\\n", uv_strerror(ret));
            free(pending->read.buf_start);  // Use original buffer for cleanup
            delete pending;
            uv_fs_req_cleanup(req);
            free(req);
            shim->pending_ops--;
            exit(1);
        }
        return; // Will be called again when resubmit completes
    }

    // Call callback with data (use original buffer start, original length)
    pending->read_cb(std::string_view(static_cast<char*>(pending->read.buf_start), pending->read.len_original));

    // Cleanup (use original buffer start)
    free(pending->read.buf_start);
    delete pending;
    uv_fs_req_cleanup(req);
    free(req);

    // Decrement pending count and process queued ops
    shim->pending_ops--;
    shim->process_queued_ops();
}

void LibuvShim::stat_callback(uv_fs_s *req)
{
    PendingOp *pending = static_cast<PendingOp*>(req->data);
    LibuvShim *shim = pending->shim;

    assert(pending->type == PendingOp::STAT);

    bool ok = (req->result == 0);

    // Call callback
    pending->stat_cb(ok);

    // Cleanup
    free(pending->stat.pathname);
    delete pending;
    uv_fs_req_cleanup(req);
    free(req);

    // Decrement pending count and process queued ops
    shim->pending_ops--;
    shim->process_queued_ops();
}

void LibuvShim::process_queued_ops()
{
    // Process queued stats first (prioritized)
    while (!queued_stats.empty() && pending_ops < queue_depth) {
        QueuedStat qs = queued_stats.front();
        queued_stats.pop();
        submit_stat(qs.pathname, qs.cb);
        // Note: submit_stat will strdup, so we free the original
        free(qs.pathname);
    }

    // Process queued reads
    while (!queued_reads.empty() && pending_ops < queue_depth) {
        QueuedRead qr = queued_reads.front();
        queued_reads.pop();
        submit_read(qr.fd, qr.len, qr.offset, qr.cb);
    }
}

void LibuvShim::finish()
{
    if (!loop_initialized) {
        return;
    }

    // Process all queued operations
    process_queued_ops();

    // Run event loop until all operations complete
    while (pending_ops > 0) {
        // Run loop with timeout to process events
        uv_run(loop, UV_RUN_ONCE);

        // Process any newly queued operations
        process_queued_ops();
    }

    // Final cleanup
    uv_run(loop, UV_RUN_DEFAULT);
}
EOS

    (buildpath/"libuv_shim.h").write(libuv_shim_h)
    (buildpath/"libuv_shim.cpp").write(libuv_shim_cpp)

    system "meson", "setup", "build", *std_meson_args
    system "meson", "compile", "-C", "build"
    # Set DESTDIR for custom install scripts (like mkdir.sh) - empty so meson uses prefix directly
    ENV.delete("DESTDIR")
    system "meson", "install", "-C", "build", "--destdir", "/"
  end

  test do
    # Test that plocate can be executed and shows version/help
    assert_match "plocate", shell_output("#{bin}/plocate --help 2>&1", 1)
    # Test plocate-build exists
    assert_match "plocate-build", shell_output("#{sbin}/plocate-build --help 2>&1", 1)
  end
end

__END__
--- a/turbopfor.cpp	2024-11-24 22:14:30
+++ b/turbopfor.cpp	2025-11-21 00:12:33
@@ -2,7 +2,23 @@
 #include <assert.h>
 #ifdef HAS_ENDIAN_H
 #include <endian.h>
+#else
+// macOS doesn't have endian.h, provide fallback implementations
+#ifdef __APPLE__
+#include <libkern/OSByteOrder.h>
+#define le16toh(x) OSSwapLittleToHostInt16(x)
+#define le32toh(x) OSSwapLittleToHostInt32(x)
+#define le64toh(x) OSSwapLittleToHostInt64(x)
+#define htole16(x) OSSwapHostToLittleInt16(x)
+#define htole32(x) OSSwapHostToLittleInt32(x)
+#define htole64(x) OSSwapHostToLittleInt64(x)
+#else
+// Generic fallback for little-endian systems (assumes host is little-endian)
+#define le16toh(x) (x)
+#define le32toh(x) (x)
+#define le64toh(x) (x)
 #endif
+#endif
 #include <stdint.h>
 #include <string.h>
 #include <strings.h>
--- a/turbopfor-encode.h	2024-11-24 22:14:30
+++ b/turbopfor-encode.h	2025-11-21 00:12:33
@@ -15,7 +15,23 @@
 #include <assert.h>
 #ifdef HAS_ENDIAN_H
 #include <endian.h>
+#else
+// macOS doesn't have endian.h, provide fallback implementations
+#ifdef __APPLE__
+#include <libkern/OSByteOrder.h>
+#define le16toh(x) OSSwapLittleToHostInt16(x)
+#define le32toh(x) OSSwapLittleToHostInt32(x)
+#define le64toh(x) OSSwapLittleToHostInt64(x)
+#define htole16(x) OSSwapHostToLittleInt16(x)
+#define htole32(x) OSSwapHostToLittleInt32(x)
+#define htole64(x) OSSwapHostToLittleInt64(x)
+#else
+// Generic fallback for little-endian systems (assumes host is little-endian)
+#define le16toh(x) (x)
+#define le32toh(x) (x)
+#define le64toh(x) (x)
 #endif
+#endif
 #include <limits.h>
 #include <stdint.h>
 #include <string.h>
--- a/database-builder.cpp	2024-11-24 22:14:30
+++ b/database-builder.cpp	2025-11-21 00:12:33
@@ -7,7 +7,23 @@
 #include <assert.h>
 #ifdef HAS_ENDIAN_H
 #include <endian.h>
+#else
+// macOS doesn't have endian.h, provide fallback implementations
+#ifdef __APPLE__
+#include <libkern/OSByteOrder.h>
+#define le16toh(x) OSSwapLittleToHostInt16(x)
+#define le32toh(x) OSSwapLittleToHostInt32(x)
+#define le64toh(x) OSSwapLittleToHostInt64(x)
+#define htole16(x) OSSwapHostToLittleInt16(x)
+#define htole32(x) OSSwapHostToLittleInt32(x)
+#define htole64(x) OSSwapHostToLittleInt64(x)
+#else
+// Generic fallback for little-endian systems (assumes host is little-endian)
+#define le16toh(x) (x)
+#define le32toh(x) (x)
+#define le64toh(x) (x)
 #endif
+#endif
 #include <fcntl.h>
 #include <string.h>
 #include <string_view>
--- a/io_uring_engine.h	2024-11-24 22:14:30
+++ b/io_uring_engine.h	2025-11-21 00:12:33
@@ -7,16 +7,21 @@
 #include <string_view>
 #include <sys/socket.h>
 #include <sys/types.h>
+#ifndef WITHOUT_URING
 #include <linux/stat.h>
+#endif

 struct io_uring_sqe;
 #ifndef WITHOUT_URING
 #include <liburing.h>
+#elif defined(USE_LIBUV)
+#include "libuv_shim.h"
 #endif

 class IOUringEngine {
 public:
 	IOUringEngine(size_t slop_bytes);
+	~IOUringEngine();
 	void submit_read(int fd, size_t len, off_t offset, std::function<void(std::string_view)> cb);

 	// NOTE: We just do the stat() to get the data into the dentry cache for fast access,
@@ -25,7 +30,14 @@
 	bool get_supports_stat() { return supports_stat; }

 	void finish();
-	size_t get_waiting_reads() const { return pending_reads + queued_reads.size(); }
+	size_t get_waiting_reads() const {
+#ifdef USE_LIBUV
+		if (libuv_shim) {
+			return libuv_shim->get_waiting_reads();
+		}
+#endif
+		return pending_reads + queued_reads.size();
+	}

 private:
 #ifndef WITHOUT_URING
@@ -33,6 +45,8 @@
 	void submit_stat_internal(io_uring_sqe *sqe, char *path, std::function<void(bool)> cb);

 	io_uring ring;
+#elif defined(USE_LIBUV)
+	LibuvShim *libuv_shim = nullptr;
 #endif
 	size_t pending_reads = 0;  // Number of requests we have going in the ring.
 	bool using_uring, supports_stat = false;
--- a/io_uring_engine.cpp	2024-11-24 22:14:30
+++ b/io_uring_engine.cpp	2025-11-21 00:12:33
@@ -6,6 +6,8 @@
 #include <string.h>
 #ifndef WITHOUT_URING
 #include <liburing.h>
+#elif defined(USE_LIBUV)
+#include "libuv_shim.h"
 #endif
 #include "complete_pread.h"
 #include "dprintf.h"
@@ -24,17 +26,25 @@
 	: slop_bytes(slop_bytes)
 {
 #ifdef WITHOUT_URING
+#ifdef USE_LIBUV
+	// Use libuv shim for async I/O
+	libuv_shim = new LibuvShim(slop_bytes);
+	using_uring = true;
+	supports_stat = true;
+	dprintf("Using libuv for async I/O.\n");
+#else
 	int ret = -1;
 	dprintf("Compiled without liburing support; not using io_uring.\n");
+	using_uring = false;
+	supports_stat = false;
+#endif
 #else
 	int ret = io_uring_queue_init(queue_depth, &ring, 0);
 	if (ret < 0) {
 		dprintf("io_uring_queue_init() failed; not using io_uring.\n");
 	}
-#endif
 	using_uring = (ret >= 0);

-#ifndef WITHOUT_URING
 	if (using_uring) {
 		io_uring_probe *probe = io_uring_get_probe_ring(&ring);
 		supports_stat = (probe != nullptr && io_uring_opcode_supported(probe, IORING_OP_STATX));
@@ -50,6 +60,13 @@
 {
 	assert(supports_stat);

+#ifdef USE_LIBUV
+	if (libuv_shim) {
+		libuv_shim->submit_stat(path, move(cb));
+		return;
+	}
+#endif
+
 #ifndef WITHOUT_URING
 	if (pending_reads < queue_depth) {
 		io_uring_sqe *sqe = io_uring_get_sqe(&ring);
@@ -63,12 +80,28 @@
 		qs.cb = move(cb);
 		qs.pathname = strdup(path);
 		queued_stats.push(move(qs));
+	}
+#endif
+}
+
+IOUringEngine::~IOUringEngine()
+{
+#ifdef USE_LIBUV
+	if (libuv_shim) {
+		delete libuv_shim;
 	}
 #endif
 }

 void IOUringEngine::submit_read(int fd, size_t len, off_t offset, function<void(string_view)> cb)
 {
+#ifdef USE_LIBUV
+	if (libuv_shim) {
+		libuv_shim->submit_read(fd, len, offset, move(cb));
+		return;
+	}
+#endif
+
 	if (!using_uring) {
 		// Synchronous read.
 		string s;
@@ -131,6 +164,13 @@

 void IOUringEngine::finish()
 {
+#ifdef USE_LIBUV
+	if (libuv_shim) {
+		libuv_shim->finish();
+		return;
+	}
+#endif
+
 	if (!using_uring) {
 		return;
 	}
--- a/conf.cpp	2024-11-24 22:14:30
+++ b/conf.cpp	2025-11-21 00:12:33
@@ -35,6 +35,11 @@
 #include <string.h>
 #include <unistd.h>

+#ifdef __APPLE__
+// macOS doesn't have program_invocation_name (GNU extension), provide fallback
+char *program_invocation_name = nullptr;
+#endif
+
 using namespace std;

 /* true if locate(1) should check whether files are visible before reporting
--- a/updatedb.cpp	2024-11-24 22:14:30
+++ b/updatedb.cpp	2025-11-21 00:12:33
@@ -43,7 +43,22 @@
 #include <iosfwd>
 #include <math.h>
 #include <memory>
+#ifndef __APPLE__
 #include <mntent.h>
+#else
+// macOS doesn't have mntent.h - mount info is in /etc/fstab or via sysctl
+struct mntent {
+    char *mnt_fsname;
+    char *mnt_dir;
+    char *mnt_type;
+    char *mnt_opts;
+    int mnt_freq;
+    int mnt_passno;
+};
+FILE *setmntent(const char *filename, const char *type) { return NULL; }
+struct mntent *getmntent(FILE *filep) { return NULL; }
+int endmntent(FILE *filep) { return 0; }
+#endif
 #include <random>
 #include <stdint.h>
 #include <stdio.h>
@@ -197,8 +212,13 @@

 dir_time get_dirtime_from_stat(const struct stat &buf)
 {
+#ifdef __APPLE__
+	dir_time ctime{ buf.st_ctimespec.tv_sec, int32_t(buf.st_ctimespec.tv_nsec) };
+	dir_time mtime{ buf.st_mtimespec.tv_sec, int32_t(buf.st_mtimespec.tv_nsec) };
+#else
 	dir_time ctime{ buf.st_ctim.tv_sec, int32_t(buf.st_ctim.tv_nsec) };
 	dir_time mtime{ buf.st_mtim.tv_sec, int32_t(buf.st_mtim.tv_nsec) };
+#endif
 	dir_time dt = max(ctime, mtime);

 	if (time_is_current(dt)) {
--- a/plocate.cpp	2024-11-24 22:14:30
+++ b/plocate.cpp	2025-11-21 00:12:33
@@ -94,7 +94,11 @@
 			perror("lseek");
 			exit(1);
 		}
+#ifndef __APPLE__
 		posix_fadvise(fd, 0, len, POSIX_FADV_DONTNEED);
+#else
+		// macOS doesn't support posix_fadvise, skip it
+#endif
 	}

 	complete_pread(fd, &hdr, sizeof(hdr), /*offset=*/0);
--- a/meson.build	2024-11-24 22:14:30
+++ b/meson.build	2025-11-21 00:12:33
@@ -14,8 +14,13 @@
 threaddep = dependency('threads')
 atomicdep = cxx.find_library('atomic', required: false)

+# Check for libuv when io_uring is not available (for macOS support)
+uvdep = dependency('libuv', required: false)
 if not uringdep.found()
 	add_project_arguments('-DWITHOUT_URING', language: 'cpp')
+	if uvdep.found()
+		add_project_arguments('-DUSE_LIBUV', language: 'cpp')
+	endif
 endif
 if cxx.has_header('endian.h')
 	add_project_arguments('-DHAS_ENDIAN_H', language: 'cpp')
@@ -30,8 +35,18 @@
 	add_project_arguments('-DHAS_FUNCTION_MULTIVERSIONING', language: 'cpp')
 endif

-executable('plocate', ['plocate.cpp', 'io_uring_engine.cpp', 'turbopfor.cpp', 'parse_trigrams.cpp', 'serializer.cpp', 'access_rx_cache.cpp', 'needle.cpp', 'complete_pread.cpp'],
-	dependencies: [uringdep, zstddep, threaddep, atomicdep],
+plocate_sources = ['plocate.cpp', 'io_uring_engine.cpp', 'turbopfor.cpp', 'parse_trigrams.cpp', 'serializer.cpp', 'access_rx_cache.cpp', 'needle.cpp', 'complete_pread.cpp']
+plocate_deps = [zstddep, threaddep, atomicdep]
+
+if uringdep.found()
+	plocate_deps += [uringdep]
+elif uvdep.found()
+	plocate_sources += ['libuv_shim.cpp']
+	plocate_deps += [uvdep]
+endif
+
+executable('plocate', plocate_sources,
+	dependencies: plocate_deps,
 	install: true,
 	install_mode: ['rwxr-sr-x', 'root', get_option('locategroup')])
 executable('plocate-build', ['plocate-build.cpp', 'database-builder.cpp'],
