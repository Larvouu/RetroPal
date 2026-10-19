//
//  MesenBridge.mm
//  EmulateurGBA
//
//  ObjC++ implementation bridging MesenCE (SNES, NES, Master System, Game
//  Gear) to Swift.
//
//  HOW THIS CORE IS DRIVEN, AND WHY IT IS NOT DRIVEN THE WAY MESEN DRIVES ITSELF
//
//  Mesen's own frontends call Emulator::Run(), which owns a thread and a
//  FrameLimiter and blocks until the game stops. Our EmulatorSession already IS
//  the emulation loop: it runs one frame per display refresh and paces itself.
//  So this bridge steps the console directly:
//
//      console->RunFrame();
//
//  THAT REQUIRES ONE PATCH TO THE CORE, and the reason is worth knowing before
//  touching anything here. Stepping frames outside Run() is not something Mesen
//  supports: the consoles call Emulator::ProcessEndOfFrame() themselves at the
//  end of every frame, and it dereferences a FrameLimiter that only Run() ever
//  builds. So a stepped frontend null-dereferences on its first frame, on both
//  consoles. Mesen's own headless test runner drives the emulator through Run()
//  for exactly this reason.
//
//  The patch builds that limiter in the Emulator constructor instead of only in
//  Run(). It lives in Vendor/mesen-ios/patches/ and is applied by build.sh, so
//  the submodule stays pinned to upstream and the patch file is the whole of our
//  modification. `EmulationSpeed = 0` then keeps the limiter from ever waiting,
//  which leaves the pacing where it belongs, in our own loop.
//
//  Two workarounds were measured and rejected before choosing the patch: parking
//  Run() on a scratch thread does build the limiter, but the emulator is then
//  "paused" and SoundMixer drops every sample while it is; and letting Run() own
//  the loop would move the per-frame contract for rewind and RetroAchievements
//  onto a different clock for this core alone.
//
//  THE SECOND HALF OF DRIVING IT OURSELVES IS `LoadRom(..., stopRom: false)`.
//  A default LoadRom starts Mesen's own emulation thread, so the core would be
//  running the game while we stepped it too. See loadROMAtPath: for the detail.
//
//  Everything else reaches us through the same three interfaces Mesen's .NET and
//  SDL frontends implement, so apart from that one patch nothing here is a
//  private-API trick:
//    IRenderingDevice  frames arrive post-filter, post-overscan, as ARGB
//    IAudioDevice      samples are pushed during RunFrame, we ring-buffer them
//    IInputProvider    the console asks us for button state when it polls
//
//  TWO CONSEQUENCES OF NOT USING Run(), BOTH LOAD-BEARING
//
//  1. NEVER call Emulator::AcquireLock() / Lock() from here. That protocol works
//     by the Run loop reaching WaitForLock() and yielding; with no Run loop
//     nothing ever yields. The app's own contract already covers what the lock
//     is for: emulation is PAUSED before a save state is written or loaded, the
//     same contract MGBABridge and MelonDSBridge rely on.
//  2. Emulator::IsEmulationThread() is always false for us, because that id is
//     stamped inside Run(). Nothing on our paths depends on it; it guards
//     debugger hooks and one NES APU peek used only by the debugger.
//
//  AND TWO THINGS THE FRONTEND MUST PROVIDE THAT NOTHING WARNS ABOUT, both on
//  the NES, both silent, and both making the console look broken in a different
//  way.
//
//  The PALETTE: NesConfig::UserPalette is zero-filled by default and no code in
//  the core ever fills it, so a frontend that does not supply one gets a game
//  that runs perfectly, plays its music, and renders every single pixel black.
//
//  The CONTROLLER: the NES looks like it configures its own, and it only does so
//  for cartridges whose input type is declared, which means NES 2.0 headers and
//  the game database. A plain iNES 1.0 ROM the database does not know keeps
//  Port1.Type = None and answers no button ever pressed. See configureSettings.
//

// The core's sources live in a SUBMODULE, so a fresh clone or a pull that did
// not update submodules leaves Vendor/mesence empty and every include below
// fails with "file not found", which says nothing about the cause. Say it here
// instead, once, in the terms of the fix.
#if !__has_include("Shared/Emulator.h")
#error "MesenCE sources are missing. Run: git submodule update --init Vendor/mesence  (then Vendor/mesen-ios/build.sh)"
#endif

// ─── INCLUDE ORDER IS LOAD-BEARING. MESEN BEFORE FOUNDATION. ────────────────
//
// Apple's SDK declares a legacy Carbon function called `Debugger()`, reachable
// from Foundation and marked unavailable on iOS. Mesen has a `class Debugger`,
// which Emulator.h holds as `safe_ptr<Debugger>`. C++ lets a function name hide
// a class name, so if Foundation is parsed first, every one of Mesen's own
// mentions of the type stops compiling: "must use 'class' tag", "not available
// on iOS", "template argument must be a type".
//
// Parsing Mesen first costs nothing and fixes all of it: the class is then the
// meaning of the name inside Mesen's headers, and Apple's function simply hides
// it afterwards in code that never uses it. Mesen's pch declares only targeted
// `using std::…`, never `using namespace std`, so Foundation is unaffected.
//
// Do not sort these blocks alphabetically or move the bridge's own header up.

#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <pthread/qos.h>
#include <sstream>
#include <string>
#include <vector>

#include "Shared/Emulator.h"
#include "Shared/BatteryManager.h"
#include "Shared/EmuSettings.h"
#include "Shared/SettingTypes.h"
#include "Shared/BaseControlDevice.h"
#include "Shared/BaseControlManager.h"
#include "Shared/CheatManager.h"
#include "Shared/MemoryType.h"
#include "Shared/RenderedFrame.h"
#include "Shared/SaveStateManager.h"
#include "Shared/Audio/SoundMixer.h"
#include "Shared/Interfaces/IAudioDevice.h"
#include "Shared/Interfaces/IConsole.h"
#include "Shared/Interfaces/IInputProvider.h"
#include "Shared/Interfaces/IRenderingDevice.h"
#include "Shared/Video/VideoRenderer.h"
#include "SNES/Input/SnesController.h"
#include "NES/Input/NesController.h"
#include "SMS/Input/SmsController.h"
#include "Utilities/FolderUtilities.h"
#include "Utilities/VirtualFile.h"

// Foundation, UIKit and the bridge protocol come last, for the reason above.
#import "MesenBridge.h"

/// SNES blanks the top 7 and bottom 8 scanlines of its 239-line frame itself, so
/// without an overscan setting the game would sit between two black bars. Crop
/// them and show the 224 lines a television showed.
static const uint32_t kSnesOverscanTop = 7;
static const uint32_t kSnesOverscanBottom = 8;

/// The NES's own leftmost 8 pixels, cropped for the same kind of reason.
///
/// PPUMASK bit 1 turns the background off in the leftmost 8 pixels, and most
/// scrolling games clear it for the whole game: it is how the pixel column
/// entering from the left is kept from showing a partial tile. Those 8 columns
/// then draw the backdrop colour, every frame, which on a phone is a flat blank
/// band down the left edge of the picture — reported twice on device, in both
/// orientations, and identical in both because it is not our geometry at all. A
/// television never showed it (its own overscan cut more than 8 pixels a side).
///
/// So crop those 8 columns and let the picture start where the game's own
/// composition starts. The remaining 248x240 keeps square pixels, which is what
/// `displayAspect` returns, and the cost is 8 columns in the games that DO draw
/// there — a strip a real TV hid as well.
static const uint32_t kNesOverscanLeft = 8;

/// What the Master System and the Game Gear show of the 256x240 frame Mesen
/// draws them into. These are the values Mesen's own frontend ships
/// (`UI/Config/SmsConfig.cs`); the core's `SmsConfig` defaults to no crop at all,
/// and a frontend that leaves it there gets the Master System's 192 lines
/// between two 24-line black bands and the Game Gear's 160x144 screen as a small
/// window in the middle of a black 256x240 frame.
///
/// The Master System's 24 lines come off the top and bottom of every frame, so
/// the texture is the 192-line picture a television showed. The rare game that
/// switches the console's video chip to its 224- or 240-line mode loses those
/// extra lines, which is exactly what Mesen's frontend does too and what keeps
/// the texture one size for the session.
static const uint32_t kSmsOverscanTopBottom = 24;
/// The Game Gear's screen is the window of 160x144 inside the Master System's
/// picture that the handheld's LCD actually shows.
static const uint32_t kGgOverscan = 48;

/// The Master System's and the Game Gear's cartridge RAM as Mesen holds it
/// (`SmsMemoryManager::CartRamMaxSize`): the largest battery save they have.
static const uint32_t kSmsCartRamBytes = 0x8000;

const NSInteger SNESBufferWidth  = 512;
const NSInteger SNESBufferHeight = 448;
const NSInteger NESBufferWidth   = 256 - (NSInteger)kNesOverscanLeft;
const NSInteger NESBufferHeight  = 240;
const NSInteger SMSBufferWidth   = 256;
const NSInteger SMSBufferHeight  = 240 - 2 * (NSInteger)kSmsOverscanTopBottom;
const NSInteger GGBufferWidth    = 256 - 2 * (NSInteger)kGgOverscan;
const NSInteger GGBufferHeight   = 240 - 2 * (NSInteger)kGgOverscan;

/// The console a session is running. Mesen picks its console from the
/// extension on its own; the bridge needs to know it too, because the buffer,
/// the settings, the pad, the save's file name and the memory map differ.
/// `.sms` and `.gg` are one console to Mesen (`SmsConsole`), but not to the
/// screen, so they are two kinds here.
enum class MesenKind : uint8_t { Snes, Nes, Sms, Gg };

static const char* MesenKindName(MesenKind kind)
{
	switch(kind) {
		case MesenKind::Snes: return "SNES";
		case MesenKind::Nes: return "NES";
		case MesenKind::Sms: return "SMS";
		case MesenKind::Gg: return "GG";
	}
	return "?";
}

/// The NES palette, which the frontend owns.
///
/// These are the 64 colours of the 2C02 PPU as MesenCE itself tabulates them
/// (NesDefaultVideoFilter's own 2C02 row), copied here because the core exposes
/// no accessor for them and its NesConfig ships an empty palette. Mesen builds
/// the 448 emphasis variants from these itself, so only the base 64 are needed.
static const uint32_t kNesPalette2C02[64] = {
	0xFF666666, 0xFF002A88, 0xFF1412A7, 0xFF3B00A4, 0xFF5C007E, 0xFF6E0040, 0xFF6C0600, 0xFF561D00,
	0xFF333500, 0xFF0B4800, 0xFF005200, 0xFF004F08, 0xFF00404D, 0xFF000000, 0xFF000000, 0xFF000000,
	0xFFADADAD, 0xFF155FD9, 0xFF4240FF, 0xFF7527FE, 0xFFA01ACC, 0xFFB71E7B, 0xFFB53120, 0xFF994E00,
	0xFF6B6D00, 0xFF388700, 0xFF0C9300, 0xFF008F32, 0xFF007C8D, 0xFF000000, 0xFF000000, 0xFF000000,
	0xFFFFFEFF, 0xFF64B0FF, 0xFF9290FF, 0xFFC676FF, 0xFFF36AFF, 0xFFFE6ECC, 0xFFFE8170, 0xFFEA9E22,
	0xFFBCBE00, 0xFF88D800, 0xFF5CE430, 0xFF45E082, 0xFF48CDDE, 0xFF4F4F4F, 0xFF000000, 0xFF000000,
	0xFFFFFEFF, 0xFFC0DFFF, 0xFFD3D2FF, 0xFFE8C8FF, 0xFFFBC2FF, 0xFFFEC4EA, 0xFFFECCC5, 0xFFF7D8A5,
	0xFFE4E594, 0xFFCFEF96, 0xFFBDF4AB, 0xFFB3F3CC, 0xFFB5EBF2, 0xFFB8B8B8, 0xFF000000, 0xFF000000
};

/// Audio ring: 32,768 stereo frames, roughly 0.68 s at 48 kHz. Sized for the
/// worst case rather than the normal one, which is 3x fast-forward pushing about
/// 2,400 frames per drain.
/// How long RunFrame waits for its own frame to come back off the decode thread
/// before giving up and showing the previous one. A frame is 16.6 ms and the
/// decode costs well under one, so this is generous by design: it is a deadlock
/// guard, not a budget.
static const int kFrameWaitMs = 4;

static const size_t kAudioRingFrames = 32768;
static const uint32_t kAudioSampleRate = 48000;

/// Rewind, sized from what these consoles actually cost rather than from the DS
/// figures. A DS state is 19.0 MB, which is why MelonDSBridge stores deltas and
/// schedules its snapshots around the frame budget. An SNES state is two orders
/// smaller and an NES state smaller still, so whole states once a second are
/// affordable and the entire delta apparatus would be complexity bought for
/// nothing. Snapshot cost and the real state size are logged in DEBUG and are to
/// be confirmed on device.
///
/// One a SECOND, not one every 60 frames: a European cartridge runs at 50 (the
/// Master System at 49.70), and counted in its own frames a snapshot fell every
/// 1.2 seconds, so the 5 seconds the caller asks for (in sixtieths of a second,
/// `seconds * 60`, whatever the console) went back 6 and the 30 went back 36,
/// past what the ring holds. The Mega Drive and the PlayStation had the same
/// unit error, fixed 2026-10-08; see `framesPerSnapshot`.
static const NSInteger kRewindSecondsPerSnapshot = 1;
/// Hard ceiling on rewind memory. If a game's states are unexpectedly large (a
/// 128 KB-SRAM cart plus coprocessor RAM), DEPTH shrinks instead of the memory
/// growing. Depth is what the pause menu offers, so a shorter ring is visible to
/// the player rather than silent, which is the failure mode that matters.
static const size_t kRewindMemoryCap = 24 * 1024 * 1024;

#pragma mark - Frame sink (IRenderingDevice)

/// Receives finished frames from Mesen's video pipeline and keeps the most
/// recent one in a buffer of the session's FIXED size.
///
/// Frames arrive on Mesen's decode thread, not on the emulation thread, so the
/// buffer is double-buffered: a frame is assembled in the back buffer and only
/// then swapped in, so a reader never sees a half-written frame. It can still
/// see a swap happen mid-copy, which costs at most one frame of tearing and is
/// exactly what the other two bridges already allow by handing out the core's
/// live buffer. Mesen's own SoftwareRenderer is built the same way.
///
/// THAT THREAD IS ALSO WHY THIS CONSOLE FELT LAGGY, and the two answers are here.
///
/// mGBA and melonDS hand back the buffer the core has just finished writing, so
/// the frame on screen is the frame we stepped. Mesen does not: SnesPpu ends a
/// frame by calling VideoDecoder::UpdateFrame(frame, sync = false), which parks
/// it and signals a decode thread; the filter runs there and only then reaches
/// this sink. RunFrame therefore returns BEFORE its own frame exists, and the
/// draw that follows uploads the previous one. That is a full frame of latency
/// on a good day, and on a bad one it is however long iOS took to schedule a
/// plain std::thread against a main thread that is running emulation and Metal.
///
/// 1. `_qosRaised`: the first frame this sink receives is on that decode thread,
///    so it is the one place we can name its priority from. Mesen creates it as
///    a bare std::thread, which iOS gives an unspecified QoS, and it is on the
///    display path, so it is raised to user-interactive once.
/// 2. `WaitForFrameAfter`: the bridge waits, briefly and with a timeout, for the
///    frame its own RunFrame produced. The wait costs the decode thread's work
///    (well under a millisecond) and buys back the frame of latency. It also
///    guarantees the decoder is idle before the next RunFrame, which retires a
///    busy-spin inside VideoDecoder::UpdateFrame that would otherwise have the
///    main thread spinning on the very thread it is starving.
class MesenFrameSink : public IRenderingDevice
{
public:
	MesenFrameSink(uint32_t width, uint32_t height) : _width(width), _height(height)
	{
		_front = new uint32_t[width * height]();
		_back = new uint32_t[width * height]();
	}

	~MesenFrameSink() override
	{
		delete[] _front;
		delete[] _back;
	}

	void UpdateFrame(RenderedFrame& frame) override
	{
		//This runs on Mesen's decode thread. Name its priority from inside it,
		//once: it is on the display path and it arrives unspecified.
		if(!_qosRaised.exchange(true)) {
			pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
		}

		if(!frame.FrameBuffer || frame.Width == 0 || frame.Height == 0) {
			return;
		}

		uint32_t* src = (uint32_t*)frame.FrameBuffer;
		if(frame.Width == _width && frame.Height == _height) {
			//Exact match: an NES frame, or an SNES frame already in hi-res.
			memcpy(_back, src, (size_t)_width * _height * sizeof(uint32_t));
		} else if(frame.Width * 2 == _width && frame.Height * 2 == _height) {
			//The ordinary SNES frame, doubled into the hi-res-sized buffer.
			//Lossless, and it keeps the texture one size for the whole session.
			//
			//Written wide rather than pixel by pixel: one 64-bit store places a
			//pixel and its copy, and the doubled row is then memcpy'd to the row
			//below it. A quarter of the stores of the obvious loop, on a thread
			//the frame's latency now waits for.
			for(uint32_t y = 0; y < frame.Height; y++) {
				const uint32_t* in = src + (size_t)y * frame.Width;
				uint32_t* out0 = _back + (size_t)(y * 2) * _width;
				uint64_t* wide = (uint64_t*)out0;
				for(uint32_t x = 0; x < frame.Width; x++) {
					uint64_t px = in[x];
					wide[x] = px | (px << 32);
				}
				memcpy(out0 + _width, out0, (size_t)_width * sizeof(uint32_t));
			}
		} else {
			//Any other size: scale rather than tear or drop. Not expected on
			//either console, and cheap insurance against a mode we have not met.
			for(uint32_t y = 0; y < _height; y++) {
				uint32_t sy = y * frame.Height / _height;
				uint32_t* in = src + (size_t)sy * frame.Width;
				uint32_t* out = _back + (size_t)y * _width;
				for(uint32_t x = 0; x < _width; x++) {
					out[x] = in[x * frame.Width / _width];
				}
			}
		}

		{
			std::lock_guard<std::mutex> lock(_swapLock);
			std::swap(_front, _back);
			_frameCount++;
		}
		_frameReady.notify_all();
	}

	/// The latest complete frame. Stays valid for the sink's lifetime.
	const uint32_t* Frame()
	{
		std::lock_guard<std::mutex> lock(_swapLock);
		return _front;
	}

	/// How many frames have landed here. Read before RunFrame, waited on after.
	uint64_t FrameCount()
	{
		std::lock_guard<std::mutex> lock(_swapLock);
		return _frameCount;
	}

	/// Wait for a frame newer than `previous`, up to `timeoutMs`. Returns false on
	/// the timeout, which is not an error: the caller shows the frame it already
	/// has, exactly as it did before this wait existed. Bounded so a decode thread
	/// that never answers costs a few milliseconds rather than the session.
	bool WaitForFrameAfter(uint64_t previous, int timeoutMs)
	{
		std::unique_lock<std::mutex> lock(_swapLock);
		return _frameReady.wait_for(lock, std::chrono::milliseconds(timeoutMs),
		                            [&] { return _frameCount != previous; });
	}

	void ClearFrame() override
	{
		std::lock_guard<std::mutex> lock(_swapLock);
		memset(_front, 0, (size_t)_width * _height * sizeof(uint32_t));
	}

	//The HUD compositing pass and the window plumbing are the desktop
	//frontend's business; we draw the frame ourselves in Metal.
	void Render(RenderSurfaceInfo& emuHud, RenderSurfaceInfo& scriptHud) override {}
	void Reset() override { ClearFrame(); }
	void SetFullscreenMode(FullscreenSettings settings) override {}

private:
	uint32_t _width;
	uint32_t _height;
	uint32_t* _front;
	uint32_t* _back;
	std::mutex _swapLock;
	std::condition_variable _frameReady;
	uint64_t _frameCount = 0;
	std::atomic<bool> _qosRaised { false };
};

#pragma mark - Audio sink (IAudioDevice)

/// Mesen pushes samples during RunFrame; EmulatorAudioEngine pulls them right
/// after. This is the ring in between, in the interleaved stereo int16 layout
/// the engine already reads from the other two cores.
class MesenAudioSink : public IAudioDevice
{
public:
	MesenAudioSink() { _ring.resize(kAudioRingFrames * 2, 0); }

	void PlayBuffer(int16_t* soundBuffer, uint32_t sampleCount, uint32_t sampleRate, bool isStereo) override
	{
		std::lock_guard<std::mutex> lock(_lock);
		for(uint32_t i = 0; i < sampleCount; i++) {
			int16_t left = isStereo ? soundBuffer[i * 2] : soundBuffer[i];
			int16_t right = isStereo ? soundBuffer[i * 2 + 1] : soundBuffer[i];
			_ring[_write * 2] = left;
			_ring[_write * 2 + 1] = right;
			_write = (_write + 1) % kAudioRingFrames;
			if(_write == _read) {
				//Full: drop the oldest frame rather than the newest, so a stall
				//costs latency once instead of a permanent offset.
				_read = (_read + 1) % kAudioRingFrames;
			}
		}
	}

	size_t Read(int16_t* out, size_t maxFrames)
	{
		std::lock_guard<std::mutex> lock(_lock);
		size_t count = 0;
		while(count < maxFrames && _read != _write) {
			out[count * 2] = _ring[_read * 2];
			out[count * 2 + 1] = _ring[_read * 2 + 1];
			_read = (_read + 1) % kAudioRingFrames;
			count++;
		}
		return count;
	}

	void Stop() override { Clear(); }
	void Pause() override {}
	void ProcessEndOfFrame() override {}

	void Clear()
	{
		std::lock_guard<std::mutex> lock(_lock);
		_read = _write = 0;
	}

	string GetAvailableDevices() override { return ""; }
	void SetAudioDevice(string deviceName) override {}
	AudioStatistics GetStatistics() override { return {}; }

private:
	std::vector<int16_t> _ring;
	size_t _read = 0;
	size_t _write = 0;
	std::mutex _lock;
};

#pragma mark - Input source (IInputProvider)

/// Translates the app's 12-bit key mask into whichever pad the running console
/// asks about. Called by the console when it polls, on the emulation thread.
class MesenInputSource : public IInputProvider
{
public:
	/// Player 1's mask (port 1).
	std::atomic<uint32_t> Keys { 0 };
	/// Player 2's mask (port 2).
	std::atomic<uint32_t> Keys2 { 0 };
	std::atomic<MesenKind> Kind { MesenKind::Snes };

	bool SetInput(BaseControlDevice* device) override
	{
		if(device->GetPort() == 0) {
			ApplyKeys(device, Keys.load());
			return true;
		}
		//Port 2 answers only when it holds the console's own pad. A game that
		//declares something else there (Duck Hunt's Zapper, a Power Pad) keeps
		//its device, which reads its state from its own source.
		if(device->GetPort() == 1 && device->GetControllerType() == StandardPadType()) {
			ApplyKeys(device, Keys2.load());
			return true;
		}
		return false;
	}

	/// The console's ordinary controller, the one this app drives.
	ControllerType StandardPadType()
	{
		switch(Kind.load()) {
			case MesenKind::Nes: return ControllerType::NesController;
			case MesenKind::Sms:
			case MesenKind::Gg: return ControllerType::SmsController;
			default: return ControllerType::SnesController;
		}
	}

private:
	void ApplyKeys(BaseControlDevice* device, uint32_t keys)
	{
		const MesenKind kind = Kind.load();
		if(kind == MesenKind::Sms || kind == MesenKind::Gg) {
			//The pad's two buttons are printed 1 (left) and 2 (right), and Mesen
			//calls them B and A in that order (`SmsController.h` reads B as the
			//port's 0x10 bit, which is button 1). So the app's B, the left face
			//button on every page, is 1, and A, the right one, is 2: the same
			//places an NES pad's B and A take on the pages these two share.
			//
			//START is the console's own extra button: PAUSE on the Master
			//System (on the console, not the pad, and it raises an NMI) and
			//START on the Game Gear. Mesen reads both as its `Pause` bit and
			//routes it by model (`SmsVdp` raises the NMI on the Master System,
			//`ReadGameGearPort` answers port 0 on the Game Gear), so one bit
			//serves both. SELECT has no button on either and sends nothing.
			device->SetBitValue(SmsController::Buttons::B, keys & 0x002);
			device->SetBitValue(SmsController::Buttons::A, keys & 0x001);
			device->SetBitValue(SmsController::Buttons::Pause, keys & 0x008);
			device->SetBitValue(SmsController::Buttons::Right, keys & 0x010);
			device->SetBitValue(SmsController::Buttons::Left, keys & 0x020);
			device->SetBitValue(SmsController::Buttons::Up, keys & 0x040);
			device->SetBitValue(SmsController::Buttons::Down, keys & 0x080);
		} else if(kind == MesenKind::Nes) {
			device->SetBitValue(NesController::Buttons::A, keys & 0x001);
			device->SetBitValue(NesController::Buttons::B, keys & 0x002);
			device->SetBitValue(NesController::Buttons::Select, keys & 0x004);
			device->SetBitValue(NesController::Buttons::Start, keys & 0x008);
			device->SetBitValue(NesController::Buttons::Right, keys & 0x010);
			device->SetBitValue(NesController::Buttons::Left, keys & 0x020);
			device->SetBitValue(NesController::Buttons::Up, keys & 0x040);
			device->SetBitValue(NesController::Buttons::Down, keys & 0x080);
		} else {
			device->SetBitValue(SnesController::Buttons::A, keys & 0x001);
			device->SetBitValue(SnesController::Buttons::B, keys & 0x002);
			device->SetBitValue(SnesController::Buttons::Select, keys & 0x004);
			device->SetBitValue(SnesController::Buttons::Start, keys & 0x008);
			device->SetBitValue(SnesController::Buttons::Right, keys & 0x010);
			device->SetBitValue(SnesController::Buttons::Left, keys & 0x020);
			device->SetBitValue(SnesController::Buttons::Up, keys & 0x040);
			device->SetBitValue(SnesController::Buttons::Down, keys & 0x080);
			device->SetBitValue(SnesController::Buttons::R, keys & 0x100);
			device->SetBitValue(SnesController::Buttons::L, keys & 0x200);
			device->SetBitValue(SnesController::Buttons::X, keys & 0x400);
			device->SetBitValue(SnesController::Buttons::Y, keys & 0x800);
		}
	}
};

#pragma mark - Bridge

@implementation MesenBridge {
	std::unique_ptr<Emulator> _emu;
	std::unique_ptr<MesenFrameSink> _frameSink;
	std::unique_ptr<MesenAudioSink> _audioSink;
	std::unique_ptr<MesenInputSource> _input;

	/// How many players have a controller (`setConnectedPlayers:`), and whether
	/// port 2 must be re-planned before the next frame. Set from the UI thread,
	/// applied in `runFrame`, between frames, because Mesen's settings are the
	/// emulation thread's. It survives a game change: it describes the pads in
	/// the player's hands, not the cartridge.
	std::atomic<NSInteger> _connectedPlayers;
	std::atomic<bool> _portsDirty;
	/// Whether port 2's pad is one WE plugged in (see `applyPorts`), so taking
	/// it out again never removes a device the game itself asked for.
	BOOL _port2Plugged;

	BOOL _romLoaded;
	MesenKind _kind;
	uint32_t _bufferWidth;
	uint32_t _bufferHeight;
	int _speedMultiplier;

	/// Battery saves. Mesen names its own file (`<rom>.srm` on SNES, `<rom>.sav`
	/// on NES, Master System and Game Gear) inside a folder we choose, while the app's canonical name is
	/// `<rom>.sav` for every console. See the battery section for why that is
	/// reconciled with a shadow folder rather than by changing either side.
	std::string _canonicalSavePath;
	std::string _shadowFolder;
	std::string _romBasename;
	BOOL _batteryNeedsReload;
	/// Set when a save on disk could not be handed to the core AND could not be
	/// moved aside: writing would then replace it, so nothing is written this
	/// session. See `seedShadowFromCanonical`.
	BOOL _saveWritesBlocked;

	/// Rewind: whole states in a ring, one a second.
	std::vector<std::vector<uint8_t>> _rwStates;
	NSInteger _rwCapacity;      // snapshots the ring may hold
	NSInteger _rwStored;
	NSInteger _rwNewest;        // index of the most recent snapshot
	NSInteger _rwFrameCounter;
	/// A snapshot is due on the NEXT frame, regardless of the counter. Set at
	/// the start of a session and at every timeline jump, so the ring is never
	/// empty for a whole interval after one. See `rewindAppend`.
	BOOL _rwSnapshotDue;
	/// The sink's frame count as it was before the last RunFrame, so
	/// `awaitDisplayFrame` knows which picture it is waiting for.
	uint64_t _frameCountBeforeStep;
}

- (instancetype)init {
	self = [super init];
	if(self) {
		_romLoaded = NO;
		_kind = MesenKind::Snes;
		_connectedPlayers = 1;
		_portsDirty = false;
		_port2Plugged = NO;
		_bufferWidth = (uint32_t)SNESBufferWidth;
		_bufferHeight = (uint32_t)SNESBufferHeight;
		_speedMultiplier = 1;
		_batteryNeedsReload = NO;
		_saveWritesBlocked = NO;
		_rwCapacity = 0;
		_rwStored = 0;
		_rwNewest = -1;
		_rwFrameCounter = 0;
		_rwSnapshotDue = NO;
		_frameCountBeforeStep = 0;
	}
	return self;
}

- (void)dealloc {
	[self shutdown];
}

#pragma mark - Properties

- (BOOL)isROMLoaded { return _romLoaded; }
- (NSInteger)screenWidth { return _bufferWidth; }
- (NSInteger)screenHeight { return _bufferHeight; }
- (NSInteger)bufferStride { return _bufferWidth; }
- (NSInteger)totalBufferHeight { return _bufferHeight; }
/// Fixed for the session: the bridge presents SNES hi-res and doubles the
/// ordinary frames into it, so the buffer never changes size mid-game.
- (NSInteger)maxBufferHeight { return _bufferHeight; }
- (BOOL)hasTouchScreen { return NO; }

/// The console's OWN frame with square pixels: SNES 8:7 (256x224), NES 31:30
/// (248x240, the 240-line frame minus its 8 cropped columns), Master System
/// 4:3 (256x192) and Game Gear 10:9 (160x144).
///
/// Both consoles drew for a television that stretched them to 4:3, so there are
/// two defensible shapes: the television's, where a circle drawn by the artist
/// comes out round, and the framebuffer's, where the pixels are square and
/// nothing is resampled. Decided 2026-08-17 for the SNES against what the other
/// iPhone emulators show, and the NES follows it on 2026-08-18 rather than being
/// the one console answering the question differently.
///
/// The SNES buffer is presented double-height for hi-res mode, so 512x448 is
/// exactly 2x of 256x224 and its ratio is already the one returned here.
///
/// The Master System and the Game Gear follow the same rule. The Master System's
/// square-pixel frame happens to be 4:3 exactly; the Game Gear's LCD has square
/// pixels for real, which makes its 10:9 the handheld's own screen, the shape the
/// Game Boy's 160x144 has too.
- (CGFloat)displayAspect {
	switch(_kind) {
		case MesenKind::Nes: return (CGFloat)NESBufferWidth / (CGFloat)NESBufferHeight;
		case MesenKind::Sms: return (CGFloat)SMSBufferWidth / (CGFloat)SMSBufferHeight;
		case MesenKind::Gg: return (CGFloat)GGBufferWidth / (CGFloat)GGBufferHeight;
		default: return 8.0 / 7.0;
	}
}

/// Mesen writes 0xAARRGGBB, which on a little-endian device is B,G,R,A in
/// memory, the same order melonDS produces.
- (BOOL)usesBGRAPixelOrder { return YES; }

/// The rate the cartridge actually runs at, from the core, because on these
/// consoles it is not a constant: a European SNES, NES or Master System
/// cartridge runs at 50 and a North American one just over 60. (The Game Gear
/// runs at its one rate everywhere; Mesen answers that too.) Paced at the GBA's 59.7275 a PAL game
/// runs a fifth too fast and produces a fifth more audio per second than the
/// output can take. 60 is only the fallback before a game is loaded.
- (double)framesPerSecond {
	if(!_emu || !_romLoaded) return 60.0;
	IConsole *console = _emu->GetConsoleUnsafe();
	double fps = console ? console->GetFps() : 0.0;
	return fps > 1.0 ? fps : 60.0;
}

#pragma mark - ROM management

- (BOOL)loadROMAtPath:(NSString *)path {
	[self shutdown];

	NSString *ext = path.pathExtension.lowercaseString;
	if([ext isEqualToString:@"nes"]) {
		_kind = MesenKind::Nes;
		_bufferWidth = (uint32_t)NESBufferWidth;
		_bufferHeight = (uint32_t)NESBufferHeight;
	} else if([ext isEqualToString:@"sms"]) {
		_kind = MesenKind::Sms;
		_bufferWidth = (uint32_t)SMSBufferWidth;
		_bufferHeight = (uint32_t)SMSBufferHeight;
	} else if([ext isEqualToString:@"gg"]) {
		_kind = MesenKind::Gg;
		_bufferWidth = (uint32_t)GGBufferWidth;
		_bufferHeight = (uint32_t)GGBufferHeight;
	} else {
		_kind = MesenKind::Snes;
		_bufferWidth = (uint32_t)SNESBufferWidth;
		_bufferHeight = (uint32_t)SNESBufferHeight;
	}
	_romBasename = std::string(path.lastPathComponent.stringByDeletingPathExtension.UTF8String);

	_emu.reset(new Emulator());
	//No shortcut handler: it polls a KeyManager we deliberately never register,
	//because every shortcut this app has is its own UI.
	_emu->Initialize(false);

	[self configureSettings];
	[self configureFolders];

	_frameSink.reset(new MesenFrameSink(_bufferWidth, _bufferHeight));
	_audioSink.reset(new MesenAudioSink());
	_input.reset(new MesenInputSource());
	_input->Kind = _kind;
	_emu->GetVideoRenderer()->RegisterRenderingDevice(_frameSink.get());
	_emu->GetSoundMixer()->RegisterAudioDevice(_audioSink.get());

	//THE THIRD ARGUMENT IS THE WHOLE GAME. `stopRom:` defaults to true, and a
	//true LoadRom ends by starting Mesen's own emulation thread — the core runs
	//the game itself from that moment. Stepping frames as well would put two
	//threads inside one console, which is what black screens, silent audio and
	//non-reproducible crashes looked like from the outside. Passing false loads
	//the ROM and leaves it still, which is what a frontend that owns the loop
	//needs. (PowerCycle already passes false, so `reset` is safe.)
	//
	//Its other duty, stopping a previously running ROM, is not needed: this
	//bridge builds a fresh Emulator per game, so every load is a first load.
	if(!_emu->LoadRom((VirtualFile)std::string(path.UTF8String), VirtualFile(), false)) {
		NSLog(@"MesenBridge: failed to load %@", path.lastPathComponent);
		[self shutdown];
		return NO;
	}

	//The provider lives on the CONSOLE's control manager, which is a new object
	//after every load or power cycle, so this cannot be done once at startup.
	_emu->RegisterInputProvider(_input.get());
	_romLoaded = YES;
	//Port 2 is planned AFTER the load, because the load is where an NES game
	//from the database declares its own devices (see `applyPorts`). Applied
	//here directly, like the PlayStation's pad type: the first frame has to
	//find a second player's pad already plugged in, or the few games that look
	//for it at boot would not see it.
	_port2Plugged = NO;
	[self applyPorts];
	return YES;
}

/// Only the settings whose defaults are wrong for a phone are touched; the rest
/// of Mesen's defaults are its own and better left alone.
- (void)configureSettings {
	AudioConfig audio = _emu->GetSettings()->GetAudioConfig();
	audio.SampleRate = kAudioSampleRate;
	//Mesen's dynamic sample rate is a second sync loop: it stretches the
	//resampling ratio from the audio device's reported latency to hold a target
	//buffer depth. EmulatorAudioEngine already does that job for all four
	//existing consoles, and two control loops pulling on the same buffer is how
	//you get audible pitch wobble. Ours wins; this one is off.
	audio.DisableDynamicSampleRate = true;
	_emu->GetSettings()->SetAudioConfig(audio);

	PreferencesConfig prefs = _emu->GetSettings()->GetPreferences();
	//Stops Stop() from writing a recent-games file into our sandbox on teardown.
	prefs.DisableGameSelectionScreen = true;
	prefs.ShowFps = false;
	prefs.ShowDebugInfo = false;
	_emu->GetSettings()->SetPreferences(prefs);

	//Speed 0 means "unlimited" to Mesen, which makes its frame delay zero and its
	//limiter return immediately. That is exactly what we want: the limiter has to
	//EXIST (the consoles reach for it every frame) but it must never wait, because
	//the pacing is our loop's job. It also keeps run-ahead off, which Mesen only
	//considers between 1 and 100.
	EmulationConfig emulation = _emu->GetSettings()->GetEmulationConfig();
	emulation.EmulationSpeed = 0;
	_emu->GetSettings()->SetEmulationConfig(emulation);

	if(_kind == MesenKind::Nes) {
		NesConfig nes = _emu->GetSettings()->GetNesConfig();

		//Two arrays NesConfig ships EMPTY and expects the frontend to fill. Both
		//fail silently and independently, and each one alone makes the console
		//look broken in a different way.

		//Without the palette the game runs and draws every pixel black.
		memcpy(nes.UserPalette, kNesPalette2C02, sizeof(kNesPalette2C02));
		//false = let Mesen generate the 448 emphasis colours from these 64.
		nes.IsFullColorPalette = false;

		//Without the volumes the game runs, renders, and emits a full stream of
		//perfectly silent samples: NesSoundMixer scales each channel by
		//ChannelVolumes[i] / 100, and every entry defaults to zero. 100 is full
		//scale, and it is what the SNES equivalent already defaults to, which is
		//why only the NES was silent.
		for(size_t i = 0; i < sizeof(nes.ChannelVolumes) / sizeof(nes.ChannelVolumes[0]); i++) {
			nes.ChannelVolumes[i] = 100;
		}

		//The 8 columns the PPU can blank, cropped on both regions (a European
		//cartridge reads the PAL set). See kNesOverscanLeft.
		nes.NtscOverscan.Left = kNesOverscanLeft;
		nes.PalOverscan.Left = kNesOverscanLeft;

		//AND A CONTROLLER, because this console does NOT reliably configure its
		//own, whatever the note next to the SNES port used to claim.
		//
		//`NesConsole::LoadRom` calls `InitializeInputDevices` (the thing that
		//plugs a pad into port 1) behind this guard:
		//
		//    if(AutoConfigureInput && romData.Info.InputType != Unspecified)
		//
		//and `InputType` has exactly two sources. `NesHeader::GetInputType`
		//returns Unspecified for EVERY iNES 1.0 header, byte 15 being a NES 2.0
		//field; and `NES/GameDatabase.cpp` fills it in for cartridges it
		//recognises by CRC. So a ROM that is both plain-iNES and unknown to the
		//database leaves `Port1.Type` at its default of `None`, no device is
		//created for port 0, our input provider is never asked, and the game
		//runs perfectly while responding to nothing at all.
		//
		//That is every homebrew, every romhack, every re-dump that misses the
		//database, and it is why the console passed its device test: a
		//commercial cartridge IS in the database. Found 2026-08-19 on Dúshlán,
		//the NES ROM in the App Review kit, which reaches its menu and then
		//ignores the pad.
		//
		//Set BEFORE LoadRom on purpose: this is a floor, not a ceiling. A game
		//that genuinely declares a Zapper or a Power Pad still gets one, because
		//`InitializeInputDevices` runs later and overwrites this. Port 2 is left
		//empty here for the same reason as on the SNES; `applyPorts` fills it
		//when a second player has a controller.
		nes.Port1.Type = ControllerType::NesController;

		_emu->GetSettings()->SetNesConfig(nes);
	}

	if(_kind == MesenKind::Sms || _kind == MesenKind::Gg) {
		SmsConfig sms = _emu->GetSettings()->GetSmsConfig();

		//The NES's two empty arrays, again, on this console. `ChannelVolumes`
		//ships zero-filled for the four PSG channels (three tones and the
		//noise), and SmsPsg scales each by it, so a frontend that leaves it
		//alone gets a game that runs and draws and is entirely silent. 100 is
		//what Mesen's own frontend sets (`SmsConfig.cs`, Tone1Vol..NoiseVol).
		//The FM unit's volume already defaults to 100 in the core.
		for(size_t i = 0; i < sizeof(sms.ChannelVolumes) / sizeof(sms.ChannelVolumes[0]); i++) {
			sms.ChannelVolumes[i] = 100;
		}

		//The crop, which the core also ships empty. See kSmsOverscanTopBottom.
		sms.NtscOverscan.Top = kSmsOverscanTopBottom;
		sms.NtscOverscan.Bottom = kSmsOverscanTopBottom;
		sms.PalOverscan.Top = kSmsOverscanTopBottom;
		sms.PalOverscan.Bottom = kSmsOverscanTopBottom;
		sms.GameGearOverscan.Left = kGgOverscan;
		sms.GameGearOverscan.Right = kGgOverscan;
		sms.GameGearOverscan.Top = kGgOverscan;
		sms.GameGearOverscan.Bottom = kGgOverscan;

		//RAM powers on as ZEROES, not Mesen's default of random bytes. Random
		//RAM made a RetroAchievements progress counter read its maximum at
		//boot (Wonder Boy III's "find all 8 heart containers" showed 104/104
		//five seconds in, found on device 2026-10-09): achievement sets are
		//written against emulators whose RAM starts from a known state, and
		//so is a game's own first frame. It also makes a session reproducible.
		//Work RAM and the cartridge's RAM both read this (`InitializeRam`); a
		//battery save, when there is one, is loaded over it as before.
		sms.RamPowerOnState = RamState::AllZeros;

		//And the pad, for the same reason as on the SNES: every port defaults
		//to None and nothing in SmsConsole plugs one in, so without this line
		//the game runs and answers no button. Port 2 is `applyPorts`'s, and
		//only on the Master System (the Game Gear has one player).
		sms.Port1.Type = ControllerType::SmsController;

		//Region stays on Auto, which is Mesen's own default and reads it from
		//the file name: "(Europe)" or "(E)" makes a Master System game PAL (50
		//frames a second), everything else NTSC. The importer keeps a game's
		//original name, so a No-Intro European dump runs at its own speed.
		_emu->GetSettings()->SetSmsConfig(sms);
	}

	if(_kind == MesenKind::Snes) {
		SnesConfig snes = _emu->GetSettings()->GetSnesConfig();
		snes.Overscan.Top = kSnesOverscanTop;
		snes.Overscan.Bottom = kSnesOverscanBottom;

		//And the same trap on the input side. Every port on every console
		//defaults to ControllerType::None, so with no controller plugged in there
		//is no device for our input provider to answer about and the game receives
		//nothing at all. The SNES has no auto-configure path whatsoever; the NES
		//has one that only fires for cartridges whose input type is declared, which
		//is why it needs the same line (see the NES block above). Port 2 is left
		//empty on purpose: a second pad changes what some games do at boot, so
		//`applyPorts` plugs one only when a second player has a controller.
		snes.Port1.Type = ControllerType::SnesController;

		_emu->GetSettings()->SetSnesConfig(snes);
	}
}

/// Every folder Mesen writes to is pointed away from the app's own directories.
/// Battery saves go to the shadow folder (see the battery section); save states,
/// screenshots and firmware are ours to manage and Mesen must never create them.
- (void)configureFolders {
	NSString *appSupport = NSSearchPathForDirectoriesInDomains(
		NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
	NSString *root = [appSupport stringByAppendingPathComponent:@"Mesen"];
	NSString *battery = [root stringByAppendingPathComponent:@"Battery"];
	NSString *scratch = [root stringByAppendingPathComponent:@"Scratch"];
	NSFileManager *fm = NSFileManager.defaultManager;
	[fm createDirectoryAtPath:battery withIntermediateDirectories:YES attributes:nil error:nil];
	[fm createDirectoryAtPath:scratch withIntermediateDirectories:YES attributes:nil error:nil];

	_shadowFolder = std::string(battery.UTF8String);
	FolderUtilities::SetHomeFolder(std::string(root.UTF8String));
	FolderUtilities::SetFolderOverrides(_shadowFolder,
	                                    std::string(scratch.UTF8String),
	                                    std::string(scratch.UTF8String),
	                                    std::string(scratch.UTF8String));
}

- (void)reset {
	if(!_emu || !_romLoaded) return;
	[self invalidateRewind];
	//THE MASTER SYSTEM AND THE GAME GEAR HAVE NO SOFT RESET IN MESEN.
	//`SmsConsole::Reset()` reloads the ROM (`ReloadRom(true)`, "behave like
	//power cycle"), and `Emulator::Reset()` calls it from inside its own lock
	//and then goes on using the console it held before the reload, which the
	//reload has just replaced. So on this console a reset is a power cycle,
	//taken the bridge's way: through `PowerCycle()`, then the input provider
	//registered on the NEW console's control manager, as below.
	if(_batteryNeedsReload || _kind == MesenKind::Sms || _kind == MesenKind::Gg) {
		//The save path arrives AFTER loadROMAtPath: (EmulatorSession sets it
		//between the load and this reset, so an existing save is picked up).
		//Mesen reads the battery when the cartridge initialises, so a power
		//cycle is what makes a save that arrived late take effect. Later resets
		//are ordinary soft resets.
		//
		//And the console being replaced must not write ITS battery first.
		//`Emulator::InternalLoadRom` saves the outgoing console's battery before
		//reloading, and that console was loaded before the save path was known:
		//its cartridge RAM is whatever the shadow held then (the power-on fill
		//when there was none), not the save just seeded. Written over the
		//shadow `setSavePath` has just seeded, it is what the reload then read,
		//and the next flush copied it over the canonical save. The SNES and the
		//NES write unconditionally, so a save that arrived since the last
		//session (imported, or pulled from iCloud) was replaced at its first
		//launch (host, Super Mario World with an imported save: lost in 8 of 8
		//runs without this line, kept in 16 of 16 with it); the Master System
		//writes only RAM the game changed, which is why it was spared. An empty name is Mesen's
		//own "battery disabled" (`BatteryManager::SaveBattery`), and the reload
		//names the battery again before the new console reads it (`TryLoadRom`).
		_batteryNeedsReload = NO;
		_emu->GetBatteryManager()->Initialize("");
		_emu->PowerCycle();
		_emu->RegisterInputProvider(_input.get());
		//A power cycle reloads the cartridge, and with it an NES game's own
		//port declaration; plan port 2 again on top of it.
		_port2Plugged = NO;
		[self applyPorts];
	} else {
		_emu->Reset();
	}
	if(_audioSink) _audioSink->Clear();
}

#pragma mark - Battery saves
//
// The app stores one canonical battery file per game, `BatterySaves/<rom>.sav`,
// for every console. That single name is what the iCloud battery mirror
// reconciles, what the per-game export shares, and what the save importer
// writes, and BatterySaveImporter is the single source of truth for it.
//
// Mesen names its own file: `<rom>.srm` on SNES, `<rom>.sav` on NES, Master
// System and Game Gear, plus
// occasional companions (`.rtc` for the SPC7110 clock, `.bs` for BS-X, and
// `.chr.sav` for NES CHR RAM). The extension is hardcoded at each call site in
// the cartridge code, so it cannot be asked to use ours.
//
// Rather than teach the whole save-safety layer a per-console extension, or let
// Mesen's names into a folder the mirror scans, Mesen writes into a private
// shadow folder and the bridge copies the primary file in and out at exactly the
// moments the app already promises the save is on disk. The canonical `.sav`
// therefore keeps working unchanged for sync, export and import.
//
// Known limitation, stated rather than hidden: the companion files stay in the
// shadow folder. They persist across sessions and updates, but they are not
// mirrored to iCloud and not part of a save export. That affects a handful of
// coprocessor games and never the ordinary save.

- (void)setSavePath:(NSString *)path {
	_canonicalSavePath = std::string(path.UTF8String);
	[self seedShadowFromCanonical];
	_batteryNeedsReload = YES;
}

- (NSString *)shadowPrimaryPath {
	//`SmsMemoryManager` names its file `.sav` too (`LoadBattery(".sav", ...)`).
	NSString *name = [NSString stringWithFormat:@"%s%s", _romBasename.c_str(),
	                  _kind == MesenKind::Snes ? ".srm" : ".sav"];
	return [@(_shadowFolder.c_str()) stringByAppendingPathComponent:name];
}

/// The canonical file is what the sync engine has already reconciled, so it wins
/// whenever it exists. When it does not, an existing shadow file is kept: that
/// is a session that ended without a flush, and it holds the newer data.
- (void)seedShadowFromCanonical {
	if(_canonicalSavePath.empty() || _shadowFolder.empty()) return;
	NSFileManager *fm = NSFileManager.defaultManager;
	NSString *canonical = @(_canonicalSavePath.c_str());
	NSString *shadow = [self shadowPrimaryPath];
	if(![fm fileExistsAtPath:canonical]) return;
	//A Master System or Game Gear save LARGER than the cartridge's 32 KB of RAM
	//is never handed to Mesen. `SmsMemoryManager::SaveBattery` writes as many
	//bytes as the file on disk holds, from its 32 KB buffer: a 64 KB file there
	//is a heap overflow (host, AddressSanitizer, Waternet with a 64 KB .sav) and
	//garbage written into the save. Such a file is another console's save (the
	//importer takes 64 KB for the SNES and the Mega Drive) or another
	//emulator's layout, so it is moved aside, as the Mega Drive does
	//(BlastEmBridge, loadSaveRAM), and kept under a name the battery-save sync
	//does not read. If it cannot be moved, nothing is written this session, so
	//it is never overwritten.
	if(_kind == MesenKind::Sms || _kind == MesenKind::Gg) {
		NSNumber *size = [fm attributesOfItemAtPath:canonical error:nil][NSFileSize];
		if(size && size.unsignedLongLongValue > kSmsCartRamBytes) {
			[fm removeItemAtPath:shadow error:nil];
			NSString *aside = [NSString stringWithFormat:@"%@.unread-%lld", canonical,
			                   (long long)[NSDate date].timeIntervalSince1970];
			NSError *moveError = nil;
			if(![fm moveItemAtPath:canonical toPath:aside error:&moveError]) {
				_saveWritesBlocked = YES;
				NSLog(@"MesenBridge: save is %@ bytes, the cartridge has %u; could not move it aside (%@), save writes blocked",
				      size, kSmsCartRamBytes, moveError);
			} else {
				NSLog(@"MesenBridge: save is %@ bytes, the cartridge has %u; kept unread as %@",
				      size, kSmsCartRamBytes, aside.lastPathComponent);
			}
			return;
		}
	}
	[fm removeItemAtPath:shadow error:nil];
	NSError *error = nil;
	if(![fm copyItemAtPath:canonical toPath:shadow error:&error]) {
		NSLog(@"MesenBridge: could not seed battery save: %@", error);
	}
}

- (void)flushSaveData {
	if(!_emu || !_romLoaded) return;
	IConsole *console = _emu->GetConsoleUnsafe();
	if(!console) return;
	console->SaveBattery();
	[self copyShadowToCanonical];
}

- (void)copyShadowToCanonical {
	if(_canonicalSavePath.empty() || _saveWritesBlocked) return;
	NSFileManager *fm = NSFileManager.defaultManager;
	NSString *shadow = [self shadowPrimaryPath];
	if(![fm fileExistsAtPath:shadow]) return;   //game has no battery
	NSData *data = [NSData dataWithContentsOfFile:shadow];
	if(!data) return;
	if(![data writeToFile:@(_canonicalSavePath.c_str()) atomically:YES]) {
		NSLog(@"MesenBridge: could not write the battery save to its canonical path");
	}
}

#pragma mark - Emulation

- (void)runFrame {
	if(!_emu || !_romLoaded) return;
	IConsole *console = _emu->GetConsoleUnsafe();
	if(!console) return;
	//One call, and nothing after it: the console ends its own frame. Its
	//ProcessEndOfFrame runs the coprocessors and the SPC, polls input, and calls
	//Emulator::ProcessEndOfFrame, which is where the lag counter is maintained.
	//Doing any of that again here would double-count it.
	//
	//The frame this produces is NOT ready when RunFrame returns: the PPU parks it
	//on a decode thread. `awaitDisplayFrame` is where we wait for it, once per
	//DRAWN frame rather than once per emulated one, so fast-forward and catch-up
	//do not pay for pictures they discard.
	if(_portsDirty.exchange(false)) [self applyPorts];
	_frameCountBeforeStep = _frameSink ? _frameSink->FrameCount() : 0;
	console->RunFrame();
}

/// See EmulatorBridge.h. The wait is the decode thread's own work, which is why
/// the sink also raises that thread's priority; the timeout is the fail-soft and
/// taking it just means showing the frame we already had. See MesenFrameSink.
- (void)awaitDisplayFrame {
	if(!_frameSink) return;
	_frameSink->WaitForFrameAfter(_frameCountBeforeStep, kFrameWaitMs);
}

- (void)setKeys:(uint32_t)keys {
	if(_input) _input->Keys = keys;
}

#pragma mark - Players

/// Player 2's buttons. The console has two ports, so any other player is
/// ignored (the session never sends one: `PresetSystem.playerCount`).
- (void)setKeys:(uint32_t)keys player:(NSInteger)player {
	if(!_input) return;
	if(player == 0) {
		_input->Keys = keys;
	} else if(player == 1) {
		_input->Keys2 = keys;
	}
}

- (void)setConnectedPlayers:(NSInteger)count {
	if(_connectedPlayers.exchange(count) != count) _portsDirty = true;
}

/// Port 2 holds the console's pad exactly while a second player exists.
///
/// Only an EMPTY port is filled, and only a pad we plugged is taken out. An NES
/// cartridge the database knows arrives with its ports already declared: two
/// pads for most games (port 2 then stays as it is, as it always has), a Zapper
/// or a Power Pad for a few, and none of those is ours to replace. An SNES
/// port 2, and an unknown NES game's, start empty (see `configureSettings`),
/// which is where the second player's pad goes.
///
/// Both consoles rebuild their devices from these settings at the end of every
/// frame (`UpdateControlDevices`, which returns at once when nothing changed),
/// so a change made here takes effect on the next frame, mid-game included.
- (void)applyPorts {
	if(!_emu || !_romLoaded) return;
	//The Game Gear is a handheld with one player and no second port to fill.
	const bool wantsPort2 = _connectedPlayers.load() >= 2 && _kind != MesenKind::Gg;
	const ControllerType pad = _input ? _input->StandardPadType() : ControllerType::SnesController;
	if(_kind == MesenKind::Sms || _kind == MesenKind::Gg) {
		SmsConfig sms = _emu->GetSettings()->GetSmsConfig();
		if(wantsPort2 && sms.Port2.Type == ControllerType::None) {
			sms.Port2.Type = pad;
			_port2Plugged = YES;
		} else if(!wantsPort2 && _port2Plugged) {
			if(sms.Port2.Type == pad) sms.Port2.Type = ControllerType::None;
			_port2Plugged = NO;
		}
		_emu->GetSettings()->SetSmsConfig(sms);
	} else if(_kind == MesenKind::Nes) {
		NesConfig nes = _emu->GetSettings()->GetNesConfig();
		if(wantsPort2 && nes.Port2.Type == ControllerType::None) {
			nes.Port2.Type = pad;
			_port2Plugged = YES;
		} else if(!wantsPort2 && _port2Plugged) {
			if(nes.Port2.Type == pad) nes.Port2.Type = ControllerType::None;
			_port2Plugged = NO;
		}
		_emu->GetSettings()->SetNesConfig(nes);
	} else {
		SnesConfig snes = _emu->GetSettings()->GetSnesConfig();
		if(wantsPort2 && snes.Port2.Type == ControllerType::None) {
			snes.Port2.Type = pad;
			_port2Plugged = YES;
		} else if(!wantsPort2 && _port2Plugged) {
			if(snes.Port2.Type == pad) snes.Port2.Type = ControllerType::None;
			_port2Plugged = NO;
		}
		_emu->GetSettings()->SetSnesConfig(snes);
	}
	//A pad that leaves must not leave a button held on the port it left.
	if(!wantsPort2 && _input) _input->Keys2 = 0;
}

#pragma mark - Video

- (const uint32_t *)frameBuffer {
	if(!_frameSink) return NULL;
	return _frameSink->Frame();
}

- (CGImageRef)createFrameImage {
	if(!_romLoaded || !_frameSink) return NULL;
	CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
	CGContextRef context = CGBitmapContextCreate(
		(void *)_frameSink->Frame(), _bufferWidth, _bufferHeight, 8,
		_bufferWidth * sizeof(uint32_t), colorSpace,
		kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst);
	CGImageRef image = NULL;
	if(context) {
		image = CGBitmapContextCreateImage(context);
		CGContextRelease(context);
	}
	CGColorSpaceRelease(colorSpace);
	return image;
}

- (CGImageRef)createDualScreenFrameImage { return NULL; }

- (void)setGBPalette:(const uint32_t *)colors {}
- (BOOL)isDMGPaletteApplicable { return NO; }

#pragma mark - Audio

- (unsigned int)audioSampleRate { return kAudioSampleRate; }

- (NSInteger)readAudioSamples:(int16_t *)buffer count:(NSInteger)count {
	if(!_audioSink || count <= 0) return 0;
	return (NSInteger)_audioSink->Read(buffer, (size_t)count);
}

/// Fixed for the life of a session: we set the rate ourselves and Mesen resamples
/// every console to it.
- (unsigned int)consumePendingAudioRate { return 0; }

#pragma mark - Speed

/// Recorded, but deliberately NOT passed to the core.
///
/// Mesen's speed setting drives its frame limiter, and this bridge keeps that
/// limiter at "unlimited" on purpose (see `configureSettings`): the number of
/// frames run per display refresh is our loop's decision, exactly as it is for
/// the other two cores. Handing Mesen a speed as well would put a second pacer
/// on the same frames. Fast-forward audio is handled where it already is, by the
/// session skipping the drain, and the ring drops its oldest frames rather than
/// growing.
- (void)setSpeedMultiplier:(int)multiplier {
	_speedMultiplier = MAX(1, multiplier);
}

#pragma mark - Save states

- (BOOL)saveStateToPath:(NSString *)path {
	if(!_emu || !_romLoaded) return NO;
	std::ostringstream out(std::ios::binary);
	_emu->GetSaveStateManager()->SaveState(out);
	std::string bytes = out.str();
	if(bytes.empty()) return NO;
	NSData *data = [NSData dataWithBytes:bytes.data() length:bytes.size()];
	return [data writeToFile:path atomically:YES];
}

- (BOOL)loadStateFromPath:(NSString *)path {
	if(!_emu || !_romLoaded) return NO;
	//A loaded state is a different timeline, so every snapshot we hold describes
	//a past that no longer leads here. Invalidating in the BRIDGE rather than at
	//the call sites is deliberate: the DS shipped this bug because the session's
	//frame counter looked like it covered the case, and it does not. It gates
	//how far back you may ask, not which timeline the answer comes from.
	[self invalidateRewind];

	NSData *data = [NSData dataWithContentsOfFile:path];
	if(!data || data.length == 0) return NO;
	std::string bytes((const char *)data.bytes, data.length);
	std::istringstream in(bytes, std::ios::binary);
	return _emu->GetSaveStateManager()->LoadState(in) ? YES : NO;
}

#pragma mark - Rewind

- (void)initRewind:(NSInteger)seconds {
	[self teardownRewind];
	if(seconds <= 0) return;
	//Buffers are allocated on the first snapshot, which is now the first frame
	//(see `_rwSnapshotDue`). That is affordable here and is not on the DS: a
	//state on these consoles is 0.16 MB against 19.0, and the ring is a vector
	//of empty vectors until each slot is first written.
	_rwCapacity = seconds;
	_rwFrameCounter = 0;
	//Take the first one straight away rather than a second into the session:
	//until it lands there is nothing to rewind TO, and a rewind with an empty
	//ring is refused without anything on screen saying so.
	_rwSnapshotDue = YES;
}

- (void)teardownRewind {
	_rwStates.clear();
	_rwStates.shrink_to_fit();
	_rwCapacity = 0;
	_rwStored = 0;
	_rwNewest = -1;
	_rwFrameCounter = 0;
	_rwSnapshotDue = NO;
}

/// Drop every snapshot, keep the ring's size. Used on both timeline jumps.
- (void)invalidateRewind {
	for(auto& state : _rwStates) {
		state.clear();
	}
	_rwStored = 0;
	_rwNewest = -1;
	_rwFrameCounter = 0;
	//The jump we just took IS a rewind target: the state at the load or the
	//reset point. Taking it now restarts the cadence from here and keeps the
	//interval after a jump from being a hole the player can fall into.
	_rwSnapshotDue = YES;
}

/// The console's own frames in one snapshot's second: 60 for an NTSC
/// cartridge, 50 for a PAL one.
- (NSInteger)framesPerSnapshot {
	return MAX((NSInteger)1, (NSInteger)llround(self.framesPerSecond * kRewindSecondsPerSnapshot));
}

- (void)rewindAppend {
	if(_rwCapacity <= 0 || !_emu || !_romLoaded) return;
	if(!_rwSnapshotDue && ++_rwFrameCounter < [self framesPerSnapshot]) return;
	_rwSnapshotDue = NO;
	_rwFrameCounter = 0;

	std::ostringstream out(std::ios::binary);
	_emu->GetSaveStateManager()->SaveState(out);
	std::string bytes = out.str();
	if(bytes.empty()) return;

	if(_rwStates.empty()) {
		//First snapshot: its size decides how deep the ring can be within the
		//memory ceiling. Depth shrinking is visible to the player through what
		//the rewind button offers, which is why it is preferred to more memory.
		NSInteger affordable = (NSInteger)(kRewindMemoryCap / MAX(bytes.size(), (size_t)1));
		NSInteger depth = MIN(_rwCapacity, MAX((NSInteger)1, affordable));
#if DEBUG
		NSLog(@"[REWIND] %s state %.2f MB, depth %ld of %ld requested",
		      MesenKindName(_kind), bytes.size() / 1048576.0, (long)depth, (long)_rwCapacity);
#endif
		_rwCapacity = depth;
		_rwStates.resize((size_t)depth);
	}

	_rwNewest = (_rwNewest + 1) % _rwCapacity;
	_rwStates[(size_t)_rwNewest].assign(bytes.begin(), bytes.end());
	_rwStored = MIN(_rwStored + 1, _rwCapacity);
}

- (BOOL)rewindFrames:(NSInteger)count {
	if(!_emu || !_romLoaded || _rwStored <= 0) return NO;

	//The caller counts SIXTIETHS of a second (EmulatorViewController asks
	//`seconds * 60` whatever the cartridge's rate), and we hold one snapshot a
	//second of play, so a second is 60 here on every console, PAL included.
	//The app's depths are whole seconds, so this is exact on every value the
	//UI can actually ask for.
	const NSInteger perSnapshot = kRewindSecondsPerSnapshot * 60;
	NSInteger back = MAX((NSInteger)1, count / perSnapshot);
	if(back > _rwStored) back = _rwStored;

	NSInteger index = _rwNewest - (back - 1);
	while(index < 0) index += _rwCapacity;
	std::vector<uint8_t>& state = _rwStates[(size_t)index];
	if(state.empty()) return NO;

	std::string bytes((const char *)state.data(), state.size());
	std::istringstream in(bytes, std::ios::binary);
	if(!_emu->GetSaveStateManager()->LoadState(in)) return NO;

	//Consume: the snapshots we rewound past describe a timeline the player just
	//left, exactly as after a state load. The one we landed on stays, so a
	//second rewind continues from here.
	_rwStored -= (back - 1);
	_rwNewest = index;
	_rwFrameCounter = 0;
	if(_audioSink) _audioSink->Clear();
	return YES;
}

#pragma mark - Memory (RetroAchievements)
//
// rcheevos hands us a REAL bus address, translated from its flat map by
// RAClient. Mesen exposes each memory region as a raw pointer, so the decode is
// a small table per console.
//
// SNES: rcheevos maps System RAM at 0x7E0000 and places cartridge RAM and the
// SA-1's I-RAM OUTSIDE the console's own address space, at 0x1000000 and
// 0x1080000, because cartridge RAM sits in a different place on every board.
// NES: internal RAM at 0x0000-0x07FF and cartridge save RAM at 0x6000-0x7FFF;
// the mirrors are virtual in rcheevos' map and never reach us.
//
// Master System and Game Gear: one map for both. System RAM (8 KB) at 0xC000,
// and the cartridge's RAM placed OUTSIDE the console's 64 KB, at 0x10000, as
// one 32 KB block: rcheevos' own comment says the mappers bank it in pieces, so
// its "real address" is a virtual one. Mesen registers the same 32 KB block
// (`SmsMemoryManager::CartRamMaxSize`), so the offsets line up one for one.
//
// Stated rather than hidden: rcheevos' NES map also describes the cartridge ROM
// at 0x8000 as readable, and this serves nothing there. Reading it would mean
// resolving the mapper's current bank for every address, and achievement logic is
// built on RAM. If a set is ever found to depend on it, that is the fix, and the
// symptom would be one game's achievements never triggering rather than anything
// silently wrong.

- (NSInteger)readMemoryAtAddress:(uint32_t)address into:(uint8_t *)buffer length:(NSInteger)length {
	if(!_emu || !_romLoaded || length <= 0) return 0;

	MemoryType type;
	uint32_t offset;
	if(_kind == MesenKind::Sms || _kind == MesenKind::Gg) {
		if(address >= 0xC000 && address < 0xE000) {
			type = MemoryType::SmsWorkRam;
			offset = address - 0xC000;
		} else if(address >= 0x10000 && address < 0x18000) {
			type = MemoryType::SmsCartRam;
			offset = address - 0x10000;
		} else {
			return 0;
		}
	} else if(_kind == MesenKind::Nes) {
		if(address < 0x0800) {
			type = MemoryType::NesInternalRam;
			offset = address;
		} else if(address >= 0x6000 && address < 0x8000) {
			type = MemoryType::NesSaveRam;
			offset = address - 0x6000;
		} else {
			return 0;
		}
	} else {
		if(address >= 0x7E0000 && address < 0x800000) {
			type = MemoryType::SnesWorkRam;
			offset = address - 0x7E0000;
		} else if(address >= 0x1000000 && address < 0x1080000) {
			type = MemoryType::SnesSaveRam;
			offset = address - 0x1000000;
		} else if(address >= 0x1080000 && address < 0x1080800) {
			//The SA-1's own 2 KB of I-RAM, which rcheevos also places outside the
			//console's address space. Worth serving rather than skipping: the SA-1
			//carts are Super Mario RPG, Kirby Super Star and Kirby's Dream Land 3,
			//all of which carry achievement sets.
			type = MemoryType::Sa1InternalRam;
			offset = address - 0x1080000;
		} else {
			return 0;
		}
	}

	ConsoleMemoryInfo info = _emu->GetMemory(type);
	if(!info.Memory || offset >= info.Size) return 0;
	uint32_t available = info.Size - offset;
	uint32_t toRead = (uint32_t)MIN((NSInteger)available, length);
	memcpy(buffer, (uint8_t *)info.Memory + offset, toRead);
	return (NSInteger)toRead;
}

#pragma mark - Cheats
//
// Mesen's cheat model is one code per entry, and unlike mGBA it carries no
// state that spans lines: a Game Genie code is self-contained and a Pro Action
// Replay code is an address and a value. So a multi-line paste is simply
// several codes, and the entry the app saves stays one entry.
//
// The 2026-08-11 doctrine still applies and is easier to honour here, because
// Mesen can convert a code WITHOUT installing it. Every line is validated first
// and nothing is installed unless all of them convert. A type that cannot read
// every line is the wrong type; the caller then tries the next one, and a code
// no type reads in full fails visibly instead of leaving a fragment installed.

- (BOOL)addCheatCode:(NSString *)code type:(int)type {
	if(!_emu || !_romLoaded) return NO;

	CheatType cheatType;
	const bool isSms = (_kind == MesenKind::Sms || _kind == MesenKind::Gg);
	if(isSms) {
		//The Master System's and the Game Gear's two formats, which Mesen shares
		//between them: Game Genie (`XXX-XXX` or `XXX-XXX-XXX`) and Pro Action
		//Replay (eight hex digits, an address and a value).
		switch(type) {
			case 0: cheatType = CheatType::SmsGameGenie; break;
			case 1: cheatType = CheatType::SmsProActionReplay; break;
			default: return NO;
		}
	} else if(_kind == MesenKind::Nes) {
		switch(type) {
			case 0: cheatType = CheatType::NesGameGenie; break;
			case 1: cheatType = CheatType::NesProActionRocky; break;
			case 2: cheatType = CheatType::NesCustom; break;
			default: return NO;
		}
	} else {
		switch(type) {
			case 0: cheatType = CheatType::SnesGameGenie; break;
			case 1: cheatType = CheatType::SnesProActionReplay; break;
			default: return NO;
		}
	}

	NSArray<NSString *> *lines = [code componentsSeparatedByCharactersInSet:
	                              NSCharacterSet.newlineCharacterSet];
	std::vector<CheatCode> parsed;
	for(NSString *line in lines) {
		NSString *trimmed = [line stringByTrimmingCharactersInSet:
		                     NSCharacterSet.whitespaceCharacterSet];
		if(trimmed.length == 0) continue;
		if(isSms && cheatType == CheatType::SmsProActionReplay) {
			trimmed = [MesenBridge sega8BitProActionReplayDigits:trimmed];
		}
		//Mesen's code field is 16 bytes including its terminator; nothing this
		//long is a valid code on either console.
		if(trimmed.length > 15) return NO;

		CheatCode entry = {};
		entry.Type = cheatType;
		strncpy(entry.Code, trimmed.UTF8String, sizeof(entry.Code) - 1);

		InternalCheatCode converted;
		if(!_emu->GetCheatManager()->GetConvertedCheat(entry, converted)) {
			return NO;   //one unreadable line rejects the whole code
		}
		parsed.push_back(entry);
	}
	if(parsed.empty()) return NO;

	for(CheatCode& entry : parsed) {
		if(!_emu->GetCheatManager()->AddCheat(entry)) {
			return NO;
		}
	}
	return YES;
}

- (void)clearCheats {
	if(_emu) _emu->GetCheatManager()->ClearCheats(false);
}

/// A Pro Action Replay code is printed in the books and on the cheat sites as
/// `00C0:0F01` or `00C0 0F01`, and libretro's cheat files (the app's cheat
/// browser) print it `00C0-0F01`; Mesen's validator takes the eight digits
/// alone. Those separators carry nothing (the code is fixed-width), so they are
/// dropped for this format and these two consoles only. The dash was not, until
/// 2026-10-10, and refused 3,286 of the Master System's browser codes and 3,054
/// of the Game Gear's (host, Mesen's own converter: one of each left refused,
/// both malformed in the file).
///
/// The Game Genie's dashes are part of ITS format and are never touched: the
/// session tries the Game Genie first (type 0), and this runs only for the
/// Pro Action Replay (type 1), which takes exactly eight hex digits, so a
/// Game Genie code (six or nine) stripped of its dashes still cannot pass as one.
+ (NSString *)sega8BitProActionReplayDigits:(NSString *)code {
	NSString *digits = code;
	for(NSString *separator in @[@":", @" ", @"-"]) {
		digits = [digits stringByReplacingOccurrencesOfString:separator withString:@""];
	}
	return digits;
}

#pragma mark - Touch screen (not applicable)

- (void)touchScreenAtX:(int)x y:(int)y {}
- (void)touchScreenRelease {}

#pragma mark - Lifecycle

- (void)shutdown {
	[self teardownRewind];
	if(_emu) {
		if(_romLoaded) {
			//Stop() saves the battery on its way out; mirror it to the canonical
			//path before the core goes away.
			IConsole *console = _emu->GetConsoleUnsafe();
			if(console) console->SaveBattery();
			[self copyShadowToCanonical];
		}
		_emu->Release();
		_emu.reset();
	}
	_frameSink.reset();
	_audioSink.reset();
	_input.reset();
	_romLoaded = NO;
	_batteryNeedsReload = NO;
	_saveWritesBlocked = NO;
	_canonicalSavePath.clear();
	_romBasename.clear();
}

@end
