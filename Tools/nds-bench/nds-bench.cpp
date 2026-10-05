// Host harness for the melonDS core as Retro Pal builds it: the same core
// sources, the same Platform layer as the app (MelonDSPlatform.cpp, compiled
// here unchanged), the same NDSArgs (no JIT, software renderer, FreeBIOS,
// direct boot). It exists so that a change to the DS core, a build flag or a
// patch is PROVEN on this machine before it reaches a phone:
//
//   hash       run N frames from a state and print one line per frame with a
//              hash of both screens and of the audio the frame produced. Two
//              builds whose hash files are identical produced the same picture
//              and the same sound on every frame: that is the zero-regression
//              gate for any change meant to be invisible (speed, threading).
//   bench      the same run, timed. Host timings, so only the RATIO between two
//              builds means anything; the phone's pause-menu line is the number.
//   roundtrip  load a state, run, save, run M frames (A), load the saved state
//              back, run M frames again (B): A and B must be identical from the
//              second frame on (see the mode's comment, and use --video-only).
//              Proves a state written by THIS build restores exactly.
//   save       load a state, run N frames, write a new state file. Used to make
//              fixtures with the shipping core, and to cross-load between builds.
//   info       print a state file's melonDS header (version, length).
//   migrate    the sequences MelonDSStateMigrationTests runs on the phone: a
//              state played on N frames, against the same state saved again by
//              this build, reloaded and played on N frames (same picture?); and
//              a refused newer-format load against a real one (untouched?).
//   oldload    load a state the way the 1.3.2 bridge did (DoSavestate's return
//              value only, never the file's Error), then run N frames. Says
//              what an older Retro Pal does when handed a state it cannot read.
//
// Usage: nds-bench <mode> <rom.nds> <state|-> [options]
//   --frames N       frames to run (default 3600, one minute)
//   --threaded       enable melonDS's 3D render thread
//   --snapshot-every N  hash: serialize a state every N frames and throw it away,
//                    as the rewind does; the hashes must not change because of it
//   --out FILE       hash: write the per-frame lines there instead of stdout
//   --save-to FILE   save: where the new state goes
//   --video-only     hash the two screens only, not the sound
//
// Paths are arguments on purpose: the games used to measure are the owner's
// own and never enter the repository.

#include <melonds/NDS.h>
#include <melonds/NDSCart.h>
#include <melonds/GPU.h>
#include <melonds/GPU3D_Soft.h>
#include <melonds/SPU.h>
#include <melonds/Savestate.h>
#include <melonds/Args.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

using namespace melonDS;

namespace {

struct Options {
    std::string mode, rom, state, out, saveTo;
    int frames = 3600;
    int snapshotEvery = 0;
    bool threaded = false;
};

[[noreturn]] void die(const char* msg) {
    fprintf(stderr, "nds-bench: %s\n", msg);
    exit(2);
}

std::vector<u8> readFile(const std::string& path) {
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) die(("cannot open " + path).c_str());
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    std::vector<u8> data((size_t)n);
    if (n > 0 && fread(data.data(), 1, (size_t)n, f) != (size_t)n) die("short read");
    fclose(f);
    return data;
}

void writeFile(const std::string& path, const u8* data, size_t n) {
    FILE* f = fopen(path.c_str(), "wb");
    if (!f) die(("cannot write " + path).c_str());
    fwrite(data, 1, n, f);
    fclose(f);
}

// FNV-1a, 64 bit. Not cryptographic, and does not need to be: it only has to
// make two different frames collide with negligible probability.
u64 fnv(const void* p, size_t n, u64 h = 0xcbf29ce484222325ull) {
    const u8* b = (const u8*)p;
    for (size_t i = 0; i < n; i++) { h ^= b[i]; h *= 0x100000001b3ull; }
    return h;
}

// Boot exactly as MelonDSBridge does: parse, insert, reset, direct boot, start.
std::unique_ptr<NDS> boot(const Options& o) {
    NDSArgs args {};
    args.JIT = std::nullopt;
    auto nds = std::make_unique<NDS>(std::move(args));
    auto rom = readFile(o.rom);
    auto cart = NDSCart::ParseROM(rom.data(), (u32)rom.size());
    if (!cart) die("ROM does not parse");
    nds->SetNDSCart(std::move(cart));
    // Threaded before the reset, in the bridge's order (loadROMAtPath: then reset).
    if (o.threaded) {
        auto& r = static_cast<SoftRenderer&>(nds->GPU.GetRenderer3D());
        r.SetThreaded(true, nds->GPU);
    }
    nds->Reset();
    if (nds->NeedsDirectBoot()) nds->SetupDirectBoot("bench");
    nds->Start();
    return nds;
}

bool loadState(NDS& nds, std::vector<u8> data) {
    Savestate st(data.data(), (u32)data.size(), false);
    if (st.Error) return false;
    bool ok = nds.DoSavestate(&st);
    return ok && !st.Error;
}

std::vector<u8> saveState(NDS& nds) {
    Savestate st;
    if (!nds.DoSavestate(&st)) die("DoSavestate failed");
    st.Finish();
    if (st.Error) die("savestate error");
    return std::vector<u8>((const u8*)st.Buffer(), (const u8*)st.Buffer() + st.Length());
}

// What the hashes cover. Video alone is the right gate across a state load:
// melonDS does not save its audio resampler or its output buffer, so the sound
// after a load starts from a fresh resampler and differs by design.
bool gHashAudio = true;

// One emulated frame, as the bridge runs it, plus the audio it produced.
u64 frameHash(NDS& nds) {
    nds.RunFrame();
    int fb = nds.GPU.FrontBuffer;
    u64 h = fnv(nds.GPU.Framebuffer[fb][0].get(), 256 * 192 * 4);
    h = fnv(nds.GPU.Framebuffer[fb][1].get(), 256 * 192 * 4, h);
    s16 audio[2 * 4096];
    int n;
    while ((n = nds.SPU.ReadOutput(audio, 4096)) > 0) {
        if (gHashAudio) h = fnv(audio, (size_t)n * 4, h);
    }
    return h;
}

std::vector<u8> saveState(NDS& nds);

std::vector<u64> runHashes(NDS& nds, int frames, int snapshotEvery = 0) {
    std::vector<u64> out;
    out.reserve((size_t)frames);
    for (int i = 0; i < frames; i++) {
        out.push_back(frameHash(nds));
        if (snapshotEvery > 0 && (i + 1) % snapshotEvery == 0) saveState(nds);
    }
    return out;
}

void shutdown(std::unique_ptr<NDS>& nds) {
    // Join the render thread while the GPU is whole (see MelonDSBridge).
    auto& r = static_cast<SoftRenderer&>(nds->GPU.GetRenderer3D());
    r.SetThreaded(false, nds->GPU);
    nds.reset();
}

void startFrom(NDS& nds, const Options& o) {
    nds.RunFrame();   // one frame first, as SaveStateCompatibilityTests does
    if (o.state != "-" && !loadState(nds, readFile(o.state))) die("state refused");
}

int stateInfo(const std::string& path) {
    auto d = readFile(path);
    if (d.size() < 16 || memcmp(d.data(), "MELN", 4) != 0) { printf("not a melonDS state\n"); return 1; }
    u16 major, minor; u32 len;
    memcpy(&major, &d[4], 2); memcpy(&minor, &d[6], 2); memcpy(&len, &d[8], 4);
    printf("version %u.%u, header length %u, file %zu bytes\n", major, minor, len, d.size());
    return 0;
}

} // namespace

int main(int argc, char** argv) {
    Options o;
    if (argc >= 2) o.mode = argv[1];
    if (o.mode == "info" && argc == 3) return stateInfo(argv[2]);
    if (argc < 4) {
        fprintf(stderr, "usage: nds-bench hash|bench|roundtrip|save <rom> <state|-> [--frames N] [--threaded] [--out F] [--save-to F]\n"
                        "       nds-bench info <state>\n");
        return 2;
    }
    o.rom = argv[2];
    o.state = argv[3];
    for (int i = 4; i < argc; i++) {
        std::string a = argv[i];
        if (a == "--frames" && i + 1 < argc) o.frames = atoi(argv[++i]);
        else if (a == "--threaded") o.threaded = true;
        else if (a == "--video-only") gHashAudio = false;
        else if (a == "--snapshot-every" && i + 1 < argc) o.snapshotEvery = atoi(argv[++i]);
        else if (a == "--out" && i + 1 < argc) o.out = argv[++i];
        else if (a == "--save-to" && i + 1 < argc) o.saveTo = argv[++i];
        else die(("unknown option " + a).c_str());
    }

    auto nds = boot(o);

    if (o.mode == "oldload") {
        nds->RunFrame();
        auto data = readFile(o.state);
        Savestate st(data.data(), (u32)data.size(), false);
        bool reported = nds->DoSavestate(&st);   // exactly what 1.3.2 checked
        printf("header refused: %s; DoSavestate returned %s, so 1.3.2 reports the load as %s\n",
               st.Error ? "yes" : "no", reported ? "true" : "false", reported ? "SUCCESS" : "FAILED");
        auto hs = runHashes(*nds, o.frames);
        printf("ran %d frames after it without crashing\n", o.frames);
        shutdown(nds);
        return 0;
    }

    startFrom(*nds, o);

    if (o.mode == "migrate") {
        auto picture = [&]() {
            int fb = nds->GPU.FrontBuffer;
            u64 h = fnv(nds->GPU.Framebuffer[fb][0].get(), 256 * 192 * 4);
            return fnv(nds->GPU.Framebuffer[fb][1].get(), 256 * 192 * 4, h);
        };
        auto run = [&](int n) { for (int i = 0; i < n; i++) nds->RunFrame(); };
        auto original = readFile(o.state);
        run(o.frames);
        u64 fromOriginal = picture();
        if (!loadState(*nds, original)) die("reload refused");
        auto resaved = saveState(*nds);
        if (!loadState(*nds, resaved)) die("resaved state refused");
        run(o.frames);
        printf("migrate: state played on %d frames %s the same moment saved again and reloaded\n",
               o.frames, fromOriginal == picture() ? "==" : "!=");
        // Refusal: load the original, play on, save S, fail to load a copy of
        // S marked with a newer minor version, play on (A); load S, play on
        // the same span (B). A == B means the refused load changed nothing.
        if (!loadState(*nds, original)) die("reload refused");
        run(o.frames);
        auto snap = saveState(*nds);
        auto future = snap;
        future[6] = 2; future[7] = 0;
        if (loadState(*nds, future)) die("a newer-format state was accepted");
        run(o.frames);
        u64 afterRefusal = picture();
        if (!loadState(*nds, snap)) die("own state refused");
        run(o.frames);
        printf("migrate: refused newer state, game %s\n", afterRefusal == picture() ? "untouched" : "CHANGED");
        shutdown(nds);
        return 0;
    }

    if (o.mode == "hash") {
        auto hs = runHashes(*nds, o.frames, o.snapshotEvery);
        FILE* f = o.out.empty() ? stdout : fopen(o.out.c_str(), "w");
        if (!f) die("cannot write --out");
        u64 all = 0xcbf29ce484222325ull;
        for (size_t i = 0; i < hs.size(); i++) {
            fprintf(f, "%zu %016llx\n", i, (unsigned long long)hs[i]);
            all = fnv(&hs[i], sizeof hs[i], all);
        }
        if (f != stdout) fclose(f);
        printf("frames %d  sequence %016llx\n", o.frames, (unsigned long long)all);
    } else if (o.mode == "bench") {
        s16 audio[2 * 4096];
        long samples = 0;
        int n;
        for (int i = 0; i < 60; i++) {   // settle, and leave no sound queued
            nds->RunFrame();
            while (nds->SPU.ReadOutput(audio, 4096) > 0) {}
        }
        auto t0 = std::chrono::steady_clock::now();
        for (int i = 0; i < o.frames; i++) {
            nds->RunFrame();
            while ((n = nds->SPU.ReadOutput(audio, 4096)) > 0) samples += n;
        }
        double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        printf("frames %d  %.3f ms/frame  (%s)  %.2f audio samples/frame\n", o.frames, ms / o.frames,
               o.threaded ? "threaded 3D" : "inline 3D", (double)samples / o.frames);
        // What a rewind snapshot costs: serialise into a buffer allocated once,
        // as MelonDSBridge's rewind does.
        std::vector<u8> snap(24 * 1024 * 1024);
        auto s0 = std::chrono::steady_clock::now();
        u32 len = 0;
        for (int i = 0; i < 20; i++) {
            Savestate st(snap.data(), (u32)snap.size(), true);
            nds->DoSavestate(&st);
            st.Finish();
            len = st.Length();
        }
        double sms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - s0).count() / 20;
        printf("snapshot %.2f MB in %.2f ms\n", len / 1048576.0, sms);
    } else if (o.mode == "roundtrip") {
        for (int i = 0; i < 120; i++) nds->RunFrame();
        auto saved = saveState(*nds);
        auto a = runHashes(*nds, o.frames);
        if (!loadState(*nds, saved)) die("own state refused");
        auto b = runHashes(*nds, o.frames);
        // Frame 0 is left out: the first frame after ANY load shows the 3D
        // picture the renderer held before the load (inline) or one redrawn
        // from the loaded polygons (threaded), in the pinned core as shipped.
        // Run with --video-only: the sound after a load comes from a fresh
        // resampler (melonDS does not save it), so it differs by design.
        size_t diff = 0;
        for (size_t i = 1; i < a.size(); i++) if (a[i] != b[i]) {
            if (diff < 8) printf("frame %zu differs\n", i);
            diff++;
        }
        u16 minor; memcpy(&minor, &saved[6], 2);
        printf("state %zu bytes, version minor %u, frames 1-%d after reload: %s\n",
               saved.size(), minor, o.frames - 1, diff == 0 ? "IDENTICAL" : "DIFFERENT");
        shutdown(nds);
        return diff == 0 ? 0 : 1;
    } else if (o.mode == "save") {
        if (o.saveTo.empty()) die("save needs --save-to");
        for (int i = 0; i < o.frames; i++) nds->RunFrame();
        auto s = saveState(*nds);
        writeFile(o.saveTo, s.data(), s.size());
        printf("wrote %zu bytes to %s\n", s.size(), o.saveTo.c_str());
    } else {
        die("unknown mode");
    }
    shutdown(nds);
    return 0;
}
