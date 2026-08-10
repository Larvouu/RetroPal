/*
 *  MelonDSPlatform.cpp
 *  EmulateurGBA
 *
 *  Platform callbacks required by melonDS core.
 *  Provides file I/O, threading, and stub implementations
 *  for features not needed on iOS (multiplayer, camera, etc.).
 */

#include <melonds/Platform.h>

#include <cstdio>
#include <cstdarg>
#include <cstring>
#include <ctime>
#include <string>
#include <functional>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <chrono>
#include <atomic>
#include <algorithm>
#include <sys/stat.h>
#include <unistd.h>
#include <dlfcn.h>

// Pre-recorded blow waveform from melonDS (local copy with melonDS types dependency removed)
#include "mic_blow.h"

// WFC spike (see WFC_SPIKE.md): real DS-game internet access through the
// melonDS slirp user-mode network stack, feeding the Nintendo WFC revival
// servers. OFF by default — enabling RETROPAL_WFC requires the extra static
// libs from Vendor/melonds-ios/build-wfc-net.sh, so current builds are
// byte-identical without it.
#if RETROPAL_WFC
#include <melonds/Net.h>
#include <melonds/Net_Slirp.h>
#endif

// ============================================================
// Microphone shared state — written by UI/audio threads, read by emulator thread
// ============================================================

namespace {
    static std::atomic<bool> g_micBlowActive{false};
    static int g_micBlowReadPos = 0;
    static constexpr int g_micBlowLength = sizeof(mic_blow) / sizeof(int16_t);
}

// C-linkage function called from MelonDSBridge (ObjC++)
extern "C" {

void MelonDSMic_SetBlowActive(bool active) {
    g_micBlowActive.store(active, std::memory_order_relaxed);
    if (!active) g_micBlowReadPos = 0;
}

} // extern "C"

namespace melonDS::Platform
{

// ============================================================
// Logging
// ============================================================

void Log(LogLevel level, const char* fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    vprintf(fmt, args);
    va_end(args);
}

// ============================================================
// File I/O
// ============================================================

struct FileHandle
{
    FILE* file;
    std::string path;
};

static const char* FileModeString(FileMode mode)
{
    bool read  = mode & FileMode::Read;
    bool write = mode & FileMode::Write;
    bool preserve = mode & FileMode::Preserve;
    bool noCreate = mode & FileMode::NoCreate;
    bool text = mode & FileMode::Text;
    bool append = mode & FileMode::Append;

    if (append) return text ? "a+t" : "a+b";
    if (read && write) {
        if (preserve) return text ? "r+t" : "r+b";
        return text ? "w+t" : "w+b";
    }
    if (write) return text ? "wt" : "wb";
    return text ? "rt" : "rb";
}

std::string GetLocalFilePath(const std::string& filename)
{
    // Not used in our integration — we manage paths from the ObjC++ bridge
    return filename;
}

FileHandle* OpenFile(const std::string& path, FileMode mode)
{
    if (mode & FileMode::NoCreate) {
        struct stat st;
        if (stat(path.c_str(), &st) != 0) return nullptr;
    }

    FILE* f = fopen(path.c_str(), FileModeString(mode));
    if (!f) return nullptr;

    auto* handle = new FileHandle();
    handle->file = f;
    handle->path = path;
    return handle;
}

FileHandle* OpenLocalFile(const std::string& path, FileMode mode)
{
    return OpenFile(path, mode);
}

bool FileExists(const std::string& name)
{
    struct stat st;
    return stat(name.c_str(), &st) == 0;
}

bool LocalFileExists(const std::string& name)
{
    return FileExists(name);
}

bool CheckFileWritable(const std::string& filepath)
{
    FILE* f = fopen(filepath.c_str(), "ab");
    if (!f) return false;
    fclose(f);
    return true;
}

bool CheckLocalFileWritable(const std::string& filepath)
{
    return CheckFileWritable(filepath);
}

bool CloseFile(FileHandle* file)
{
    if (!file) return false;
    int ret = fclose(file->file);
    delete file;
    return ret == 0;
}

bool IsEndOfFile(FileHandle* file)
{
    return file && feof(file->file);
}

bool FileReadLine(char* str, int count, FileHandle* file)
{
    if (!file) return false;
    return fgets(str, count, file->file) != nullptr;
}

u64 FilePosition(FileHandle* file)
{
    if (!file) return 0;
    return (u64)ftello(file->file);
}

bool FileSeek(FileHandle* file, s64 offset, FileSeekOrigin origin)
{
    if (!file) return false;
    int whence = SEEK_SET;
    if (origin == FileSeekOrigin::Current) whence = SEEK_CUR;
    else if (origin == FileSeekOrigin::End) whence = SEEK_END;
    return fseeko(file->file, (off_t)offset, whence) == 0;
}

void FileRewind(FileHandle* file)
{
    if (file) rewind(file->file);
}

u64 FileRead(void* data, u64 size, u64 count, FileHandle* file)
{
    if (!file) return 0;
    return fread(data, (size_t)size, (size_t)count, file->file);
}

bool FileFlush(FileHandle* file)
{
    if (!file) return false;
    return fflush(file->file) == 0;
}

u64 FileWrite(const void* data, u64 size, u64 count, FileHandle* file)
{
    if (!file) return 0;
    return fwrite(data, (size_t)size, (size_t)count, file->file);
}

u64 FileWriteFormatted(FileHandle* file, const char* fmt, ...)
{
    if (!file) return 0;
    va_list args;
    va_start(args, fmt);
    u64 ret = (u64)vfprintf(file->file, fmt, args);
    va_end(args);
    return ret;
}

u64 FileLength(FileHandle* file)
{
    if (!file) return 0;
    long pos = ftello(file->file);
    fseeko(file->file, 0, SEEK_END);
    long len = ftello(file->file);
    fseeko(file->file, pos, SEEK_SET);
    return (u64)len;
}

// ============================================================
// Emulation signals
// ============================================================

void SignalStop(StopReason reason, void* userdata)
{
    // Handled by checking NDS::IsRunning() in the bridge
}

// ============================================================
// Save callbacks
// ============================================================

// These are called by the core when save data changes.
// Our bridge handles persistence via explicit save/load, so these
// write directly to the save file path set during ROM load.

static std::string g_ndsSavePath;
static std::string g_gbaSavePath;

void WriteNDSSave(const u8* savedata, u32 savelen, u32 writeoffset, u32 writelen, void* userdata)
{
    if (g_ndsSavePath.empty()) return;
    FILE* f = fopen(g_ndsSavePath.c_str(), "r+b");
    if (!f) f = fopen(g_ndsSavePath.c_str(), "wb");
    if (!f) return;
    fseek(f, writeoffset, SEEK_SET);
    fwrite(savedata + writeoffset, 1, writelen, f);
    fclose(f);
}

void WriteGBASave(const u8* savedata, u32 savelen, u32 writeoffset, u32 writelen, void* userdata)
{
    if (g_gbaSavePath.empty()) return;
    FILE* f = fopen(g_gbaSavePath.c_str(), "r+b");
    if (!f) f = fopen(g_gbaSavePath.c_str(), "wb");
    if (!f) return;
    fseek(f, writeoffset, SEEK_SET);
    fwrite(savedata + writeoffset, 1, writelen, f);
    fclose(f);
}

void WriteFirmware(const Firmware& firmware, u32 writeoffset, u32 writelen, void* userdata)
{
    // No-op: we don't persist firmware changes
}

void WriteDateTime(int year, int month, int day, int hour, int minute, int second, void* userdata)
{
    // No-op: RTC changes don't need frontend persistence
}

// Public API for the bridge to set save paths
void SetNDSSavePath(const std::string& path) { g_ndsSavePath = path; }
void SetGBASavePath(const std::string& path) { g_gbaSavePath = path; }

// ============================================================
// Threading
// ============================================================

struct Thread
{
    std::thread thread;
};

Thread* Thread_Create(std::function<void()> func)
{
    auto* t = new Thread();
    t->thread = std::thread(func);
    return t;
}

void Thread_Free(Thread* thread)
{
    if (thread && thread->thread.joinable())
        thread->thread.detach();
    delete thread;
}

void Thread_Wait(Thread* thread)
{
    if (thread && thread->thread.joinable())
        thread->thread.join();
}

struct Semaphore
{
    std::mutex mutex;
    std::condition_variable cv;
    int count = 0;
};

Semaphore* Semaphore_Create()
{
    return new Semaphore();
}

void Semaphore_Free(Semaphore* sema)
{
    delete sema;
}

void Semaphore_Reset(Semaphore* sema)
{
    if (!sema) return;
    std::lock_guard<std::mutex> lock(sema->mutex);
    sema->count = 0;
}

void Semaphore_Wait(Semaphore* sema)
{
    if (!sema) return;
    std::unique_lock<std::mutex> lock(sema->mutex);
    sema->cv.wait(lock, [sema]{ return sema->count > 0; });
    sema->count--;
}

bool Semaphore_TryWait(Semaphore* sema, int timeout_ms)
{
    if (!sema) return false;
    std::unique_lock<std::mutex> lock(sema->mutex);
    if (timeout_ms == 0) {
        if (sema->count <= 0) return false;
    } else {
        if (!sema->cv.wait_for(lock, std::chrono::milliseconds(timeout_ms),
                               [sema]{ return sema->count > 0; }))
            return false;
    }
    sema->count--;
    return true;
}

void Semaphore_Post(Semaphore* sema, int count)
{
    if (!sema) return;
    {
        std::lock_guard<std::mutex> lock(sema->mutex);
        sema->count += count;
    }
    for (int i = 0; i < count; i++)
        sema->cv.notify_one();
}

struct Mutex
{
    std::mutex mutex;
};

Mutex* Mutex_Create()
{
    return new Mutex();
}

void Mutex_Free(Mutex* mutex)
{
    delete mutex;
}

void Mutex_Lock(Mutex* mutex)
{
    if (mutex) mutex->mutex.lock();
}

void Mutex_Unlock(Mutex* mutex)
{
    if (mutex) mutex->mutex.unlock();
}

bool Mutex_TryLock(Mutex* mutex)
{
    return mutex ? mutex->mutex.try_lock() : false;
}

void Sleep(u64 usecs)
{
    usleep((useconds_t)usecs);
}

u64 GetMSCount()
{
    auto now = std::chrono::steady_clock::now();
    return (u64)std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()).count();
}

u64 GetUSCount()
{
    auto now = std::chrono::steady_clock::now();
    return (u64)std::chrono::duration_cast<std::chrono::microseconds>(now.time_since_epoch()).count();
}

// ============================================================
// Multiplayer — stubs (not supported)
// ============================================================

void MP_Begin(void* userdata) {}
void MP_End(void* userdata) {}
int MP_SendPacket(u8* data, int len, u64 timestamp, void* userdata) { return 0; }
int MP_RecvPacket(u8* data, u64* timestamp, void* userdata) { return 0; }
int MP_SendCmd(u8* data, int len, u64 timestamp, void* userdata) { return 0; }
int MP_SendReply(u8* data, int len, u64 timestamp, u16 aid, void* userdata) { return 0; }
int MP_SendAck(u8* data, int len, u64 timestamp, void* userdata) { return 0; }
int MP_RecvHostPacket(u8* data, u64* timestamp, void* userdata) { return 0; }
u16 MP_RecvReplies(u8* data, u64 timestamp, u16 aidmask, void* userdata) { return 0; }

// ============================================================
// Network — WFC spike behind RETROPAL_WFC, stubs otherwise
// ============================================================

#if RETROPAL_WFC
// One process-wide Net + slirp driver, started lazily the first time the
// emulated wifi hardware actually emits a frame (games that never touch
// wifi never pay for it). Single emu instance on iOS -> instance id 0.
// Net::RecvPacket pumps the driver's RecvCheck itself, on the emu thread,
// so no extra polling thread is needed.
namespace {
    melonDS::Net g_net;
    std::atomic<bool> g_netStarted{false};
    std::mutex g_netStartLock;

    void EnsureNetStarted()
    {
        if (g_netStarted.load(std::memory_order_acquire)) return;
        std::lock_guard<std::mutex> lock(g_netStartLock);
        if (g_netStarted.load(std::memory_order_relaxed)) return;
        g_net.SetDriver(std::make_unique<melonDS::Net_Slirp>(
            [](const u8* data, int len) { g_net.RXEnqueue(data, len); }));
        g_net.RegisterInstance(0);
        g_netStarted.store(true, std::memory_order_release);
    }
}

int Net_SendPacket(u8* data, int len, void* userdata)
{
    EnsureNetStarted();
    g_net.SendPacket(data, len, 0);
    return 0;
}

int Net_RecvPacket(u8* data, void* userdata)
{
    if (!g_netStarted.load(std::memory_order_acquire)) return 0;
    return g_net.RecvPacket(data, 0);
}
#else
int Net_SendPacket(u8* data, int len, void* userdata) { return 0; }
int Net_RecvPacket(u8* data, void* userdata) { return 0; }
#endif

// ============================================================
// Camera — stubs
// ============================================================

void Camera_Start(int num, void* userdata) {}
void Camera_Stop(int num, void* userdata) {}
void Camera_CaptureFrame(int num, u32* frame, int width, int height, bool yuv, void* userdata) {}

// ============================================================
// Microphone — blow simulation + real device mic
// ============================================================

void Mic_Start(void* userdata) {}
void Mic_Stop(void* userdata) {}
int Mic_ReadInput(s16* data, int maxlength, void* userdata)
{
    if (g_micBlowActive.load(std::memory_order_relaxed)) {
        int readlength = 0;
        while (readlength < maxlength) {
            int thislen = std::min(maxlength - readlength, g_micBlowLength - g_micBlowReadPos);
            memcpy(data + readlength, &mic_blow[g_micBlowReadPos], thislen * sizeof(s16));
            g_micBlowReadPos = (g_micBlowReadPos + thislen) % g_micBlowLength;
            readlength += thislen;
        }
        return maxlength;
    }

    // Silence
    memset(data, 0, maxlength * sizeof(s16));
    return maxlength;
}

// ============================================================
// AAC decoder — stubs (DSi only)
// ============================================================

AACDecoder* AAC_Init() { return nullptr; }
void AAC_DeInit(AACDecoder* dec) {}
bool AAC_Configure(AACDecoder* dec, int frequency, int channels) { return false; }
bool AAC_DecodeFrame(AACDecoder* dec, const void* input, int inputlen, void* output, int outputlen) { return false; }

// ============================================================
// Addon inputs — stubs
// ============================================================

bool Addon_KeyDown(KeyType type, void* userdata) { return false; }
void Addon_RumbleStart(u32 len, void* userdata) {}
void Addon_RumbleStop(void* userdata) {}
float Addon_MotionQuery(MotionQueryType type, void* userdata) { return 0.0f; }

// ============================================================
// Dynamic libraries — stubs
// ============================================================

DynamicLibrary* DynamicLibrary_Load(const char* lib) { return nullptr; }
void DynamicLibrary_Unload(DynamicLibrary* lib) {}
void* DynamicLibrary_LoadFunction(DynamicLibrary* lib, const char* name) { return nullptr; }

} // namespace melonDS::Platform
