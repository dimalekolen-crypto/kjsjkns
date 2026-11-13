// =========================================================================================
// FlopDLC.mm — v136.3 (Key System UI Fixed & Mobile Adjusted)
// =========================================================================================
// Сборка: clang++ -arch arm64 -miphoneos-version-min=15.0 -isysroot $(xcrun --sdk iphoneos --show-sdk-path) -std=c++17 -fobjc-arc -O2 -fvisibility=hidden -dynamiclib -install_name @rpath/FlopDLC.dylib -Wl,-undefined,dynamic_lookup -framework Foundation -framework UIKit -framework CoreGraphics -framework CoreFoundation -framework QuartzCore -framework AVFoundation FlopDLC.mm -o FlopDLC.dylib
// =========================================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>

#include <dlfcn.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <execinfo.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <atomic>
#include <cmath>
#include <vector>
#include <unordered_map>
#include <string>
#include <algorithm>
#include <mach/mach_time.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach/task_info.h>
#include <mach/vm_param.h>
#include <mach-o/dyld.h>
#include <dispatch/dispatch.h>
#include <CoreFoundation/CoreFoundation.h>

static constexpr const char* kEspVersion = "136.3";

#define SANE_PTR(p) ((uintptr_t)(p) > 0x100000000 && (uintptr_t)(p) < 0x00007FFFFFFFFFFF)

struct __attribute__((aligned(4))) Vec3 {
    float x;
    float y;
    float z;
    
    Vec3() : x(0), y(0), z(0) {}
    
    Vec3(float x, float y, float z) : x(x), y(y), z(z) {}
    
    Vec3 operator+(const Vec3& v) const {
        return Vec3(x + v.x, y + v.y, z + v.z);
    }
    
    Vec3 operator-(const Vec3& v) const {
        return Vec3(x - v.x, y - v.y, z - v.z);
    }
    
    Vec3 operator*(float s) const {
        return Vec3(x * s, y * s, z * s);
    }
    
    float Length() const {
        return std::sqrt(x * x + y * y + z * z);
    }
};

struct __attribute__((aligned(4))) Vec2 {
    float x;
    float y;
    
    Vec2() : x(0), y(0) {}
    
    Vec2(float x, float y) : x(x), y(y) {}
};

struct __attribute__((aligned(4))) Quat {
    float x;
    float y;
    float z;
    float w;
    
    Quat() : x(0), y(0), z(0), w(1) {}
};

struct __attribute__((aligned(4))) UnityColor {
    float r;
    float g;
    float b;
    float a;
    
    UnityColor() : r(0), g(0), b(0), a(1) {}
    
    UnityColor(float r, float g, float b, float a) : r(r), g(g), b(b), a(a) {}
};

namespace Math {
    static constexpr float DEG2RAD = 3.14159265358979323846f / 180.0f;
    
    inline float Clamp(float v, float lo, float hi) {
        if (v < lo) {
            return lo;
        }
        if (v > hi) {
            return hi;
        }
        return v;
    }
    
    inline bool Finite(float v) {
        return std::isfinite(v);
    }
    
    inline bool Finite(const Vec3& v) {
        bool fx = std::isfinite(v.x);
        bool fy = std::isfinite(v.y);
        bool fz = std::isfinite(v.z);
        return fx && fy && fz;
    }
}

static NSString* gLogDocPath = nil;
static NSLock* gLogLock = nil;

static void LOG(NSString* format, ...) {
    @try {
        va_list args;
        va_start(args, format);
        NSString* s = [[NSString alloc] initWithFormat:format arguments:args];
        va_end(args);
        
        if (!s) {
            return;
        }
        
        NSLog(@"[FlopDLC] %@", s);
        
        if (!gLogLock) {
            return;
        }
        if (!gLogDocPath) {
            return;
        }
        
        [gLogLock lock];
        
        NSFileHandle* fh = [NSFileHandle fileHandleForWritingAtPath:gLogDocPath];
        if (fh) {
            @try {
                [fh seekToEndOfFile];
                NSString* line = [s stringByAppendingString:@"\n"];
                NSData* data = [line dataUsingEncoding:NSUTF8StringEncoding];
                [fh writeData:data];
                [fh closeFile];
            } @catch (NSException* e) {
                [fh closeFile];
            }
        }
        
        [gLogLock unlock];
    } @catch (NSException* e) {
    }
}

// Any non-finite float that reaches a %f/%d format string is rendered by UIKit as the
// literal text "nan" or "inf". A single bad value (weapon data, velocity, config) then
// paints "nan" over the HUD/ESP. Clamp at the source and scrub the formatted result.
static inline float ClampFinite(float v, float lo, float hi, float fallback) {
    if (!std::isfinite(v)) {
        return fallback;
    }
    return Math::Clamp(v, lo, hi);
}

static NSString* SafeFmt(NSString* fmt, ...) {
    @try {
        va_list args;
        va_start(args, fmt);
        NSString* s = [[NSString alloc] initWithFormat:fmt arguments:args];
        va_end(args);
        
        if (s) {
            // Only scrub numeric formats so a nickname like "Nan" is never touched.
            if (fmt && ([fmt rangeOfString:@"%f"].location != NSNotFound ||
                        [fmt rangeOfString:@"%."].location != NSNotFound ||
                        [fmt rangeOfString:@"%d"].location != NSNotFound ||
                        [fmt rangeOfString:@"%l"].location != NSNotFound)) {
                NSString* low = [s lowercaseString];
                if ([low rangeOfString:@"nan"].location != NSNotFound ||
                    [low rangeOfString:@"inf"].location != NSNotFound) {
                    return @"0";
                }
            }
            return s;
        }
        return @"";
    } @catch (NSException* e) {
        return @"";
    }
}

static NSString* SafeStr(NSString* s) {
    if (s) {
        return s;
    }
    return @"";
}

static int gCrashFd = -1;

static void CrashSignalHandler(int sig, siginfo_t* info, void* ctx) {
    char buf[256];
    void* addr = NULL;
    if (info) {
        addr = info->si_addr;
    }
    
    int n = snprintf(buf, sizeof(buf), "\n=== CRASH signal=%d addr=%p ===\n", sig, addr);
    
    if (n > 0) {
        if (gCrashFd >= 0) {
            write(gCrashFd, buf, n);
        }
    }
    
    void* frames[64];
    int fc = backtrace(frames, 64);
    
    if (gCrashFd >= 0) {
        backtrace_symbols_fd(frames, fc, gCrashFd);
    }
    
    signal(sig, SIG_DFL);
    raise(sig);
}

static void InstallCrashHandler(void) {
    @try {
        NSArray* paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString* docs = nil;
        if (paths.count > 0) {
            docs = paths.firstObject;
        }
        
        if (!docs) {
            return;
        }
        
        gLogDocPath = [docs stringByAppendingPathComponent:@"flop_log.txt"];
        
        NSFileManager* fm = [NSFileManager defaultManager];
        [fm removeItemAtPath:gLogDocPath error:nil];
        
        [@"" writeToFile:gLogDocPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        
        gLogLock = [NSLock new];
        
        NSString* crashPath = [docs stringByAppendingPathComponent:@"flop_crash.txt"];
        gCrashFd = open([crashPath UTF8String], O_WRONLY | O_CREAT | O_APPEND, 0644);
        
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_sigaction = CrashSignalHandler;
        sa.sa_flags = SA_SIGINFO;
        sigemptyset(&sa.sa_mask);
        
        sigaction(SIGSEGV, &sa, NULL);
        sigaction(SIGBUS, &sa, NULL);
        sigaction(SIGABRT, &sa, NULL);
    } @catch (NSException* e) {
    }
}

static inline uint64_t MachTicksToNanoseconds(uint64_t ticks) {
    static mach_timebase_info_data_t timebase = [] {
        mach_timebase_info_data_t value{};
        if (mach_timebase_info(&value) != KERN_SUCCESS || value.denom == 0) {
            value.numer = 1;
            value.denom = 1;
        }
        return value;
    }();

    uint64_t whole = ticks / timebase.denom;
    uint64_t remainder = ticks % timebase.denom;
    return whole * timebase.numer + remainder * timebase.numer / timebase.denom;
}

static inline uint64_t NowMs(void) {
    return MachTicksToNanoseconds(mach_absolute_time()) / 1000000ULL;
}

// AUDIO
static AVAudioPlayer* gKillPlayer = nil;
static AVAudioPlayer* gHitPlayer = nil;

static AVAudioPlayer* MakeTonePlayer(float freq, float dur, float amp) {
    @try {
        NSMutableData* wav = [NSMutableData data];
        int rate = 44100;
        int n = (int)(rate * dur);
        
        [wav appendBytes:"RIFF" length:4];
        uint32_t chunk = 36 + n * 2;
        [wav appendBytes:&chunk length:4];
        [wav appendBytes:"WAVEfmt " length:8];
        uint32_t sub1 = 16;
        [wav appendBytes:&sub1 length:4];
        uint16_t fmt = 1;
        [wav appendBytes:&fmt length:2];
        uint16_t ch = 1;
        [wav appendBytes:&ch length:2];
        uint32_t sr = rate;
        [wav appendBytes:&sr length:4];
        uint32_t br = rate * 2;
        [wav appendBytes:&br length:4];
        uint16_t ba = 2;
        [wav appendBytes:&ba length:2];
        uint16_t bps = 16;
        [wav appendBytes:&bps length:2];
        [wav appendBytes:"data" length:4];
        uint32_t sub2 = n * 2;
        [wav appendBytes:&sub2 length:4];
        
        for (int i = 0; i < n; i++) {
            double t = (double)i / rate;
            double env = 1.0 - (t / dur);
            if (env < 0) {
                env = 0;
            }
            double sin_val = sin(2.0 * M_PI * (double)freq * t) * 0.7 + sin(2.0 * M_PI * (double)(freq * 1.5) * t) * 0.3;
            int16_t s = (int16_t)(sin_val * 32767.0 * env * amp);
            [wav appendBytes:&s length:2];
        }
        
        AVAudioPlayer* p = [[AVAudioPlayer alloc] initWithData:wav error:nil];
        [p prepareToPlay];
        return p;
    } @catch (NSException* e) {
        return nil;
    }
}

static void PlayKillSound(void) {
    if (!gKillPlayer) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        gKillPlayer.currentTime = 0;
        [gKillPlayer play];
    });
}

static void PlayHitSound(void) {
    if (!gHitPlayer) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        gHitPlayer.currentTime = 0;
        [gHitPlayer play];
    });
}

// OFFSETS
namespace off {
    constexpr uint64_t kObjCachedPtr = 0x10;
    constexpr uint64_t kPlayerIsDead = 0xB8;
    constexpr uint64_t kPlayerTeam = 0xBC;
    constexpr uint64_t kPlayerNickName = 0xC0;
    constexpr uint64_t kPlayerCharacter = 0xF0;
    constexpr uint64_t kCharModelContainer = 0x120;
    constexpr uint64_t kCharController = 0x130;
    constexpr uint64_t kCharHealth = 0x13C;
    constexpr uint64_t kCharArmor = 0x140;
    constexpr uint64_t kCharIsDead = 0x150;
    
    constexpr uint64_t kCtrlCC = 0x48;
    constexpr uint64_t kCtrlEquip = 0x50;
    
    constexpr uint64_t kLocalCamera = 0x90;
    constexpr uint64_t kOtherRemoteVis = 0xC8;
    constexpr uint64_t kRvModel = 0x48;
    constexpr uint64_t kRvItemView = 0xB0;
    constexpr uint64_t kModelAnimator = 0x20;
    constexpr uint64_t kModelWeaponTf = 0x40;
    constexpr uint64_t kModelHead = 0x58;
    constexpr uint64_t kCamComponent = 0x48;
    constexpr uint64_t kCamIsBusy = 0x60;
    constexpr uint64_t kCamIsDisable = 0x61;
    constexpr uint64_t kCamHands = 0x40;
    
    constexpr uint64_t kEquipData = 0x178;
    constexpr uint64_t kEquipCoolTime = 0x180;
    constexpr uint64_t kWepAmmoTotal = 0x1BC;
    constexpr uint64_t kWepAmmo = 0x1C0;
    constexpr uint64_t kWepIsReload = 0x1C4;
    constexpr uint64_t kWepLastShotTime = 0x228;
    constexpr uint64_t kWepSpread = 0x1F0; // Vector2 <Spread>k__BackingField
    constexpr uint64_t kWepRecoil = 0x1F8; // Vector3 <Recoil>k__BackingField
    constexpr uint64_t kWepRangeData = 0x1B0; // WeaponDataRange <RangeData>k__BackingField
    constexpr uint64_t kWepOffset = 0x1D8; // Vector3 Offset
    constexpr uint64_t kWepJyw = 0x1E4; // Vector3 jyw
    constexpr uint64_t kWepJzc = 0x204; // Vector3 jzc
    constexpr uint64_t kWepIsAiming = 0x1A1; // bool IsAiming
    constexpr uint64_t kItemDataId = 0xB0;   // Item.DataId (System.String*, SyncVar)
    constexpr uint64_t kDataAmmo = 0xA8;
    constexpr uint64_t kDataShootCount = 0xB0; // int ShootCount
    constexpr uint64_t kDataShootMultiOffset = 0xB4; // Vector3 ShootMultiOffset
    constexpr uint64_t kDataRecoilPattern = 0xA0; // List<Vector2> RecoilPattern
    constexpr uint64_t kDataFireBackOffset = 0x90; // Vector3 _fireBackOffset
    constexpr uint64_t kDataFireBackTime = 0x9C; // float _fireBackOffsetTime
    constexpr uint64_t kRangeShootOffset = 0xF8; // Vector2 ShootOffset
    constexpr uint64_t kRangeSpreadMove = 0x100; // Vector2 SpreadMove
    constexpr uint64_t kRangeOffsetCool = 0x108; // float OffsetCool
    constexpr uint64_t kRangeStandingBallisticMul = 0x10C; // float StandingBallisticMul
    constexpr uint64_t kRangeRecoilPatternScale = 0x110; // float RecoilPatternScale
    constexpr uint64_t kRangeUnscopedRecoilMul = 0x114; // float UnscopedRecoilMul
    constexpr uint64_t kCamRot = 0x30; // Vector2 rot
    constexpr uint64_t kCamAdditionalRot = 0x38; // Vector2 additionalRot
    constexpr uint64_t kCamStateBegin = 0x30; // SceneLevelCamera::rot
    constexpr uint64_t kCamStateSize = 0x10; // rot + additionalRot only (safe to restore)
    
    constexpr uint64_t kMoveIsGrounded = 0x28;
    constexpr uint64_t kMoveSpeed = 0x3C;
    constexpr uint64_t kMoveGravity = 0x40;
    constexpr uint64_t kMoveJumpH = 0x4C;
    constexpr uint64_t kMoveVelocity = 0x5C;
    
    constexpr uint64_t kVolumeWeight = 0x2C;
    
    // =====================================================================================
    // RAGE / COMBAT OFFSETS
    //
    // Every value below is copied verbatim out of out/dump.cs. Sources:
    //   ItemEquipWeaponRange      -> Image 0 Assembly-CSharp.dll  (TypeDefIndex 1307)
    //   WeaponDataRange           -> Image 0 Assembly-CSharp.dll  (TypeDefIndex 1767)
    //   ItemEquipWeaponRangeShotgun -> Image 0 Assembly-CSharp.dll (TypeDefIndex 1311)
    //   SceneLevelCamera          -> Image 0 Assembly-CSharp.dll
    //   Player / Character        -> Image 0 Assembly-CSharp.dll
    //
    // Offsets that only exist in the dump but not in this file are marked with the
    // dump line they were read from so a rebuild after a game patch is a one-grep job.
    // =====================================================================================
    
    // --- ItemEquipWeaponRange: combat-relevant instance data ---------------------------
    constexpr uint64_t kRngIsAiming        = 0x1A1; // bool IsAiming
    constexpr uint64_t kRngNetworkIsAiming = 0x1A2; // bool NetworkIsAiming
    constexpr uint64_t kRngOnReloadEvent   = 0x1A8; // Action OnReloadEvent
    constexpr uint64_t kRngUnlimitedAmmo   = 0x1B8; // bool UnlimitedAmmo
    constexpr uint64_t kRngMagCapacity     = 0x25C; // int  (jzj, resolved via MagazineCapacity in dump)
    constexpr uint64_t kRngReloadCooldown  = 0x258; // int  jzi
    constexpr uint64_t kRngShotSerial      = 0x21C; // float jzf
    constexpr uint64_t kRngHitList         = 0x210; // List<ItemEquipWeapon.Hit> jzd
    constexpr uint64_t kRngShotSerialInt   = 0x218; // int  jze
    constexpr uint64_t kRngGameObject      = 0x220; // GameObject jzg
    
    // --- Anti-cheat burst bookkeeping present on the weapon ---------------------------
    constexpr uint64_t kRngAcBurstStart    = 0x238; // double AcBurstStart
    constexpr uint64_t kRngAcPellets       = 0x240; // int    AcPelletsInBurst
    constexpr uint64_t kRngAcMagRounds     = 0x244; // int    AcMagRoundsLeft
    constexpr uint64_t kRngAcServerShots   = 0x248; // int    AcServerShots
    constexpr uint64_t kRngAcAmmoBurstTime = 0x250; // double AcAmmoBurstTime
    
    // --- WeaponDataRange: data the weapon reads when it builds the shot ---------------
    constexpr uint64_t kWdrAmmo            = 0xA8;  // int  Ammo
    constexpr uint64_t kWdrShootCount      = 0xB0;  // int  ShootCount
    constexpr uint64_t kWdrShootMultiOffset = 0xB4; // Vector3 ShootMultiOffset
    constexpr uint64_t kWdrFireBackOffset  = 0x90;  // Vector3 _fireBackOffset
    constexpr uint64_t kWdrFireBackTime    = 0x9C;  // float  _fireBackOffsetTime
    constexpr uint64_t kWdrRecoilPattern   = 0xA0;  // List<Vector2> RecoilPattern
    constexpr uint64_t kWdrPelletCount     = 0xC4;  // int  PelletCount (shotgun)
    constexpr uint64_t kWdrRange           = 0xD0;  // float Range
    constexpr uint64_t kWdrDamage          = 0xD8;  // float Damage
    constexpr uint64_t kWdrHeadshotMul     = 0xDC;  // float HeadshotMultiplier
    
    // --- Character / player: rage reads beyond health and armor ------------------------
    constexpr uint64_t kCharMaxHealth      = 0x138; // int  MaxHealth
    constexpr uint64_t kCharTeam           = 0xBC;  // int  Team
    constexpr uint64_t kCharFootsteps      = 0x154; // bool Footsteps (noise emission)
    constexpr uint64_t kCharCrouch         = 0x155; // bool IsCrouch
    constexpr uint64_t kCharSprint         = 0x156; // bool IsSprint
    
    // --- SceneLevelCamera: recoil kick lands here -------------------------------------
    // dump.cs: SceneLevelCamera.rot        -> Vector2 @ 0x30 (yaw in .x, pitch in .y)
    //          SceneLevelCamera.additionalRot -> Vector2 @ 0x38
    //          IsBusy @ 0x60, IsDisable @ 0x61 (see kCamIsBusy / kCamIsDisable above)
    constexpr uint64_t kCamRotYaw          = 0x30;  // Vector2 rot        (read only)
    constexpr uint64_t kCamRotOffset       = 0x38;  // Vector2 additionalRot (anti-aim writes here)
    constexpr uint64_t kCamRotPitch        = 0x34;  // Vector2 rot.y
    constexpr uint64_t kCamStateSizeRage   = 0x08;  // one Vector2
}

// =========================================================================================
// RAGE GLOBALS
//
// One flag or one tune per RAGE row. Everything here is a plain std::atomic so the
// render thread (espTick), the camera LateUpdate hook and the weapon Update hook can
// all read the same value without a lock.
//
// Naming rule used by the neighbouring code is kept: g<Rage><Thing>. The ConfigManager
// key is always written next to the flag so save/load and UI never drift apart.
// =========================================================================================
static std::atomic<bool>  gRageEnabled{false};             // rg_e   master switch for the tab
static std::atomic<bool>  gRageAutoAim{true};              // rg_a   pick a target and aim at it
static std::atomic<bool>  gRageAutoFire{false};            // rg_f   pull the trigger when the shot is valid
static std::atomic<bool>  gRageAutoScope{false};           // rg_sc  force ADS before firing
static std::atomic<bool>  gRageAutoReload{true};           // rg_r   reload the moment the mag runs dry
static std::atomic<bool>  gRageAutoPistol{false};          // rg_ap  switch to the sidearm at 0 ammo
static std::atomic<bool>  gRageAutoZeus{false};            // rg_z   treat a full-auto spray as a tap
static std::atomic<int>   gRageMinDamage{1};               // rg_dmg minimum damage the shot must be worth
static std::atomic<int>   gRageHitchance{0};               // rg_hc  percent, 0 disables the check
static std::atomic<int>   gRagePriority{0};                // rg_pri 0 distance, 1 lowest hp, 2 crosshair, 3 threat
static std::atomic<int>   gRagePoint{0};                   // rg_pt  0 head, 1 chest, 2 pelvis, 3 nearest to crosshair
static std::atomic<bool>  gRageVisibleOnly{true};          // rg_vo  never fire through a wall
static std::atomic<bool>  gRageTeamCheck{true};            // rg_tc  skip teammates
static std::atomic<float> gRageFovPx{600.0f};              // rg_fov aim cone in pixels, not degrees
static std::atomic<float> gRageSmooth{0.35f};              // rg_sm  0 = instant snap, 1 = never arrive
static std::atomic<float> gRageSwitchDelay{120.0f};        // rg_swd ms to hold a target before switching
static std::atomic<float> gRageFireDelay{60.0f};           // rg_fd  ms between auto-fire pulls
static std::atomic<float> gRageSlowAim{0.0f};              // rg_sla extra ms added to the fire delay
static std::atomic<float> gRageMaxRange{300.0f};           // rg_mr  maximum target-selection range in metres
static std::atomic<float> gRageAimStep{0.0f};              // rg_stp 0 = LookAtTarget, >0 = N steps per frame
static std::atomic<bool>  gRageBypassSmoke{false};         // rg_smoke ignore smoke volumes
static std::atomic<bool>  gRageIgnoreTeammatesInFov{true}; // rg_itf do not let a mate block the shot
static std::atomic<bool>  gRageHitboxExpand{false};        // rg_hbx grow the aim cone on moving targets
static std::atomic<float> gRageHitboxExpandPx{4.0f};       // rg_hbxp pixels added while the target strafes
static std::atomic<bool>  gRageAutoStop{false};            // rg_ast stop firing when out of ammo
static std::atomic<bool>  gRageBurst{false};               // rg_bst fire a burst instead of a single shot
static std::atomic<int>   gRageBurstCount{3};              // rg_bc  rounds per burst
static std::atomic<int>   gRageBurstPause{140};            // rg_bp  ms of silence between bursts
static std::atomic<bool>  gRageAirStuck{false};            // rg_air aim only while grounded
static std::atomic<bool>  gRageLogShots{false};            // rg_log write every auto-fired shot
static std::atomic<int>   gRageLogMax{24};                 // rg_logn ring size for the shot log
static std::atomic<bool>  gRagePerTargetStats{false};      // rg_pts track hit/miss per player
static std::atomic<bool>  gRageTeleport{false};            // rg_tp snap behind the target, off by default
static std::atomic<float> gRageTeleportDist{2.0f};         // rg_tpd metres behind the target
static std::atomic<bool>  gRageAntiAim{false};             // rg_aa spin the local camera state
static std::atomic<float> gRageAntiAimYaw{180.0f};         // rg_aay degrees of yaw offset
static std::atomic<float> gRageAntiAimPitch{-89.0f};       // rg_aap degrees of pitch offset
static std::atomic<bool>  gRageAntiAimJitter{false};       // rg_aaj flip the offsets every frame
static std::atomic<int>   gRageAntiAimMode{0};             // rg_aam 0 static, 1 spin, 2 jitter, 3 back-and-forth
static std::atomic<float> gRageAntiAimSpin{720.0f};        // rg_aas degrees per second while spinning
static std::atomic<bool>  gRageForceBaim{false};           // rg_fb  always aim for the chest
static std::atomic<bool>  gRageOnKey{false};               // rg_ok  only act while the rage hotkey is held
static std::atomic<bool>  gRageDebug{false};               // rg_dbg verbose log line per decision

// Per-target rolling statistics. Keyed by the il2cpp Player object pointer so the
// map dies together with the match (the entries are pruned in RageTick).
struct RageTargetStat {
    int shots = 0;
    int hits = 0;
    int headshots = 0;
    uint64_t firstSeenMs = 0;
    uint64_t lastSeenMs = 0;
    float lastDistance = 0.0f;
    int lastHealth = 0;
    int lastArmor = 0;
    bool visible = false;
};
static std::unordered_map<void*, RageTargetStat> gRageStats;

// Ring buffer of the last auto-fired shots, shown in the RAGE log panel.
struct RageLogEntry {
    char target[40];
    float distance;
    int damage;
    bool hit;
    uint64_t atMs;
};
static std::vector<RageLogEntry> gRageLog;
static std::atomic<uint64_t> gRageLastLogMs{0};       // last shot-log row written
static std::atomic<uint64_t> gRageLastPruneMs{0};     // last housekeeping sweep (separate clock)

// Runtime state shared between the camera hook, the weapon hook and the tick.
static std::atomic<void*> gRageTarget{nullptr};       // currently locked player
static std::atomic<uint64_t> gRageTargetSince{0};     // when the lock started
static std::atomic<uint64_t> gRageLastFireMs{0};      // last auto-fire pull
static std::atomic<int> gRageBurstLeft{0};            // rounds left in the current burst
static std::atomic<uint64_t> gRageBurstNextMs{0};     // when the next burst round is due
static std::atomic<bool> gRageTriggerHeld{false};     // synthetic trigger state
static std::atomic<int> gRageShotSerial{0};           // shots observed, for hitchance maths
static std::atomic<int> gRageHitSerial{0};            // hits observed, for hitchance maths
static std::atomic<int> gRageLastHitSerial{0};        // shot serial the last hit belongs to
static std::atomic<uint64_t> gRageLastHitMs{0};       // when the last hit landed
static Vec3 gRageLastTargetPos{};
static uint64_t gRageLastTargetMs = 0;
// Step-smoothing cursor. Kept separate from gRageLastTargetPos on purpose: the bookkeeping
// block in RageTick overwrites gRageLastTargetPos with the real model position every frame,
// which would otherwise restart the step from the true position and cancel the smoothing.
static Vec3 g_smoothAimCursor{};
static bool g_smoothAimCursorValid = false;
static Vec3 gRageLastLocalPos{};
static uint64_t gRageLastLocalMs = 0;

// IL2CPP TYPES
typedef void* (*fn_domain_get)();
typedef void** (*fn_domain_get_assemblies)(void*, size_t*);
typedef void* (*fn_assembly_get_image)(void*);
typedef void* (*fn_class_from_name)(void*, const char*, const char*);
typedef void* (*fn_class_get_method_from_name)(void*, const char*, int);
typedef void* (*fn_class_get_methods)(void*, void**);
typedef const char* (*fn_method_get_name)(void*);
typedef uint32_t (*fn_method_get_param_count)(void*);
typedef void* (*fn_method_get_param)(void*, uint32_t);
typedef char* (*fn_type_get_name)(void*);
typedef void* (*fn_class_get_type)(void*);
typedef void* (*fn_type_get_object)(void*);
typedef const char* (*fn_class_get_name)(void*);
typedef const char* (*fn_class_get_namespace)(void*);
typedef void* (*fn_class_get_parent)(void*);
typedef size_t (*fn_image_get_class_count)(const void*);
typedef void* (*fn_image_get_class)(const void*, size_t);
typedef void* (*fn_runtime_invoke)(void*, void*, void**, void**);
typedef void* (*fn_thread_attach)(void*);
typedef uint32_t (*fn_gchandle_new)(void*, bool);
typedef void (*fn_gchandle_free)(uint32_t);
typedef void* (*fn_gchandle_get_target)(uint32_t);
typedef void* (*fn_string_new)(const char*);
typedef void* (*fn_object_new)(void*);
typedef void* (*fn_array_new)(void*, size_t);

typedef Vec3 (*fn_camW2S)(void*, Vec3, void*);
typedef int (*fn_camGetPixelWidth)(void*, void*);
typedef int (*fn_camGetPixelHeight)(void*, void*);
typedef float (*fn_camGetFov)(void*, void*);
typedef void (*fn_camSetAspect)(void*, float, void*);
typedef void (*fn_camSetFov)(void*, float, void*);
typedef void (*fn_sceneSetFov)(void*, float, void*);
typedef Vec3 (*fn_tfGetPos)(void*, void*);
typedef void (*fn_tfSetPos)(void*, Vec3, void*);
typedef Vec3 (*fn_tfGetLocalScale)(void*, void*);
typedef void (*fn_tfSetLocalScale)(void*, Vec3, void*);
typedef Vec3 (*fn_tfGetEuler)(void*, void*);
typedef void* (*fn_getBoneTransform)(void*, int, void*);
typedef void* (*fn_getTransform)(void*, void*);
typedef void* (*fn_getSkybox)(void* mi);
typedef void (*fn_matSetColor)(void* self, void* name, UnityColor value, void* mi);
typedef void* (*fn_rendGetSharedMats)(void*, void*);
typedef void (*fn_rendSetSharedMats)(void*, void*, void*);
typedef void (*fn_rendSetEnabled)(void*, bool, void*);
typedef bool (*fn_rendGetEnabled)(void*, void*);
typedef void (*fn_matSetFloat)(void*, void*, float, void*);
typedef void (*fn_matSetTexture)(void*, void*, void*, void*);
typedef void (*fn_matSetInt)(void*, void*, int, void*);
typedef void (*fn_matEnableKeyword)(void*, void*, void*);
typedef void (*fn_matSetRenderQueue)(void*, int, void*);
typedef void (*fn_LookAtTarget)(void* self, Vec3 target, void* mi);
typedef bool (*fn_CheckSeen)(void* self, Vec3 target, void* mi);
typedef void* (*fn_getGameObject)(void*, void*);
typedef UnityColor (*fn_renderGetAmbientLight)(void*);
typedef void (*fn_renderSetAmbientLight)(void*, UnityColor, void*);
typedef float (*fn_lightGetIntensity)(void*, void*);
typedef void (*fn_lightSetIntensity)(void*, float, void*);
typedef UnityColor (*fn_lightGetColor)(void*, void*);
typedef void (*fn_lightSetColor)(void*, UnityColor, void*);
typedef void (*fn_setFog)(bool, void*);
typedef bool (*fn_getFog)(void*);

static fn_domain_get p_domain_get = nullptr;
static fn_domain_get_assemblies p_domain_get_assemblies = nullptr;
static fn_assembly_get_image p_assembly_get_image = nullptr;
static fn_class_from_name p_class_from_name = nullptr;
static fn_class_get_method_from_name p_class_get_method_from_name = nullptr;
static fn_class_get_methods p_class_get_methods = nullptr;
static fn_method_get_name p_method_get_name = nullptr;
static fn_method_get_param_count p_method_get_param_count = nullptr;
static fn_method_get_param p_method_get_param = nullptr;
static fn_type_get_name p_type_get_name = nullptr;
static fn_class_get_type p_class_get_type = nullptr;
static fn_type_get_object p_type_get_object = nullptr;
static fn_class_get_name p_class_get_name = nullptr;
static fn_class_get_namespace p_class_get_namespace = nullptr;
static fn_class_get_parent p_class_get_parent = nullptr;
static fn_image_get_class_count p_image_get_class_count = nullptr;
static fn_image_get_class p_image_get_class = nullptr;
static fn_runtime_invoke p_runtime_invoke = nullptr;
static fn_thread_attach p_thread_attach = nullptr;
static fn_gchandle_new p_gchandle_new = nullptr;
static fn_gchandle_free p_gchandle_free = nullptr;
static fn_gchandle_get_target p_gchandle_get_target = nullptr;
static fn_string_new p_string_new = nullptr;
static fn_object_new p_object_new = nullptr;
static fn_array_new p_array_new = nullptr;

static void* gDomain = nullptr;
static void* gObjCls = nullptr;
static void* gGOCls = nullptr;
static void* gTransformCls = nullptr;
static void* gAnimatorCls = nullptr;
static void* gCharCls = nullptr;
static void* gVolumeCls = nullptr;
static void* gMatCls = nullptr;
static void* gSkyboxCls = nullptr;
static void* gRendererCls = nullptr;
static void* gLightCls = nullptr;
static void* gColorAdjCls = nullptr;
static void* gBloomCls = nullptr;
static void* gMotionBlurCls = nullptr;
static void* gApplicationCls = nullptr;
static void* gSetTargetFrameRateMI = nullptr;
static void* gClampedFCls = nullptr;
static void* gMinFCls = nullptr;
static void* gFloatPCls = nullptr;
static void* gCamDataCls = nullptr;

static uint32_t gPlayerTypeHandle = 0;
static uint32_t gVolumeTypeHandle = 0;
static uint32_t gLightTypeHandle = 0;
static uint32_t gCamDataTypeHandle = 0;

static void* p_findPlayerMI = nullptr;
static void* p_findVolumeMI = nullptr;
static void* p_getBoneTransformMI = nullptr;
static void* p_camW2SMI = nullptr;
static void* p_camGetPixelWidthMI = nullptr;
static void* p_camGetPixelHeightMI = nullptr;
static void* p_camGetFovMI = nullptr;
static void* p_camSetAspectMI = nullptr;
static void* p_camSetFovMI = nullptr;
static void* p_sceneSetFovMI = nullptr;
static void* p_tfGetPosMI = nullptr;
static void* p_tfSetPosMI = nullptr;
static void* p_tfGetLocalScaleMI = nullptr;
static void* p_tfSetLocalScaleMI = nullptr;
static void* p_tfGetEulerMI = nullptr;
static void* p_getTransformMI = nullptr;
static void* p_getSkyboxMI = nullptr;
static void* p_matSetColorMI = nullptr;
static void* p_matCopyCtorMI = nullptr;
static void* p_matSetFloatMI = nullptr;
static void* p_matSetTextureMI = nullptr;
static void* p_matSetIntMI = nullptr;
static void* p_matEnableKeywordMI = nullptr;
static void* p_matSetRQMI = nullptr;
static void* p_lightGetIntensityMI = nullptr;
static void* p_lightSetIntensityMI = nullptr;
static void* p_lightGetColorMI = nullptr;
static void* p_lightSetColorMI = nullptr;
static void* p_setFogMI = nullptr;
static void* p_getFogMI = nullptr;
static void* p_cfaValMI = nullptr;
static void* p_mfaValMI = nullptr;
static void* p_fpaValMI = nullptr;
static void* p_rendGetSharedMatsMI = nullptr;
static void* p_rendSetSharedMatsMI = nullptr;
static void* p_rendSetEnabledMI = nullptr;
static void* p_rendGetEnabledMI = nullptr;
static void* p_getCompsInChildrenMI = nullptr;
static void* p_getGameObjectMI = nullptr;
static void* p_lookAtTargetMI = nullptr;
static void* p_checkSeenMI = nullptr;

static fn_camW2S p_camW2S = nullptr;
static fn_camGetPixelWidth p_camGetPixelWidth = nullptr;
static fn_camGetPixelHeight p_camGetPixelHeight = nullptr;
static fn_camGetFov p_camGetFov = nullptr;
static fn_camSetAspect p_camSetAspect = nullptr;
static fn_camSetFov p_camSetFov = nullptr;
static fn_sceneSetFov p_sceneSetFov = nullptr;
static fn_tfGetPos p_tfGetPos = nullptr;
static fn_tfSetPos p_tfSetPos = nullptr;
static fn_tfGetLocalScale p_tfGetLocalScale = nullptr;
static fn_tfSetLocalScale p_tfSetLocalScale = nullptr;
static fn_tfGetEuler p_tfGetEuler = nullptr;
static fn_getBoneTransform p_getBoneTransform = nullptr;
static fn_getTransform p_getTransform = nullptr;
static fn_getSkybox p_getSkybox = nullptr;
static fn_matSetColor p_matSetColor = nullptr;
static fn_rendGetSharedMats p_rendGetSharedMats = nullptr;
static fn_rendSetSharedMats p_rendSetSharedMats = nullptr;
static fn_rendSetEnabled p_rendSetEnabled = nullptr;
static fn_rendGetEnabled p_rendGetEnabled = nullptr;
static fn_matSetFloat p_matSetFloat = nullptr;
static fn_matSetTexture p_matSetTexture = nullptr;
static fn_matSetInt p_matSetInt = nullptr;
static fn_matEnableKeyword p_matEnableKeyword = nullptr;
static fn_matSetRenderQueue p_matSetRQ = nullptr;
static fn_lightGetIntensity p_lightGetIntensity = nullptr;
static fn_lightSetIntensity p_lightSetIntensity = nullptr;
static fn_lightGetColor p_lightGetColor = nullptr;
static fn_lightSetColor p_lightSetColor = nullptr;
static fn_setFog p_setFog = nullptr;
static fn_getFog p_getFog = nullptr;
static fn_getGameObject p_getGameObject = nullptr;
static fn_LookAtTarget p_lookAtTarget = nullptr;
static fn_CheckSeen p_CheckSeen = nullptr;

// GLOBALS
static std::atomic<bool> gEspEnabled{false};
static std::atomic<bool> gSkeletonEnabled{false};
static std::atomic<bool> gHealthBarEnabled{false};
static std::atomic<bool> gNameEnabled{false};
static std::atomic<bool> gTracersEnabled{false};
static std::atomic<bool> gOofEnabled{false};

static std::atomic<bool> gAimbotEnabled{false};
static std::atomic<bool> gAimOnFireEnabled{false};
static std::atomic<bool> gSilentAimEnabled{false};
static std::atomic<bool> gHotAimbotEnabled{false};
static std::atomic<bool> gHotAimOnFireEnabled{false};

// Fire button state. Aim On Fire must only lock while the trigger is actually held.
// gFireHeldUntil is a deadline, not a latched flag, so a missed OnClickFireUp (touch
// cancelled by the OS, hook not installed, etc.) can never leave the aimbot stuck on.
static std::atomic<uint64_t> gFireHeldUntil{0};

static inline bool IsFireHeld(void) {
    return NowMs() < gFireHeldUntil.load();
}
static std::atomic<bool> gHotEspEnabled{false};
static std::atomic<bool> gInvertPitch{false};
static std::atomic<bool> gInvertYaw{false};
static std::atomic<int> gAimBone{10};
static std::atomic<int> gAimbotFovPx{300};
static std::atomic<bool> gPredictionEnabled{false};
static std::atomic<float> gAimbotSmooth{0.0f};
static std::atomic<float> gAimOnFireSmooth{0.0f};
static std::atomic<bool> gAimbotVisibleOnly{false};
static std::atomic<bool> gAimbotNoTeam{true};

static std::atomic<bool> gSpeedHackEnabled{false};
static std::atomic<float> gSpeedHackVal{1.0f};
static std::atomic<bool> gJumpHackEnabled{false};
static std::atomic<float> gJumpHackVal{1.0f};

static std::atomic<bool> gRapidFireEnabled{false};
static std::atomic<bool> gInstantReloadEnabled{false};
static std::atomic<bool> gUnlimAmmoEnabled{false};
static std::atomic<bool> gNoSpreadEnabled{false};
static std::atomic<bool> gNoRecoilEnabled{false};

// BALLISTICS
// No Spread / No Recoil are implicit while any aim mode is active. The manual
// PLAYER-tab toggles are the only way to run them without aiming.
static std::atomic<bool> gBallisticsDebug{false};
static std::atomic<bool> gSpreadFloorEnabled{false};
static std::atomic<float> gSpreadFloor{0.0f};

// HUD / VISUALS
static std::atomic<bool> gHeadDotEnabled{true};
static std::atomic<bool> gDistanceEnabled{true};
static std::atomic<bool> gHealthTextEnabled{false};
static std::atomic<bool> gHitMarkerEnabled{true};
static std::atomic<bool> gDamageNumbersEnabled{true};
static std::atomic<int> gHitMarkerStyle{0};
static std::atomic<float> gHitMarkerSize{10.0f};
static std::atomic<int> gHitMarkerDuration{260};
static std::atomic<bool> gHitMarkerShowDamage{false};
static std::atomic<float> gDamageNumberSize{13.0f};
static std::atomic<int> gDamageNumberDuration{650};
static std::atomic<float> gDamageNumberRise{32.0f};
static std::atomic<bool> gDamageNumberOutline{true};
static std::atomic<bool> gRadarEnabled{false};
static std::atomic<bool> gCrosshairEnabled{false};
static std::atomic<bool> gScopeOverlayEnabled{false};
static std::atomic<bool> gAimLineEnabled{false};
static std::atomic<bool> gTeamColorEnabled{false};
static std::atomic<bool> gVisibleColorEnabled{false};
static std::atomic<bool> gSnapBottomEnabled{false};
static std::atomic<bool> gKillFeedEnabled{true};
static std::atomic<int> gBoxStyle{0};
static std::atomic<float> gSkelThickness{1.5f};
static std::atomic<int> gRadarRange{60};
static std::atomic<float> gRadarSize{120.0f};
static std::atomic<bool> gRadarRotate{true};

static UIColor* gTeamColor = [UIColor cyanColor];
static UIColor* gVisibleColor = [UIColor greenColor];
static UIColor* gHiddenColor = [UIColor redColor];
static UIColor* gHitMarkerColor = [UIColor whiteColor];
static UIColor* gDamageNumberColor = [UIColor colorWithRed:1.0 green:0.75 blue:0.1 alpha:1.0];
static UIColor* gRadarColor = [UIColor greenColor];
static UIColor* gCrosshairColor = [UIColor whiteColor];

struct HudPlayerInfo {
    CGRect box;
    CGPoint head;
    CGPoint feet;
    int health;
    int armor;
    int team;
    bool visible;
    float distance;
};

struct HudDamageInfo {
    CGPoint pos;
    int amount;
    uint64_t until;
};

struct HudKillInfo {
    char name[40];
    uint64_t until;
};

struct HudRadarBlip {
    float x;
    float y;
    int team;
    bool dead;
};

static std::vector<HudPlayerInfo> gHudPlayers;
static std::vector<HudDamageInfo> gHudDamage;
static std::vector<HudKillInfo> gHudKills;
static std::vector<HudRadarBlip> gHudRadar;
static CGPoint gHudAimLineTarget = CGPointMake(0, 0);
static bool gHudAimLineActive = false;
static float gHudCrosshairGap = 6.0f;
static bool gHudCrosshairVisible = false;
static bool gHudScopeActive = false;
static uint64_t gHudHitMarkerUntil = 0;
static int gHudHitMarkerDamage = 0;

// FPS / FRAME-TIME GRAPH
static std::atomic<bool> gFpsEnabled{true};
static std::atomic<int> gFpsValue{0};
static std::atomic<float> gFrameMs{0.0f};
static std::vector<float> gFpsHistory;
static uint64_t gFpsLastSample = 0;
static int gFpsFrames = 0;

// =========================================================================================
// TRIGGERBOT
// Fires the real mobile-input fire path when the crosshair is inside a small
// pixel radius around an enemy bone. The instance/method pointers are captured
// from the OnClickFire* hooks, so no extra offsets are required.
// =========================================================================================
static std::atomic<bool> gTriggerbotEnabled{false};
static std::atomic<int> gTriggerbotDelay{90};          // ms between shots
static std::atomic<int> gTriggerbotFovPx{14};          // crosshair radius in px
static std::atomic<int> gTriggerbotHold{35};           // how long the fire call is held
static std::atomic<bool> gTriggerbotVisibleOnly{true};
static std::atomic<bool> gTriggerbotTeamCheck{true};
static std::atomic<bool> gTriggerbotScopeOnly{false};
static std::atomic<bool> gTriggerbotHeadOnly{false};

static void* gMobileInputsInst = nullptr;
static void* gMobileInputsFireMI = nullptr;
static void* gMobileInputsFireDownMI = nullptr;
static void* gMobileInputsFireUpMI = nullptr;
static uint64_t gTriggerLastFireMs = 0;
static uint64_t gTriggerReleaseMs = 0;
static bool gTriggerHolding = false;

static bool gTriggerHasTarget = false;
static float gTriggerBestDist = 99999.0f;
static Vec3 gTriggerBestPos{};
static bool gTriggerBestVisible = false;

// =========================================================================================
// SKIN CHANGER
// Catalog comes from GameManager.Data._items (List<ItemData>); every ItemWeaponSkin /
// ItemSkin entry carries its asset name (ItemData.get_Id) and _targetItem (0x70).
// Applying writes Item.<ItemSkinData> (0xE8) on the local weapon and fires
// FireSkinDtoUpdate so the viewmodel rebuilds with the new model.
// =========================================================================================
struct SkinEntry {
    std::string id;
    std::string target;
    void* obj;
    int rarity;
};

struct WeaponEntry {
    std::string id;
    std::string label;
    void* obj;
    int skinCount;
};

static std::atomic<bool> gSkinChangerEnabled{false};
static std::vector<SkinEntry> gSkinCatalog;
static std::vector<WeaponEntry> gWeaponList;
static std::vector<int> gSkinFiltered;
static int gSkinTargetIndex = 0;
static int gSkinIndex = 0;
static bool gSkinCatalogLoaded = false;
static void* gSkinSelectedObj = nullptr;
static std::string gSkinSelectedId;
static std::string gSkinSelectedTarget;
static std::string gSkinPendingId;
static std::atomic<bool> gSkinApplying{false};
static void* gWeaponClasses[12] = {nullptr};
static int gWeaponClassCount = 0;

static UIColor* SkinRarityColor(int rarity) {
    switch (rarity) {
        case 1:  return [UIColor colorWithRed:0.42 green:0.72 blue:0.95 alpha:1.0];
        case 2:  return [UIColor colorWithRed:0.24 green:0.44 blue:0.95 alpha:1.0];
        case 3:  return [UIColor colorWithRed:0.64 green:0.30 blue:0.95 alpha:1.0];
        case 4:  return [UIColor colorWithRed:0.95 green:0.30 blue:0.64 alpha:1.0];
        case 5:  return [UIColor colorWithRed:0.95 green:0.56 blue:0.16 alpha:1.0];
        default: return [UIColor colorWithWhite:0.55 alpha:1.0];
    }
}

static const char* SkinRarityName(int rarity) {
    switch (rarity) {
        case 0:  return "Common";
        case 1:  return "Rare";
        case 2:  return "Epic";
        case 3:  return "Legendary";
        case 4:  return "Arcane";
        case 5:  return "Mythical";
        default: return "";
    }
}

static std::string SkinPrettyName(const std::string& id) {
    static const struct { const char* id; const char* label; } kMap[] = {
        {"Ak47", "AK-47"}, {"M4", "M4A4"}, {"M4A1", "M4A1-S"}, {"AWP", "AWP"},
        {"Deagle", "Desert Eagle"}, {"Fiveseven", "Five-SeveN"}, {"Glock", "Glock-18"},
        {"Usp", "USP-S"}, {"Ssg08", "SSG 08"}, {"Scar20", "SCAR-20"},
        {"G3sg1_delete", "G3SG1"}, {"Mag7_delete", "MAG-7"}, {"Negev_delete", "Negev"},
        {"Berettas_delete", "Dual Berettas"}, {"Bizon_delete", "PP-Bizon"},
        {"Cz75_delete", "CZ75-Auto"}, {"Xm1014", "XM1014"}, {"Sawedoff", "Sawed-Off"},
        {"Tec9", "Tec-9"}, {"Mp9", "MP9"}, {"Mp7", "MP7"}, {"Mp5", "MP5-SD"},
        {"Mac10", "MAC-10"}, {"Ump45", "UMP-45"}, {"P90", "P90"}, {"P250", "P250"},
        {"P2000", "P2000"}, {"Nova", "Nova"}, {"M249", "M249"}, {"Galil", "Galil AR"},
        {"Famas", "FAMAS"}, {"Aug", "AUG"}, {"Sg553", "SG 553"}, {"Knife", "Knife"},
        {"CFour", "C4"}, {"DefuseKit", "Defuse Kit"},
        {"GrenadeExplosion", "HE Grenade"}, {"GrenadeFlash", "Flashbang"},
        {"GrenadeIncendiary", "Incendiary"}, {"GrenadeMolotov", "Molotov"},
        {"GrenadeSmoke", "Smoke Grenade"},
    };
    for (const auto& e : kMap) {
        if (id == e.id) {
            return std::string(e.label);
        }
    }
    return id;
}

static void* gItemCls = nullptr;
static void* gItemWeaponSkinCls = nullptr;
static void* gItemSkinCls = nullptr;
static void* gGameManagerCls = nullptr;
static void* gDataCls = nullptr;
static void* gItemDataGetIdMI = nullptr;
static void* gItemFireSkinDtoUpdateMI = nullptr;
static void* gItemSyncSkinDtoMI = nullptr;
static void* gHandsEquipMI = nullptr;
static void* gHandsLoadModelMI = nullptr;
static void* gMobileInputsCls = nullptr;

// =========================================================================================
// CROSSHAIR / FOV CIRCLE / ESP STYLE
// =========================================================================================
static std::atomic<int> gCrosshairStyle{0};            // 0 cross, 1 dot, 2 circle, 3 T, 4 X
static std::atomic<float> gCrosshairGap{6.0f};
static std::atomic<float> gCrosshairLength{9.0f};
static std::atomic<float> gCrosshairThickness{1.4f};
static std::atomic<float> gCrosshairDot{1.5f};
static std::atomic<bool> gCrosshairOutline{true};

static std::atomic<bool> gFovCircleEnabled{true};
static std::atomic<int> gFovCircleStyle{0};            // 0 circle, 1 square, 2 corners
static std::atomic<float> gFovCircleThickness{1.0f};
static std::atomic<bool> gFovCircleFilled{false};

static std::atomic<float> gBoxThickness{1.0f};
static std::atomic<int> gHealthBarStyle{0};            // 0 left, 1 right, 2 top
static std::atomic<float> gHealthBarWidth{2.0f};
static std::atomic<int> gDistanceFormat{0};            // 0 m, 1 units
static std::atomic<bool> gDistanceAbove{false};
static std::atomic<bool> gEspFadeEnabled{false};
static std::atomic<float> gEspFadeStart{40.0f};
static std::atomic<float> gEspFadeEnd{140.0f};
static std::atomic<float> gOofSize{12.0f};
static std::atomic<float> gOofThickness{2.0f};

// =========================================================================================
// EXTENDED VISUALS / COMBAT / INFO PANELS
// =========================================================================================
static std::atomic<bool> gNameBgEnabled{true};
static std::atomic<float> gHeadDotSize{2.5f};
static std::atomic<bool> gWeaponEspEnabled{false};
static std::atomic<float> gWeaponEspThickness{1.0f};
static std::atomic<bool> gBoxFilled{false};
static std::atomic<float> gBoxFillAlpha{0.12f};
static std::atomic<bool> gEspHealthGradient{true};
static std::atomic<bool> gEspArmorBar{true};
static std::atomic<bool> gEspOffscreenArrows{true};
static std::atomic<float> gEspOffscreenMargin{40.0f};
static std::atomic<bool> gEspTeamFilter{false};
static std::atomic<bool> gEspDeadFilter{false};
static std::atomic<bool> gEspDistanceShadow{true};

static std::atomic<bool> gAimInfoEnabled{false};
static std::atomic<bool> gKeybindListEnabled{false};
static std::atomic<bool> gStatsPanelEnabled{false};
static std::atomic<bool> gDamageLogEnabled{false};
static std::atomic<bool> gAimDrawTarget{true};
static std::atomic<bool> gAimDrawFov{true};

static std::atomic<float> gPredictionAmount{0.0f};
static std::atomic<bool> gAimJitterEnabled{false};
static std::atomic<bool> gAimSwitchDelayEnabled{false};

static std::atomic<int> gStatKills{0};
static std::atomic<int> gStatHits{0};
static std::atomic<int> gStatDamage{0};
static std::atomic<int> gStatHeadshots{0};
static std::atomic<uint64_t> gStatSessionStart{0};

static std::atomic<int> gLocalHealthVal{100};
static std::atomic<int> gLocalArmorVal{0};
static std::atomic<int> gLocalAmmoVal{0};
static std::atomic<int> gLocalAmmoTotalVal{0};
static std::atomic<float> gLocalSpeedVal{0.0f};
static std::atomic<bool> gLocalScoped{false};

static std::atomic<float> gEventLogX{12.0f};
static std::atomic<float> gEventLogY{300.0f};
static std::atomic<float> gStatsPanelX{12.0f};
static std::atomic<float> gStatsPanelY{420.0f};
static std::atomic<bool> gPanelBackground{true};

static UIColor* gWeaponEspColor = [UIColor colorWithRed:1.0 green:0.6 blue:0.2 alpha:1.0];
static UIColor* gStatsColor = [UIColor whiteColor];
static UIColor* gAimInfoColor = [UIColor colorWithRed:0.9 green:0.3 blue:0.9 alpha:1.0];
static UIColor* gDamageLogColor = [UIColor colorWithRed:1.0 green:0.5 blue:0.5 alpha:1.0];

static std::atomic<int> gTargetPriority{0};          // 0 nearest, 1 lowest hp, 2 crosshair
static std::atomic<bool> gVelocityGraphEnabled{false};
static std::atomic<bool> gSessionInfoEnabled{false};
static std::atomic<bool> gDamageLogPanelEnabled{false};
static std::atomic<bool> gTargetListEnabled{false};
static std::atomic<bool> gCrosshairDebugEnabled{false};
static std::atomic<bool> gAmmoBarEnabled{false};
static std::vector<float> gSpeedHistory;

static std::atomic<float> gRadarBlipSize{2.5f};
static std::atomic<float> gRadarOpacity{0.38f};
static std::atomic<float> gBoxCornerLen{0.28f};
static std::atomic<int> gNameMaxLen{16};
static std::atomic<bool> gDamageStack{true};
static std::atomic<bool> gSkeletonUpperOnly{false};
static constexpr float kEspMaxDistanceMeters = 5000.0f;

// Target tracking used by prediction and the switch-delay gate.
static void* g_aimTargetObj = nullptr;
static std::unordered_map<void*, Vec3> gLastTargetPos;
static std::unordered_map<void*, uint64_t> gLastTargetMs;

// =========================================================================================
// PLAYER LIST / INFO PANEL / EVENT LOG
// =========================================================================================
static std::atomic<bool> gPlayerListEnabled{false};
static std::atomic<float> gPlayerListX{12.0f};
static std::atomic<float> gPlayerListY{220.0f};
static std::atomic<float> gPlayerListScale{1.0f};
static std::atomic<int> gPlayerListMax{8};
static std::atomic<bool> gPlayerListHealth{true};
static std::atomic<bool> gPlayerListDistance{true};
static std::atomic<bool> gPlayerListTeam{true};
static std::atomic<bool> gPlayerListWeapon{true};
static std::atomic<bool> gPlayerListDead{false};

static std::atomic<bool> gInfoPanelEnabled{false};
static std::atomic<float> gInfoPanelX{12.0f};
static std::atomic<float> gInfoPanelY{120.0f};
static std::atomic<bool> gInfoPanelHealth{true};
static std::atomic<bool> gInfoPanelAmmo{true};
static std::atomic<bool> gInfoPanelFps{true};
static std::atomic<bool> gInfoPanelSpeed{true};

static std::atomic<bool> gEventLogEnabled{false};
static std::atomic<int> gEventLogMax{6};
static std::atomic<float> gEventLogDuration{5000.0f};

// =========================================================================================
// WATERMARK / KILL FEED / HIT SOUND / AIM HUMANIZATION
// =========================================================================================
static std::atomic<bool> gWatermarkShowFps{true};
static std::atomic<bool> gWatermarkShowTime{true};
static std::atomic<bool> gWatermarkShowPlayers{true};
static std::atomic<float> gWatermarkScale{1.0f};
static std::atomic<float> gWatermarkAlpha{0.95f};

static std::atomic<float> gKillFeedDuration{6000.0f};
static std::atomic<int> gKillFeedMax{8};
static std::atomic<bool> gKillFeedShowKiller{true};

static std::atomic<float> gHitSoundPitch{3000.0f};
static std::atomic<float> gHitSoundVolume{0.8f};
static std::atomic<float> gKillSoundPitch{1500.0f};
static std::atomic<float> gKillSoundVolume{1.0f};

static std::atomic<float> gAimJitter{0.0f};
static std::atomic<int> gAimSwitchDelay{0};            // ms before switching target
static uint64_t gAimLastTargetMs = 0;
static void* gAimLastTarget = nullptr;

static UIColor* gFovCircleColor = [UIColor whiteColor];
static UIColor* gPlayerListColor = [UIColor whiteColor];
static UIColor* gEventLogColor = [UIColor colorWithRed:0.7 green:0.85 blue:1.0 alpha:1.0];
static UIColor* gKillFeedColor = [UIColor colorWithRed:1.0 green:0.35 blue:0.35 alpha:1.0];
static UIColor* gOofColor = [UIColor whiteColor];
static UIColor* gWatermarkAccent = [UIColor colorWithRed:0.45 green:0.35 blue:0.95 alpha:1.0];
static UIColor* gInfoPanelColor = [UIColor whiteColor];

struct HudEventInfo {
    char text[64];
    uint64_t until;
    int kind; // 0 info, 1 hit, 2 kill
};

static std::vector<HudEventInfo> gHudEvents;

static void RebuildSoundPlayers(void) {
    float hp = gHitSoundPitch.load();
    float hv = gHitSoundVolume.load();
    float kp = gKillSoundPitch.load();
    float kv = gKillSoundVolume.load();
    if (!std::isfinite(hp) || hp < 100.0f) {
        hp = 3000.0f;
    }
    if (!std::isfinite(hv) || hv < 0.0f) {
        hv = 0.8f;
    }
    if (!std::isfinite(kp) || kp < 100.0f) {
        kp = 1500.0f;
    }
    if (!std::isfinite(kv) || kv < 0.0f) {
        kv = 1.0f;
    }
    
    AVAudioPlayer* hit = MakeTonePlayer(hp, 0.08f, Math::Clamp(hv, 0.0f, 1.0f));
    if (hit) {
        gHitPlayer = hit;
    }
    AVAudioPlayer* kill = MakeTonePlayer(kp, 0.2f, Math::Clamp(kv, 0.0f, 1.0f));
    if (kill) {
        gKillPlayer = kill;
    }
}

// BALLISTICS / HUD FORWARD DECLS
static bool NoSpreadActive(void);
static bool NoRecoilActive(void);
static bool IsRangeWeapon(void* weapon);
static void BallisticsTick(void);
static void BallisticsWeaponTick(void* weapon);
static void BallisticsCameraPre(void* camera);
static void BallisticsCameraPost(void* camera);
static void BallisticsFirePre(void);
static void BallisticsFirePost(void);
static void InstallBallisticsHooks(void);
static void SetupHudView(void);
static void HudTick(void);
static void HudBeginFrame(void);
static void HudAddPlayer(const HudPlayerInfo& info);
static void HudAddDamage(CGPoint pos, int amount, uint64_t until);
static void HudAddKill(const char* name, uint64_t until);
static void HudAddEvent(const char* text, int kind, uint64_t until);
static void HudAddRadar(float x, float y, int team, bool dead);
static void HudSetAimLine(bool active, CGPoint target);
static void HudSetCrosshair(float gap, bool visible);
static void HudSetScope(bool active);
static void HudSampleFrame(void);

// RAGE FORWARD DECLS
// RageTick owns the whole rage pipeline and lives further down the file; espTick is the only
// place that already has gCached / g_localCamera / g_localSceneChar refreshed, so it is the
// single call site.
static void RageTick(void);
static void RageAutoScopeTick(void);
static void RageNoteHit(void);
static void RagePruneStats(void);
static bool RageMeleeGuard(float distance);
static void TriggerRageReload(void);
static void TriggerRageSwitchWeapon(int slot);

// LEGIT AIM FORWARD DECL
// Defined next to AnyAimModeActive (it needs the ballistics globals); called from the LEGIT tab.
static void LegitAimModeChanged(bool on);

// THIRD PERSON FORWARD DECL
// Applied at the tail of ApplyCameraOverrides, but defined after GetWeaponRenderersCached,
// which it needs to switch the local body's renderers back on.
static void ApplyThirdPerson(void* self, void* camera);

static std::atomic<bool> gCamFovEnabled{false};
static std::atomic<bool> gAspectEnabled{false};
static std::atomic<float> gCamFovVal{80.0f};
static std::atomic<float> gAspectVal{1.777f};

static std::atomic<bool> gViewmodelFovEnabled{false};
static std::atomic<float> gViewmodelFovVal{70.0f};

static std::atomic<bool> gNightModeEnabled{false};
static std::atomic<bool> gKillSoundEnabled{true};
static std::atomic<bool> gHitSoundEnabled{true};
static std::atomic<bool> gStreamMode{false};
static std::atomic<bool> gMenuOpen{false};
static std::atomic<bool> gAttached{false};

static std::atomic<bool> gSkyboxEnabled{false};
static std::atomic<uint32_t> gSkyboxColorHex{0xFFFFFFFF};
static std::atomic<bool> gSkyboxDirty{true};

// WORLD VIEW
static std::atomic<bool> gFullbrightEnabled{false};
static std::atomic<bool> gSnowEnabled{false};
static UIColor* gMenuAccent = nil;
static std::atomic<float> gMenuOpacity{1.0f};
static std::atomic<float> gMenuScale{1.0f};
static std::atomic<bool> gMenuBlurEnabled{true};
static std::atomic<float> gFullbrightMul{3.0f};
static std::atomic<bool> gNoFogEnabled{false};
static std::atomic<bool> gAmbientTintEnabled{false};
static std::atomic<uint32_t> gAmbientColorHex{0xFFFFFFFF};
static std::atomic<bool> gGradingDirty{true};
static std::atomic<float> gSaturationVal{0.0f};
static std::atomic<float> gContrastVal{0.0f};
static std::atomic<float> gGammaVal{0.0f};
static std::atomic<float> gBloomVal{0.0f};
static std::atomic<float> gSharpenVal{0.0f};
static std::atomic<bool> gMotionBlurEnabled{false};
static std::atomic<float> gMotionBlurAmount{0.45f};
static std::atomic<int> gFpsLimit{120};

// THIRD PERSON (visual only: the camera is pulled back, nothing about the player's aim,
// movement or hitboxes changes).
//
// The offset is applied at the very end of ApplyCameraOverrides, i.e. after the game's own
// LateUpdate has already placed the camera. Rendering happens after LateUpdate, so the write
// sticks for the frame. SceneLevelCamera.rot is never touched, which keeps the aim pipeline
// (LookAtTarget) and the crosshair-to-ray relationship exactly as the game left them.
static std::atomic<bool>  gTpEnabled{false};     // v_tp    master switch
static std::atomic<float> gTpDistance{2.6f};     // v_tpd   metres behind the eye
static std::atomic<float> gTpHeight{0.55f};      // v_tph   metres above the eye
static std::atomic<float> gTpShoulder{0.0f};     // v_tps   metres to the right of the eye
static std::atomic<bool>  gTpShowBody{true};     // v_tpb   force the local model renderers on
static std::atomic<float> gTpFov{0.0f};          // v_tpf   0 = leave the game FOV alone

// Renderer -> original enabled flag, so turning third person off restores first person.
static std::unordered_map<void*, bool> gTpRendererState;
static std::atomic<bool> gTpBodyApplied{false};

struct SavedLight {
    float i;
    UnityColor c;
};
static std::unordered_map<void*, SavedLight> gLightOrig;
static bool s_fogOrigInit = false;
static bool s_fogOrig = false;
static bool s_fbWas = false;
static bool s_ambWas = false;
static bool s_nfWas = false;

static void* p_renderSetAmbientLightMI = nullptr;
static void* p_renderGetAmbientLightMI = nullptr;
static fn_renderSetAmbientLight p_renderSetAmbientLight = nullptr;
static fn_renderGetAmbientLight p_renderGetAmbientLight = nullptr;
static UnityColor s_origAmbient{0.5f, 0.5f, 0.5f, 1.0f};
static bool s_origAmbientInit = false;

static std::atomic<bool> gChamsPlayerEnabled{false};
static std::atomic<bool> gChamsWeaponEnabled{false};
static std::atomic<bool> gChamsPlayerXray{false};
static std::atomic<bool> gChamsWeaponXray{false};
static std::atomic<uint32_t> gChamsPlayerColor{0xFF0000FF};
static std::atomic<uint32_t> gChamsWeaponColor{0xFF0000FF};
static std::atomic<int> gChamsPlayerMatType{0};
static std::atomic<int> gChamsWeaponMatType{0};
static std::atomic<bool> gChamsPlayerColorDirty{false};
static std::atomic<bool> gChamsWeaponColorDirty{false};

static std::atomic<uint64_t> g_lastLocalShotMs{0};
static int gLastLocalAmmo = -1;
static uint64_t g_lastHitSoundTime = 0;

static UIColor* gBoxColor = [UIColor redColor];
static UIColor* gSkelColor = [UIColor greenColor];
static UIColor* gNameColor = [UIColor whiteColor];
static UIColor* gTracerColor = [UIColor whiteColor];

static Vec3 g_localEye;
static Vec3 g_targetHead;
static Vec3 g_smoothTarget{};
static Vec3 g_aimOnFireSmoothTarget{};
static Vec3 g_silentAimTarget;
static std::atomic<uint32_t> g_silentAimSeq{0};
static std::atomic<bool> g_haveTarget{false};
static std::atomic<bool> g_silentAimActive{false};

static void* g_localCC = nullptr;
static void* g_localTransform = nullptr;
static void* g_localSceneChar = nullptr;
static void* g_localChar = nullptr;
static void* g_localCamera = nullptr;
static void* g_localCamTransform = nullptr;
static void* g_localWeapon = nullptr;
static void* g_prevLocalWeapon = nullptr;

static CGSize gScreenPts;
static CGFloat gScreenScale = 1.0;
static float gCurrentFps = 60.0f;

static float g_origMoveSpeed = -1.0f;
static float g_origJumpHeight = -1.0f;
static uint64_t gLastFrameTime = 0;

static void* gSampleMat = nullptr;
static uint32_t gSampleMatHandle = 0;
static void* gChamsMatsPlayer[6] = {nullptr, nullptr, nullptr, nullptr, nullptr, nullptr};
static void* gChamsMatsWeapon[6] = {nullptr, nullptr, nullptr, nullptr, nullptr, nullptr};

struct SavedMat {
    void* array;
    uint32_t handle;
};

static std::unordered_map<void*, SavedMat> gOrigMats;
static std::unordered_map<void*, SavedMat> gAppliedMats;
static std::unordered_map<void*, int> gLastEnemyHealth;
static std::unordered_map<void*, void*> gWeaponRenderersCache;

static bool gHandsBaseCaptured = false;
static Vec3 gHandsBaseScale(1,1,1);

static uint64_t gLastP = 0;
static uint64_t gLastNight = 0;
static uint64_t gLastWorld = 0;
static std::vector<void*> gCached;
static void* gLocal = nullptr;
static int gTeam = 0;

static inline void* methodPtr(void* mi) {
    return *(void**)(uintptr_t)mi;
}

static void* findClass(const char* ns, const char* name) {
    if (!p_domain_get || !p_domain_get_assemblies || !p_assembly_get_image || !p_class_from_name) {
        return nullptr;
    }
    size_t count = 0;
    void** assemblies = p_domain_get_assemblies(p_domain_get(), &count);
    if (!assemblies) {
        return nullptr;
    }
    
    // 1. Exact namespace first.
    for (size_t i = 0; i < count; ++i) {
        void* image = p_assembly_get_image(assemblies[i]);
        if (image) {
            void* k = p_class_from_name(image, ns, name);
            if (k) {
                return k;
            }
        }
    }
    
    // 2. The game keeps most gameplay types under the "Assets" namespace while the
    //    original mod used "" for everything. Try the common namespaces explicitly.
    const char* fallbacks[] = {
        "Assets",
        "Assets.Game.Scripts.Scenes.Game.Mono.Characters",
        ""
    };
    for (const char* fns : fallbacks) {
        if (!fns || (ns && strcmp(fns, ns) == 0)) {
            continue;
        }
        for (size_t i = 0; i < count; ++i) {
            void* image = p_assembly_get_image(assemblies[i]);
            if (image) {
                void* k = p_class_from_name(image, fns, name);
                if (k) {
                    return k;
                }
            }
        }
    }
    
    // 3. Last resort: walk every type in every image and compare the simple name.
    //    This ignores the namespace completely, so it works even if the game moves
    //    a class to another namespace in a future build.
    if (p_image_get_class_count && p_image_get_class && p_class_get_name) {
        for (size_t i = 0; i < count; ++i) {
            void* image = p_assembly_get_image(assemblies[i]);
            if (!image) {
                continue;
            }
            size_t typeCount = p_image_get_class_count(image);
            for (size_t t = 0; t < typeCount; ++t) {
                void* k = p_image_get_class(image, t);
                if (!k) {
                    continue;
                }
                const char* kn = p_class_get_name(k);
                if (kn && strcmp(kn, name) == 0) {
                    return k;
                }
            }
        }
    }
    
    return nullptr;
}

static inline bool alive(void* obj) {
    if (!obj || !SANE_PTR(obj)) {
        return false;
    }
    return *(void**)((uintptr_t)obj + off::kObjCachedPtr) != nullptr;
}

static bool getPosFast(void* transform, Vec3& out) {
    if (!alive(transform) || !p_tfGetPos) {
        return false;
    }
    out = p_tfGetPos(transform, p_tfGetPosMI);
    if (!Math::Finite(out)) {
        return false;
    }
    if (out.x == 0 && out.y == 0 && out.z == 0) {
        return false;
    }
    return true;
}

static bool w2sFast(void* camera, Vec3 worldPos, Vec3& out) {
    if (!alive(camera) || !p_camW2S) {
        return false;
    }
    out = p_camW2S(camera, worldPos, p_camW2SMI);
    return Math::Finite(out);
}

static NSString* getIL2CPPString(void* strObj) {
    @try {
        if (!SANE_PTR(strObj)) {
            return nil;
        }
        int len = *(int*)((uintptr_t)strObj + 0x10);
        if (len <= 0 || len > 128) {
            return nil;
        }
        return [[NSString alloc] initWithCharacters:(const unichar*)((uintptr_t)strObj + 0x14) length:len];
    } @catch (NSException* e) {
        return nil;
    }
}

// CONFIG
@interface ConfigManager : NSObject
@end

@implementation ConfigManager

+ (UIColor*)loadColorForKey:(NSString*)key defaultColor:(UIColor*)def {
    NSString* hex = [[NSUserDefaults standardUserDefaults] stringForKey:key];
    if (!hex || hex.length == 0) {
        return def ?: [UIColor whiteColor];
    }
    if ([hex hasPrefix:@"#"]) {
        hex = [hex substringFromIndex:1];
    }
    
    unsigned int r = 255, g = 255, b = 255, a = 255;
    if (hex.length == 8) {
        sscanf([hex UTF8String], "%02x%02x%02x%02x", &r, &g, &b, &a);
    } else if (hex.length == 6) {
        sscanf([hex UTF8String], "%02x%02x%02x", &r, &g, &b);
    } else {
        return def ?: [UIColor whiteColor];
    }
    
    return [UIColor colorWithRed:(r/255.0) green:(g/255.0) blue:(b/255.0) alpha:(a/255.0)];
}

+ (void)saveColor:(UIColor*)color forKey:(NSString*)key {
    if (!color || !key) {
        return;
    }
    CGFloat r, g, b, a;
    if ([color getRed:&r green:&g blue:&b alpha:&a]) {
        NSString* hex = SafeFmt(@"#%02x%02x%02x%02x", (int)(r*255), (int)(g*255), (int)(b*255), (int)(a*255));
        [[NSUserDefaults standardUserDefaults] setObject:hex forKey:key];
    }
}

+ (void)save {
    NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
    [d setBool:gEspEnabled forKey:@"e_e"];
    [d setBool:gSkeletonEnabled forKey:@"e_s"];
    [d setBool:gHealthBarEnabled forKey:@"e_h"];
    [d setBool:gNameEnabled forKey:@"e_n"];
    [d setBool:gTracersEnabled forKey:@"e_t"];
    [d setBool:gOofEnabled forKey:@"e_oof"];
    [d setBool:gAimbotEnabled forKey:@"a_e"];
    [d setBool:gAimOnFireEnabled forKey:@"a_of"];
    [d setInteger:gAimBone forKey:@"a_b"];
    [d setBool:gSilentAimEnabled forKey:@"a_s"];
    [d setBool:gHotAimbotEnabled forKey:@"h_ab"];
    [d setBool:gHotAimOnFireEnabled forKey:@"h_af"];
    [d setBool:gHotEspEnabled forKey:@"h_es"];
    [d setInteger:gAimbotFovPx forKey:@"a_f"];
    [d setBool:gPredictionEnabled forKey:@"a_p"];
    [d setFloat:gAimbotSmooth forKey:@"a_sm"];
    [d setFloat:gAimOnFireSmooth forKey:@"a_of_sm"];
    [d setBool:gAimbotVisibleOnly forKey:@"a_vo"];
    [d setBool:gAimbotNoTeam forKey:@"a_nt"];
    [d setBool:gSpeedHackEnabled forKey:@"m_sh"];
    [d setFloat:gSpeedHackVal forKey:@"m_shv"];
    [d setBool:gJumpHackEnabled forKey:@"m_jh"];
    [d setFloat:gJumpHackVal forKey:@"m_jhv"];
    [d setBool:gKillSoundEnabled forKey:@"s_k"];
    [d setBool:gHitSoundEnabled forKey:@"s_hit"];
    [d setBool:gCamFovEnabled forKey:@"c_f_e"];
    [d setFloat:gCamFovVal forKey:@"c_f_v"];
    [d setBool:gViewmodelFovEnabled forKey:@"c_vm_e"];
    [d setFloat:gViewmodelFovVal forKey:@"c_vm_v"];
    [d setBool:gAspectEnabled forKey:@"c_a_e"];
    [d setFloat:gAspectVal forKey:@"c_a_v"];
    [d setBool:gTpEnabled forKey:@"v_tp"];
    [d setFloat:gTpDistance forKey:@"v_tpd"];
    [d setFloat:gTpHeight forKey:@"v_tph"];
    [d setFloat:gTpShoulder forKey:@"v_tps"];
    [d setBool:gTpShowBody forKey:@"v_tpb"];
    [d setFloat:gTpFov forKey:@"v_tpf"];
    [d setBool:gRapidFireEnabled forKey:@"w_rf"];
    [d setBool:gInstantReloadEnabled forKey:@"w_ir"];
    [d setBool:gUnlimAmmoEnabled forKey:@"w_ua"];
    [d setBool:gNoSpreadEnabled forKey:@"w_ns"];
    [d setBool:gNoRecoilEnabled forKey:@"w_nr"];
    [d setBool:gBallisticsDebug forKey:@"b_dbg"];
    [d setBool:gSpreadFloorEnabled forKey:@"b_sfe"];
    [d setFloat:gSpreadFloor forKey:@"b_sf"];
    [d setBool:gHeadDotEnabled forKey:@"h_hd"];
    [d setBool:gDistanceEnabled forKey:@"h_dst"];
    [d setBool:gHealthTextEnabled forKey:@"h_hp"];
    [d setBool:gHitMarkerEnabled forKey:@"h_hm"];
    [d setBool:gDamageNumbersEnabled forKey:@"h_dn"];
    [d setInteger:gHitMarkerStyle forKey:@"h_hm_st"];
    [d setFloat:gHitMarkerSize forKey:@"h_hm_sz"];
    [d setInteger:gHitMarkerDuration forKey:@"h_hm_du"];
    [d setBool:gHitMarkerShowDamage forKey:@"h_hm_dm"];
    [d setFloat:gDamageNumberSize forKey:@"h_dn_sz"];
    [d setInteger:gDamageNumberDuration forKey:@"h_dn_du"];
    [d setFloat:gDamageNumberRise forKey:@"h_dn_ri"];
    [d setBool:gDamageNumberOutline forKey:@"h_dn_ol"];
    [d setBool:gRadarEnabled forKey:@"h_rad"];
    [d setBool:gCrosshairEnabled forKey:@"h_ch"];
    [d setBool:gScopeOverlayEnabled forKey:@"h_scope"];
    [d setBool:gAimLineEnabled forKey:@"h_al"];
    [d setBool:gTeamColorEnabled forKey:@"h_tc"];
    [d setBool:gVisibleColorEnabled forKey:@"h_vc"];
    [d setBool:gSnapBottomEnabled forKey:@"h_sb"];
    [d setBool:gKillFeedEnabled forKey:@"h_kf"];
    [d setInteger:gBoxStyle forKey:@"h_bs"];
    [d setFloat:gSkelThickness forKey:@"h_st"];
    [d setInteger:gRadarRange forKey:@"h_rr"];
    [d setFloat:gRadarSize forKey:@"h_rs"];
    [d setBool:gRadarRotate forKey:@"h_rrot"];
    [d setBool:gFpsEnabled forKey:@"h_fps"];
    [d setBool:gTriggerbotEnabled forKey:@"tb_e"];
    [d setInteger:gTriggerbotDelay forKey:@"tb_d"];
    [d setInteger:gTriggerbotFovPx forKey:@"tb_f"];
    [d setInteger:gTriggerbotHold forKey:@"tb_h"];
    [d setBool:gTriggerbotVisibleOnly forKey:@"tb_vo"];
    [d setBool:gTriggerbotTeamCheck forKey:@"tb_tc"];
    [d setBool:gTriggerbotScopeOnly forKey:@"tb_so"];
    [d setBool:gTriggerbotHeadOnly forKey:@"tb_ho"];
    [d setBool:gSkinChangerEnabled forKey:@"sk_e"];
    [d setObject:[NSString stringWithUTF8String:gSkinSelectedId.c_str()] forKey:@"sk_id"];
    [d setInteger:gCrosshairStyle forKey:@"ch_st"];
    [d setFloat:gCrosshairGap forKey:@"ch_g"];
    [d setFloat:gCrosshairLength forKey:@"ch_l"];
    [d setFloat:gCrosshairThickness forKey:@"ch_t"];
    [d setFloat:gCrosshairDot forKey:@"ch_d"];
    [d setBool:gCrosshairOutline forKey:@"ch_o"];
    [d setBool:gFovCircleEnabled forKey:@"fc_e"];
    [d setInteger:gFovCircleStyle forKey:@"fc_st"];
    [d setFloat:gFovCircleThickness forKey:@"fc_t"];
    [d setBool:gFovCircleFilled forKey:@"fc_f"];
    [d setFloat:gBoxThickness forKey:@"es_bt"];
    [d setInteger:gHealthBarStyle forKey:@"es_hbs"];
    [d setFloat:gHealthBarWidth forKey:@"es_hbw"];
    [d setInteger:gDistanceFormat forKey:@"es_df"];
    [d setBool:gDistanceAbove forKey:@"es_da"];
    [d setBool:gEspFadeEnabled forKey:@"es_fe"];
    [d setFloat:gEspFadeStart forKey:@"es_fs"];
    [d setFloat:gEspFadeEnd forKey:@"es_fend"];
    [d setFloat:gOofSize forKey:@"es_oofs"];
    [d setFloat:gOofThickness forKey:@"es_oofw"];
    [d setBool:gNameBgEnabled forKey:@"es_nbg"];
    [d setFloat:gHeadDotSize forKey:@"es_hds"];
    [d setBool:gWeaponEspEnabled forKey:@"es_wep"];
    [d setFloat:gWeaponEspThickness forKey:@"es_wepw"];
    [d setBool:gBoxFilled forKey:@"es_bf"];
    [d setFloat:gBoxFillAlpha forKey:@"es_bfa"];
    [d setBool:gEspHealthGradient forKey:@"es_hg"];
    [d setBool:gEspArmorBar forKey:@"es_ab"];
    [d setBool:gEspOffscreenArrows forKey:@"es_oa"];
    [d setFloat:gEspOffscreenMargin forKey:@"es_om"];
    [d setBool:gEspTeamFilter forKey:@"es_tf"];
    [d setBool:gEspDeadFilter forKey:@"es_df2"];
    [d setBool:gEspDistanceShadow forKey:@"es_ds"];
    [d setBool:gAimInfoEnabled forKey:@"ai_e"];
    [d setBool:gKeybindListEnabled forKey:@"kb_e"];
    [d setBool:gStatsPanelEnabled forKey:@"st_e"];
    [d setBool:gDamageLogEnabled forKey:@"dl_e"];
    [d setBool:gAimDrawTarget forKey:@"ai_t"];
    [d setBool:gAimDrawFov forKey:@"ai_f"];
    [d setFloat:gPredictionAmount forKey:@"a_pred"];
    [d setBool:gAimJitterEnabled forKey:@"a_jite"];
    [d setBool:gAimSwitchDelayEnabled forKey:@"a_swde"];
    [d setFloat:gEventLogX forKey:@"el_x"];
    [d setFloat:gEventLogY forKey:@"el_y"];
    [d setFloat:gStatsPanelX forKey:@"st_x"];
    [d setFloat:gStatsPanelY forKey:@"st_y"];
    [d setBool:gPanelBackground forKey:@"pn_bg"];
    [d setInteger:gTargetPriority forKey:@"cb_prio"];
    [d setBool:gVelocityGraphEnabled forKey:@"cb_vg"];
    [d setBool:gSessionInfoEnabled forKey:@"cb_si"];
    [d setBool:gDamageLogPanelEnabled forKey:@"cb_dlp"];
    [d setBool:gTargetListEnabled forKey:@"cb_tl"];
    [d setBool:gCrosshairDebugEnabled forKey:@"cb_cd"];
    [d setBool:gAmmoBarEnabled forKey:@"cb_ab"];
    [d setFloat:gRadarBlipSize forKey:@"h_rbs"];
    [d setFloat:gRadarOpacity forKey:@"h_rop"];
    [d setFloat:gBoxCornerLen forKey:@"es_bcl"];
    [d setInteger:gNameMaxLen forKey:@"es_nml"];
    [d setBool:gDamageStack forKey:@"h_dstack"];
    [d setBool:gSkeletonUpperOnly forKey:@"h_skuo"];
    [d setBool:gPlayerListEnabled forKey:@"pl_e"];
    [d setFloat:gPlayerListX forKey:@"pl_x"];
    [d setFloat:gPlayerListY forKey:@"pl_y"];
    [d setFloat:gPlayerListScale forKey:@"pl_s"];
    [d setInteger:gPlayerListMax forKey:@"pl_m"];
    [d setBool:gPlayerListHealth forKey:@"pl_h"];
    [d setBool:gPlayerListDistance forKey:@"pl_d"];
    [d setBool:gPlayerListTeam forKey:@"pl_t"];
    [d setBool:gPlayerListWeapon forKey:@"pl_w"];
    [d setBool:gPlayerListDead forKey:@"pl_dead"];
    [d setBool:gInfoPanelEnabled forKey:@"ip_e"];
    [d setFloat:gInfoPanelX forKey:@"ip_x"];
    [d setFloat:gInfoPanelY forKey:@"ip_y"];
    [d setBool:gInfoPanelHealth forKey:@"ip_h"];
    [d setBool:gInfoPanelAmmo forKey:@"ip_a"];
    [d setBool:gInfoPanelFps forKey:@"ip_f"];
    [d setBool:gInfoPanelSpeed forKey:@"ip_s"];
    [d setBool:gEventLogEnabled forKey:@"el_e"];
    [d setInteger:gEventLogMax forKey:@"el_m"];
    [d setFloat:gEventLogDuration forKey:@"el_d"];
    [d setBool:gWatermarkShowFps forKey:@"wm_f"];
    [d setBool:gWatermarkShowTime forKey:@"wm_t"];
    [d setBool:gWatermarkShowPlayers forKey:@"wm_p"];
    [d setFloat:gWatermarkScale forKey:@"wm_s"];
    [d setFloat:gWatermarkAlpha forKey:@"wm_a"];
    [d setFloat:gKillFeedDuration forKey:@"kf_d"];
    [d setInteger:gKillFeedMax forKey:@"kf_m"];
    [d setBool:gKillFeedShowKiller forKey:@"kf_k"];
    [d setFloat:gHitSoundPitch forKey:@"s_hp"];
    [d setFloat:gHitSoundVolume forKey:@"s_hv"];
    [d setFloat:gKillSoundPitch forKey:@"s_kp"];
    [d setFloat:gKillSoundVolume forKey:@"s_kv"];
    [d setFloat:gAimJitter forKey:@"a_jit"];
    [d setInteger:gAimSwitchDelay forKey:@"a_swd"];
    [d setBool:gNightModeEnabled forKey:@"v_nm"];
    [d setBool:gSkyboxEnabled forKey:@"v_sky_e"];
    [d setInteger:(NSInteger)gSkyboxColorHex.load() forKey:@"v_sky_c"];
    [d setBool:gFullbrightEnabled forKey:@"wv_fb"];
    [d setBool:gSnowEnabled forKey:@"wv_snow"];
    [d setFloat:gMenuOpacity forKey:@"m_op"];
    [d setFloat:gMenuScale forKey:@"m_sc"];
    [d setBool:gMenuBlurEnabled forKey:@"m_blur"];
    [d setFloat:gFullbrightMul forKey:@"wv_fbm"];
    [d setBool:gNoFogEnabled forKey:@"wv_nf"];
    [d setBool:gAmbientTintEnabled forKey:@"wv_amb_e"];
    [d setInteger:(NSInteger)gAmbientColorHex.load() forKey:@"wv_amb_c"];
    [d setFloat:gSaturationVal forKey:@"wv_sat"];
    [d setFloat:gContrastVal forKey:@"wv_con"];
    [d setFloat:gGammaVal forKey:@"wv_gam"];
    [d setFloat:gBloomVal forKey:@"wv_bloom"];
    [d setFloat:gSharpenVal forKey:@"wv_sharp"];
    [d setBool:gMotionBlurEnabled forKey:@"wv_mblur"];
    [d setFloat:gMotionBlurAmount forKey:@"wv_mblur_a"];
    [d setInteger:gFpsLimit forKey:@"wv_fps"];
    [d setBool:gChamsPlayerEnabled forKey:@"v_chams_pl_e"];
    [d setBool:gChamsWeaponEnabled forKey:@"v_chams_wep_e"];
    [d setBool:gChamsPlayerXray forKey:@"v_chams_pl_x"];
    [d setBool:gChamsWeaponXray forKey:@"v_chams_wep_x"];
    [d setInteger:(NSInteger)gChamsPlayerColor.load() forKey:@"v_chams_pl_c"];
    [d setInteger:(NSInteger)gChamsWeaponColor.load() forKey:@"v_chams_wep_c"];
    [d setInteger:gChamsPlayerMatType forKey:@"v_chams_pl_m"];
    [d setInteger:gChamsWeaponMatType forKey:@"v_chams_wep_m"];
    [ConfigManager saveColor:gBoxColor forKey:@"c_b"];
    [ConfigManager saveColor:gSkelColor forKey:@"c_s"];
    [ConfigManager saveColor:gNameColor forKey:@"c_n"];
    [ConfigManager saveColor:gTracerColor forKey:@"c_t"];
    [ConfigManager saveColor:gTeamColor forKey:@"c_team"];
    [ConfigManager saveColor:gVisibleColor forKey:@"c_vis"];
    [ConfigManager saveColor:gHiddenColor forKey:@"c_hid"];
    [ConfigManager saveColor:gHitMarkerColor forKey:@"c_hm"];
    [ConfigManager saveColor:gDamageNumberColor forKey:@"c_dn"];
    [ConfigManager saveColor:gRadarColor forKey:@"c_radar"];
    [ConfigManager saveColor:gCrosshairColor forKey:@"c_cross"];
    [ConfigManager saveColor:gFovCircleColor forKey:@"c_fov"];
    [ConfigManager saveColor:gPlayerListColor forKey:@"c_plist"];
    [ConfigManager saveColor:gEventLogColor forKey:@"c_elog"];
    [ConfigManager saveColor:gKillFeedColor forKey:@"c_kf"];
    [ConfigManager saveColor:gOofColor forKey:@"c_oof"];
    [ConfigManager saveColor:gWatermarkAccent forKey:@"c_wm"];
    [ConfigManager saveColor:gInfoPanelColor forKey:@"c_ip"];
    [ConfigManager saveColor:gWeaponEspColor forKey:@"c_wep"];
    [ConfigManager saveColor:gStatsColor forKey:@"c_stats"];
    [ConfigManager saveColor:gAimInfoColor forKey:@"c_ai"];
    [ConfigManager saveColor:gDamageLogColor forKey:@"c_dl"];
    
    // --- RAGE ---------------------------------------------------------------------------
    [d setBool:gRageEnabled forKey:@"rg_e"];
    [d setBool:gRageAutoAim forKey:@"rg_a"];
    [d setBool:gRageAutoFire forKey:@"rg_f"];
    [d setBool:gRageAutoScope forKey:@"rg_sc"];
    [d setBool:gRageAutoReload forKey:@"rg_r"];
    [d setBool:gRageAutoPistol forKey:@"rg_ap"];
    [d setBool:gRageAutoZeus forKey:@"rg_z"];
    [d setBool:gRageBurst forKey:@"rg_bst"];
    [d setBool:gRageAirStuck forKey:@"rg_air"];
    [d setBool:gRageAutoStop forKey:@"rg_ast"];
    [d setBool:gRageVisibleOnly forKey:@"rg_vo"];
    [d setBool:gRageTeamCheck forKey:@"rg_tc"];
    [d setBool:gRageBypassSmoke forKey:@"rg_smoke"];
    [d setBool:gRageIgnoreTeammatesInFov forKey:@"rg_itf"];
    [d setBool:gRageHitboxExpand forKey:@"rg_hbx"];
    [d setBool:gRageLogShots forKey:@"rg_log"];
    [d setBool:gRagePerTargetStats forKey:@"rg_pts"];
    [d setBool:gRageTeleport forKey:@"rg_tp"];
    [d setBool:gRageAntiAim forKey:@"rg_aa"];
    [d setBool:gRageAntiAimJitter forKey:@"rg_aaj"];
    [d setBool:gRageForceBaim forKey:@"rg_fb"];
    [d setBool:gRageOnKey forKey:@"rg_ok"];
    [d setBool:gRageDebug forKey:@"rg_dbg"];
    [d setInteger:gRageMinDamage forKey:@"rg_dmg"];
    [d setInteger:gRageHitchance forKey:@"rg_hc"];
    [d setInteger:gRagePriority forKey:@"rg_pri"];
    [d setInteger:gRagePoint forKey:@"rg_pt"];
    [d setInteger:gRageAntiAimMode forKey:@"rg_aam"];
    [d setInteger:gRageBurstCount forKey:@"rg_bc"];
    [d setInteger:gRageBurstPause forKey:@"rg_bp"];
    [d setInteger:gRageLogMax forKey:@"rg_logn"];
    [d setFloat:gRageFovPx forKey:@"rg_fov"];
    [d setFloat:gRageSmooth forKey:@"rg_sm"];
    [d setFloat:gRageSwitchDelay forKey:@"rg_swd"];
    [d setFloat:gRageFireDelay forKey:@"rg_fd"];
    [d setFloat:gRageSlowAim forKey:@"rg_sla"];
    [d setFloat:gRageMaxRange forKey:@"rg_mr"];
    [d setFloat:gRageAimStep forKey:@"rg_stp"];
    [d setFloat:gRageHitboxExpandPx forKey:@"rg_hbxp"];
    [d setFloat:gRageTeleportDist forKey:@"rg_tpd"];
    [d setFloat:gRageAntiAimYaw forKey:@"rg_aay"];
    [d setFloat:gRageAntiAimPitch forKey:@"rg_aap"];
    [d setFloat:gRageAntiAimSpin forKey:@"rg_aas"];
    [d synchronize];
}

+ (void)load {
    NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
    [d registerDefaults:@{
        @"rg_dmg": @1, @"rg_bc": @3, @"rg_bp": @140, @"rg_logn": @24,
        @"rg_fov": @600.0, @"rg_sm": @0.35, @"rg_swd": @120.0, @"rg_fd": @60.0,
        @"rg_mr": @300.0, @"rg_hbxp": @4.0, @"rg_tpd": @2.0,
        @"rg_aay": @180.0, @"rg_aap": @(-89.0), @"rg_aas": @720.0,
        @"m_shv": @1.0, @"m_jhv": @1.0,
        @"h_hm_sz": @10.0, @"h_hm_du": @260, @"h_dn_sz": @13.0,
        @"h_dn_du": @650, @"h_dn_ri": @32.0, @"h_st": @1.5,
        @"h_rr": @60, @"h_rs": @120.0, @"tb_d": @90, @"tb_f": @14, @"tb_h": @35,
        @"ch_g": @6.0, @"ch_l": @9.0, @"ch_t": @1.4, @"ch_d": @1.5,
        @"fc_t": @1.0, @"es_bt": @1.0, @"es_hbw": @2.0,
        @"es_fs": @40.0, @"es_fend": @140.0, @"es_oofs": @12.0, @"es_oofw": @2.0,
        @"es_hds": @2.5, @"es_wepw": @1.0, @"es_bfa": @0.12, @"es_om": @40.0,
        @"el_x": @12.0, @"el_y": @300.0, @"st_x": @12.0, @"st_y": @420.0,
        @"h_rbs": @2.5, @"h_rop": @0.38, @"es_bcl": @0.28, @"es_nml": @16,
        @"pl_x": @12.0, @"pl_y": @220.0, @"pl_s": @1.0, @"pl_m": @8,
        @"ip_x": @12.0, @"ip_y": @120.0, @"el_m": @6, @"el_d": @5000.0,
        @"wm_s": @1.0, @"wm_a": @0.95, @"kf_d": @6000.0, @"kf_m": @8,
        @"s_hp": @3000.0, @"s_hv": @0.8, @"s_kp": @1500.0, @"s_kv": @1.0,
        @"c_f_v": @80.0, @"c_a_v": @1.777, @"c_vm_v": @70.0,
        @"wv_fbm": @3.0, @"v_tpd": @2.6, @"v_tph": @0.55
    }];
    gEspEnabled = [d boolForKey:@"e_e"];
    gSkeletonEnabled = [d boolForKey:@"e_s"];
    gHealthBarEnabled = [d boolForKey:@"e_h"];
    gNameEnabled = [d boolForKey:@"e_n"];
    gTracersEnabled = [d boolForKey:@"e_t"];
    gOofEnabled = [d boolForKey:@"e_oof"];
    
    gAimbotEnabled = [d boolForKey:@"a_e"];
    gAimOnFireEnabled = [d boolForKey:@"a_of"];
    gAimBone = [d objectForKey:@"a_b"] ? (int)[d integerForKey:@"a_b"] : 10;
    if (gAimBone != 10 && gAimBone != 8 && gAimBone != 0) {
        gAimBone = 10;
    }
    
    gSilentAimEnabled = [d boolForKey:@"a_s"];
    gHotAimbotEnabled = [d boolForKey:@"h_ab"];
    gHotAimOnFireEnabled = [d boolForKey:@"h_af"];
    gHotEspEnabled = [d boolForKey:@"h_es"];
    gAimbotFovPx = (int)[d integerForKey:@"a_f"];
    if (gAimbotFovPx < 50) {
        gAimbotFovPx = 300;
    }
    
    gPredictionEnabled = [d boolForKey:@"a_p"];
    gAimbotSmooth = ClampFinite([d floatForKey:@"a_sm"], 0.0f, 1.0f, 0.0f);
    gAimOnFireSmooth = ClampFinite([d floatForKey:@"a_of_sm"], 0.0f, 1.0f, 0.0f);
    gAimbotVisibleOnly = [d boolForKey:@"a_vo"];
    gAimbotNoTeam = [d objectForKey:@"a_nt"] ? [d boolForKey:@"a_nt"] : true;
    
    gSpeedHackEnabled = [d boolForKey:@"m_sh"];
    gSpeedHackVal = ClampFinite([d floatForKey:@"m_shv"], 0.1f, 10.0f, 1.0f);
    if (gSpeedHackVal <= 0) {
        gSpeedHackVal = 1.0f;
    }
    
    gJumpHackEnabled = [d boolForKey:@"m_jh"];
    gJumpHackVal = ClampFinite([d floatForKey:@"m_jhv"], 0.1f, 10.0f, 1.0f);
    if (gJumpHackVal <= 0) {
        gJumpHackVal = 1.0f;
    }
    
    if ([d objectForKey:@"s_k"]) {
        gKillSoundEnabled = [d boolForKey:@"s_k"];
    }
    if ([d objectForKey:@"s_hit"]) {
        gHitSoundEnabled = [d boolForKey:@"s_hit"];
    }
    
    gCamFovEnabled = [d boolForKey:@"c_f_e"];
    gCamFovVal = [d floatForKey:@"c_f_v"];
    if (!std::isfinite(gCamFovVal) || gCamFovVal <= 0) {
        gCamFovVal = 80.0f;
    }
    
    gViewmodelFovEnabled = [d boolForKey:@"c_vm_e"];
    gViewmodelFovVal = [d floatForKey:@"c_vm_v"];
    if (!std::isfinite(gViewmodelFovVal) || gViewmodelFovVal <= 0) {
        gViewmodelFovVal = 70.0f;
    }
    
    gAspectEnabled = [d boolForKey:@"c_a_e"];
    gAspectVal = [d floatForKey:@"c_a_v"];
    if (!std::isfinite(gAspectVal) || gAspectVal <= 0) {
        gAspectVal = 1.777f;
    }
    
    gTpEnabled = [d boolForKey:@"v_tp"];
    gTpDistance = [d floatForKey:@"v_tpd"];
    if (!std::isfinite(gTpDistance) || gTpDistance < 0.3f) {
        gTpDistance = 2.6f;
    }
    gTpHeight = [d floatForKey:@"v_tph"];
    if (!std::isfinite(gTpHeight)) {
        gTpHeight = 0.55f;
    }
    gTpShoulder = [d floatForKey:@"v_tps"];
    if (!std::isfinite(gTpShoulder)) {
        gTpShoulder = 0.0f;
    }
    gTpShowBody = [d objectForKey:@"v_tpb"] ? [d boolForKey:@"v_tpb"] : true;
    gTpFov = [d floatForKey:@"v_tpf"];
    if (!std::isfinite(gTpFov) || gTpFov < 0.0f) {
        gTpFov = 0.0f;
    }
    
    gRapidFireEnabled = [d boolForKey:@"w_rf"];
    gInstantReloadEnabled = [d boolForKey:@"w_ir"];
    gUnlimAmmoEnabled = [d boolForKey:@"w_ua"];
    gNoSpreadEnabled = [d boolForKey:@"w_ns"];
    gNoRecoilEnabled = [d boolForKey:@"w_nr"];
    gBallisticsDebug = [d boolForKey:@"b_dbg"];
    gSpreadFloorEnabled = [d boolForKey:@"b_sfe"];
    gSpreadFloor = ClampFinite([d floatForKey:@"b_sf"], 0.0f, 0.05f, 0.0f);
    gHeadDotEnabled = [d objectForKey:@"h_hd"] ? [d boolForKey:@"h_hd"] : true;
    gDistanceEnabled = [d objectForKey:@"h_dst"] ? [d boolForKey:@"h_dst"] : true;
    gHealthTextEnabled = [d boolForKey:@"h_hp"];
    gHitMarkerEnabled = [d objectForKey:@"h_hm"] ? [d boolForKey:@"h_hm"] : true;
    gDamageNumbersEnabled = [d objectForKey:@"h_dn"] ? [d boolForKey:@"h_dn"] : true;
    gHitMarkerStyle = (int)[d integerForKey:@"h_hm_st"];
    if (gHitMarkerStyle < 0 || gHitMarkerStyle > 2) {
        gHitMarkerStyle = 0;
    }
    gHitMarkerSize = ClampFinite([d floatForKey:@"h_hm_sz"], 6.0f, 26.0f, 10.0f);
    gHitMarkerDuration = (int)ClampFinite([d floatForKey:@"h_hm_du"], 100.0f, 800.0f, 260.0f);
    gHitMarkerShowDamage = [d boolForKey:@"h_hm_dm"];
    gDamageNumberSize = ClampFinite([d floatForKey:@"h_dn_sz"], 9.0f, 28.0f, 13.0f);
    gDamageNumberDuration = (int)ClampFinite([d floatForKey:@"h_dn_du"], 250.0f, 2500.0f, 650.0f);
    gDamageNumberRise = ClampFinite([d floatForKey:@"h_dn_ri"], 0.0f, 80.0f, 32.0f);
    gDamageNumberOutline = [d objectForKey:@"h_dn_ol"] ? [d boolForKey:@"h_dn_ol"] : true;
    gRadarEnabled = [d boolForKey:@"h_rad"];
    gCrosshairEnabled = [d boolForKey:@"h_ch"];
    gScopeOverlayEnabled = [d boolForKey:@"h_scope"];
    gAimLineEnabled = [d boolForKey:@"h_al"];
    gTeamColorEnabled = [d objectForKey:@"h_tc"] ? [d boolForKey:@"h_tc"] : false;
    gVisibleColorEnabled = [d objectForKey:@"h_vc"] ? [d boolForKey:@"h_vc"] : false;
    gSnapBottomEnabled = [d boolForKey:@"h_sb"];
    gKillFeedEnabled = [d objectForKey:@"h_kf"] ? [d boolForKey:@"h_kf"] : true;
    gBoxStyle = (int)[d integerForKey:@"h_bs"];
    gSkelThickness = ClampFinite([d floatForKey:@"h_st"], 0.5f, 4.0f, 1.5f);
    gRadarRange = (int)[d integerForKey:@"h_rr"];
    if (gRadarRange < 20) {
        gRadarRange = 60;
    }
    gRadarSize = ClampFinite([d floatForKey:@"h_rs"], 70.0f, 220.0f, 120.0f);
    gRadarRotate = [d objectForKey:@"h_rrot"] ? [d boolForKey:@"h_rrot"] : true;
    gFpsEnabled = [d objectForKey:@"h_fps"] ? [d boolForKey:@"h_fps"] : true;
    gTriggerbotEnabled = [d boolForKey:@"tb_e"];
    gTriggerbotDelay = (int)ClampFinite([d floatForKey:@"tb_d"], 20.0f, 500.0f, 90.0f);
    gTriggerbotFovPx = (int)ClampFinite([d floatForKey:@"tb_f"], 2.0f, 80.0f, 14.0f);
    gTriggerbotHold = (int)ClampFinite([d floatForKey:@"tb_h"], 10.0f, 200.0f, 35.0f);
    gTriggerbotVisibleOnly = [d objectForKey:@"tb_vo"] ? [d boolForKey:@"tb_vo"] : true;
    gTriggerbotTeamCheck = [d objectForKey:@"tb_tc"] ? [d boolForKey:@"tb_tc"] : true;
    gTriggerbotScopeOnly = [d boolForKey:@"tb_so"];
    gTriggerbotHeadOnly = [d boolForKey:@"tb_ho"];
    gSkinChangerEnabled = [d boolForKey:@"sk_e"];
    NSString* savedSkinId = [d stringForKey:@"sk_id"];
    gSkinPendingId = savedSkinId ? std::string([savedSkinId UTF8String]) : std::string();
    gCrosshairStyle = (int)[d integerForKey:@"ch_st"];
    if (gCrosshairStyle < 0 || gCrosshairStyle > 4) {
        gCrosshairStyle = 0;
    }
    gCrosshairGap = ClampFinite([d floatForKey:@"ch_g"], 0.0f, 60.0f, 6.0f);
    gCrosshairLength = ClampFinite([d floatForKey:@"ch_l"], 2.0f, 40.0f, 9.0f);
    gCrosshairThickness = ClampFinite([d floatForKey:@"ch_t"], 0.5f, 5.0f, 1.4f);
    gCrosshairDot = ClampFinite([d floatForKey:@"ch_d"], 0.0f, 6.0f, 1.5f);
    gCrosshairOutline = [d objectForKey:@"ch_o"] ? [d boolForKey:@"ch_o"] : true;
    gFovCircleEnabled = [d objectForKey:@"fc_e"] ? [d boolForKey:@"fc_e"] : true;
    gFovCircleStyle = (int)[d integerForKey:@"fc_st"];
    if (gFovCircleStyle < 0 || gFovCircleStyle > 2) {
        gFovCircleStyle = 0;
    }
    gFovCircleThickness = ClampFinite([d floatForKey:@"fc_t"], 0.5f, 5.0f, 1.0f);
    gFovCircleFilled = [d boolForKey:@"fc_f"];
    gBoxThickness = ClampFinite([d floatForKey:@"es_bt"], 0.5f, 5.0f, 1.0f);
    gHealthBarStyle = (int)[d integerForKey:@"es_hbs"];
    if (gHealthBarStyle < 0 || gHealthBarStyle > 2) {
        gHealthBarStyle = 0;
    }
    gHealthBarWidth = ClampFinite([d floatForKey:@"es_hbw"], 1.0f, 6.0f, 2.0f);
    gDistanceFormat = (int)[d integerForKey:@"es_df"];
    if (gDistanceFormat < 0 || gDistanceFormat > 1) {
        gDistanceFormat = 0;
    }
    gDistanceAbove = [d boolForKey:@"es_da"];
    gEspFadeEnabled = [d boolForKey:@"es_fe"];
    gEspFadeStart = ClampFinite([d floatForKey:@"es_fs"], 5.0f, 200.0f, 40.0f);
    gEspFadeEnd = ClampFinite([d floatForKey:@"es_fend"], 10.0f, 400.0f, 140.0f);
    if (gEspFadeEnd <= gEspFadeStart) {
        gEspFadeEnd = gEspFadeStart + 20.0f;
    }
    gOofSize = ClampFinite([d floatForKey:@"es_oofs"], 4.0f, 30.0f, 12.0f);
    gOofThickness = ClampFinite([d floatForKey:@"es_oofw"], 0.5f, 6.0f, 2.0f);
    gNameBgEnabled = [d objectForKey:@"es_nbg"] ? [d boolForKey:@"es_nbg"] : true;
    gHeadDotSize = ClampFinite([d floatForKey:@"es_hds"], 1.0f, 8.0f, 2.5f);
    gWeaponEspEnabled = [d boolForKey:@"es_wep"];
    gWeaponEspThickness = ClampFinite([d floatForKey:@"es_wepw"], 0.5f, 4.0f, 1.0f);
    gBoxFilled = [d boolForKey:@"es_bf"];
    gBoxFillAlpha = ClampFinite([d floatForKey:@"es_bfa"], 0.02f, 0.5f, 0.12f);
    gEspHealthGradient = [d objectForKey:@"es_hg"] ? [d boolForKey:@"es_hg"] : true;
    gEspArmorBar = [d objectForKey:@"es_ab"] ? [d boolForKey:@"es_ab"] : true;
    gEspOffscreenArrows = [d objectForKey:@"es_oa"] ? [d boolForKey:@"es_oa"] : true;
    gEspOffscreenMargin = ClampFinite([d floatForKey:@"es_om"], 10.0f, 120.0f, 40.0f);
    gEspTeamFilter = [d boolForKey:@"es_tf"];
    gEspDeadFilter = [d boolForKey:@"es_df2"];
    gEspDistanceShadow = [d objectForKey:@"es_ds"] ? [d boolForKey:@"es_ds"] : true;
    gAimInfoEnabled = [d boolForKey:@"ai_e"];
    gKeybindListEnabled = [d boolForKey:@"kb_e"];
    gStatsPanelEnabled = [d boolForKey:@"st_e"];
    gDamageLogEnabled = [d boolForKey:@"dl_e"];
    gAimDrawTarget = [d objectForKey:@"ai_t"] ? [d boolForKey:@"ai_t"] : true;
    gAimDrawFov = [d objectForKey:@"ai_f"] ? [d boolForKey:@"ai_f"] : true;
    gPredictionAmount = ClampFinite([d floatForKey:@"a_pred"], 0.0f, 1.0f, 0.0f);
    gAimJitterEnabled = [d boolForKey:@"a_jite"];
    gAimSwitchDelayEnabled = [d boolForKey:@"a_swde"];
    gEventLogX = ClampFinite([d floatForKey:@"el_x"], 0.0f, 1000.0f, 12.0f);
    gEventLogY = ClampFinite([d floatForKey:@"el_y"], 0.0f, 1000.0f, 300.0f);
    gStatsPanelX = ClampFinite([d floatForKey:@"st_x"], 0.0f, 1000.0f, 12.0f);
    gStatsPanelY = ClampFinite([d floatForKey:@"st_y"], 0.0f, 1000.0f, 420.0f);
    gPanelBackground = [d objectForKey:@"pn_bg"] ? [d boolForKey:@"pn_bg"] : true;
    gTargetPriority = (int)[d integerForKey:@"cb_prio"];
    if (gTargetPriority < 0 || gTargetPriority > 2) {
        gTargetPriority = 0;
    }
    gVelocityGraphEnabled = [d boolForKey:@"cb_vg"];
    gSessionInfoEnabled = [d boolForKey:@"cb_si"];
    gDamageLogPanelEnabled = [d boolForKey:@"cb_dlp"];
    gTargetListEnabled = [d boolForKey:@"cb_tl"];
    gCrosshairDebugEnabled = [d boolForKey:@"cb_cd"];
    gAmmoBarEnabled = [d boolForKey:@"cb_ab"];
    gRadarBlipSize = ClampFinite([d floatForKey:@"h_rbs"], 1.0f, 8.0f, 2.5f);
    gRadarOpacity = ClampFinite([d floatForKey:@"h_rop"], 0.05f, 0.9f, 0.38f);
    gBoxCornerLen = ClampFinite([d floatForKey:@"es_bcl"], 0.1f, 0.5f, 0.28f);
    gNameMaxLen = (int)ClampFinite([d floatForKey:@"es_nml"], 4.0f, 32.0f, 16.0f);
    gDamageStack = [d objectForKey:@"h_dstack"] ? [d boolForKey:@"h_dstack"] :
                   ([d objectForKey:@"h_dst"] ? [d boolForKey:@"h_dst"] : true);
    gSkeletonUpperOnly = [d boolForKey:@"h_skuo"];
    gPlayerListEnabled = [d boolForKey:@"pl_e"];
    gPlayerListX = ClampFinite([d floatForKey:@"pl_x"], 0.0f, 1000.0f, 12.0f);
    gPlayerListY = ClampFinite([d floatForKey:@"pl_y"], 0.0f, 1000.0f, 220.0f);
    gPlayerListScale = ClampFinite([d floatForKey:@"pl_s"], 0.6f, 2.0f, 1.0f);
    gPlayerListMax = (int)ClampFinite([d floatForKey:@"pl_m"], 1.0f, 16.0f, 8.0f);
    gPlayerListHealth = [d objectForKey:@"pl_h"] ? [d boolForKey:@"pl_h"] : true;
    gPlayerListDistance = [d objectForKey:@"pl_d"] ? [d boolForKey:@"pl_d"] : true;
    gPlayerListTeam = [d objectForKey:@"pl_t"] ? [d boolForKey:@"pl_t"] : true;
    gPlayerListWeapon = [d objectForKey:@"pl_w"] ? [d boolForKey:@"pl_w"] : true;
    gPlayerListDead = [d boolForKey:@"pl_dead"];
    gInfoPanelEnabled = [d boolForKey:@"ip_e"];
    gInfoPanelX = ClampFinite([d floatForKey:@"ip_x"], 0.0f, 1000.0f, 12.0f);
    gInfoPanelY = ClampFinite([d floatForKey:@"ip_y"], 0.0f, 1000.0f, 120.0f);
    gInfoPanelHealth = [d objectForKey:@"ip_h"] ? [d boolForKey:@"ip_h"] : true;
    gInfoPanelAmmo = [d objectForKey:@"ip_a"] ? [d boolForKey:@"ip_a"] : true;
    gInfoPanelFps = [d objectForKey:@"ip_f"] ? [d boolForKey:@"ip_f"] : true;
    gInfoPanelSpeed = [d objectForKey:@"ip_s"] ? [d boolForKey:@"ip_s"] : true;
    gEventLogEnabled = [d boolForKey:@"el_e"];
    gEventLogMax = (int)ClampFinite([d floatForKey:@"el_m"], 1.0f, 12.0f, 6.0f);
    gEventLogDuration = ClampFinite([d floatForKey:@"el_d"], 1000.0f, 15000.0f, 5000.0f);
    gWatermarkShowFps = [d objectForKey:@"wm_f"] ? [d boolForKey:@"wm_f"] : true;
    gWatermarkShowTime = [d objectForKey:@"wm_t"] ? [d boolForKey:@"wm_t"] : true;
    gWatermarkShowPlayers = [d objectForKey:@"wm_p"] ? [d boolForKey:@"wm_p"] : true;
    gWatermarkScale = ClampFinite([d floatForKey:@"wm_s"], 0.6f, 1.8f, 1.0f);
    gWatermarkAlpha = ClampFinite([d floatForKey:@"wm_a"], 0.3f, 1.0f, 0.95f);
    gKillFeedDuration = ClampFinite([d floatForKey:@"kf_d"], 1500.0f, 15000.0f, 6000.0f);
    gKillFeedMax = (int)ClampFinite([d floatForKey:@"kf_m"], 1.0f, 16.0f, 8.0f);
    gKillFeedShowKiller = [d objectForKey:@"kf_k"] ? [d boolForKey:@"kf_k"] : true;
    gHitSoundPitch = ClampFinite([d floatForKey:@"s_hp"], 200.0f, 6000.0f, 3000.0f);
    gHitSoundVolume = ClampFinite([d floatForKey:@"s_hv"], 0.0f, 1.0f, 0.8f);
    gKillSoundPitch = ClampFinite([d floatForKey:@"s_kp"], 200.0f, 6000.0f, 1500.0f);
    gKillSoundVolume = ClampFinite([d floatForKey:@"s_kv"], 0.0f, 1.0f, 1.0f);
    gAimJitter = ClampFinite([d floatForKey:@"a_jit"], 0.0f, 5.0f, 0.0f);
    gAimSwitchDelay = (int)ClampFinite([d floatForKey:@"a_swd"], 0.0f, 800.0f, 0.0f);
    
    gNightModeEnabled = [d boolForKey:@"v_nm"];
    gSkyboxEnabled = [d boolForKey:@"v_sky_e"];
    gSkyboxColorHex = (uint32_t)[d integerForKey:@"v_sky_c"];
    if (gSkyboxColorHex == 0) {
        gSkyboxColorHex = 0xFFFFFFFF;
    }
    gSkyboxDirty = true;
    
    gFullbrightEnabled = [d boolForKey:@"wv_fb"];
    gSnowEnabled = [d boolForKey:@"wv_snow"];
    gMenuOpacity = ClampFinite([d floatForKey:@"m_op"], 0.5f, 1.0f, 1.0f);
    gMenuScale = ClampFinite([d floatForKey:@"m_sc"], 0.8f, 1.2f, 1.0f);
    gMenuBlurEnabled = [d objectForKey:@"m_blur"] ? [d boolForKey:@"m_blur"] : true;
    gMenuAccent = [ConfigManager loadColorForKey:@"m_accent" defaultColor:nil];
    gFullbrightMul = ClampFinite([d floatForKey:@"wv_fbm"], 1.0f, 20.0f, 3.0f);
    gNoFogEnabled = [d boolForKey:@"wv_nf"];
    gAmbientTintEnabled = [d boolForKey:@"wv_amb_e"];
    gAmbientColorHex = (uint32_t)[d integerForKey:@"wv_amb_c"];
    if (gAmbientColorHex == 0) {
        gAmbientColorHex = 0xFFFFFFFF;
    }
    gSaturationVal = ClampFinite([d floatForKey:@"wv_sat"], -1.0f, 1.0f, 0.0f);
    gContrastVal = ClampFinite([d floatForKey:@"wv_con"], -1.0f, 1.0f, 0.0f);
    gGammaVal = ClampFinite([d floatForKey:@"wv_gam"], -1.0f, 1.0f, 0.0f);
    gBloomVal = ClampFinite([d floatForKey:@"wv_bloom"], 0.0f, 5.0f, 0.0f);
    gSharpenVal = ClampFinite([d floatForKey:@"wv_sharp"], 0.0f, 5.0f, 0.0f);
    gMotionBlurEnabled = [d boolForKey:@"wv_mblur"];
    gMotionBlurAmount = ClampFinite([d floatForKey:@"wv_mblur_a"], 0.0f, 1.0f, 0.45f);
    gFpsLimit = (int)ClampFinite([d floatForKey:@"wv_fps"], 30.0f, 144.0f, 120.0f);
    gGradingDirty = true;
    
    gChamsPlayerEnabled = [d boolForKey:@"v_chams_pl_e"];
    gChamsWeaponEnabled = [d boolForKey:@"v_chams_wep_e"];
    gChamsPlayerXray = [d boolForKey:@"v_chams_pl_x"];
    gChamsWeaponXray = [d boolForKey:@"v_chams_wep_x"];
    gChamsPlayerColor = (uint32_t)[d integerForKey:@"v_chams_pl_c"];
    gChamsWeaponColor = (uint32_t)[d integerForKey:@"v_chams_wep_c"];
    
    if (gChamsPlayerColor == 0) {
        gChamsPlayerColor = 0xFF0000FF;
    }
    if (gChamsWeaponColor == 0) {
        gChamsWeaponColor = 0xFF0000FF;
    }
    
    gChamsPlayerMatType = (int)[d integerForKey:@"v_chams_pl_m"];
    gChamsWeaponMatType = (int)[d integerForKey:@"v_chams_wep_m"];
    if (gChamsPlayerMatType < 0 || gChamsPlayerMatType > 3) {
        gChamsPlayerMatType = 0;
    }
    if (gChamsWeaponMatType < 0 || gChamsWeaponMatType > 3) {
        gChamsWeaponMatType = 0;
    }
    
    gBoxColor = [ConfigManager loadColorForKey:@"c_b" defaultColor:[UIColor redColor]];
    gSkelColor = [ConfigManager loadColorForKey:@"c_s" defaultColor:[UIColor greenColor]];
    gNameColor = [ConfigManager loadColorForKey:@"c_n" defaultColor:[UIColor whiteColor]];
    gTracerColor = [ConfigManager loadColorForKey:@"c_t" defaultColor:[UIColor whiteColor]];
    gTeamColor = [ConfigManager loadColorForKey:@"c_team" defaultColor:[UIColor cyanColor]];
    gVisibleColor = [ConfigManager loadColorForKey:@"c_vis" defaultColor:[UIColor greenColor]];
    gHiddenColor = [ConfigManager loadColorForKey:@"c_hid" defaultColor:[UIColor redColor]];
    gHitMarkerColor = [ConfigManager loadColorForKey:@"c_hm" defaultColor:[UIColor whiteColor]];
    gDamageNumberColor = [ConfigManager loadColorForKey:@"c_dn" defaultColor:[UIColor colorWithRed:1.0 green:0.75 blue:0.1 alpha:1.0]];
    gRadarColor = [ConfigManager loadColorForKey:@"c_radar" defaultColor:[UIColor greenColor]];
    gCrosshairColor = [ConfigManager loadColorForKey:@"c_cross" defaultColor:[UIColor whiteColor]];
    gFovCircleColor = [ConfigManager loadColorForKey:@"c_fov" defaultColor:[UIColor whiteColor]];
    gPlayerListColor = [ConfigManager loadColorForKey:@"c_plist" defaultColor:[UIColor whiteColor]];
    gEventLogColor = [ConfigManager loadColorForKey:@"c_elog" defaultColor:[UIColor colorWithRed:0.7 green:0.85 blue:1.0 alpha:1.0]];
    gKillFeedColor = [ConfigManager loadColorForKey:@"c_kf" defaultColor:[UIColor colorWithRed:1.0 green:0.35 blue:0.35 alpha:1.0]];
    gOofColor = [ConfigManager loadColorForKey:@"c_oof" defaultColor:[UIColor whiteColor]];
    gWatermarkAccent = [ConfigManager loadColorForKey:@"c_wm" defaultColor:[UIColor colorWithRed:0.45 green:0.35 blue:0.95 alpha:1.0]];
    gInfoPanelColor = [ConfigManager loadColorForKey:@"c_ip" defaultColor:[UIColor whiteColor]];
    gWeaponEspColor = [ConfigManager loadColorForKey:@"c_wep" defaultColor:[UIColor colorWithRed:1.0 green:0.6 blue:0.2 alpha:1.0]];
    gStatsColor = [ConfigManager loadColorForKey:@"c_stats" defaultColor:[UIColor whiteColor]];
    gAimInfoColor = [ConfigManager loadColorForKey:@"c_ai" defaultColor:[UIColor colorWithRed:0.9 green:0.3 blue:0.9 alpha:1.0]];
    gDamageLogColor = [ConfigManager loadColorForKey:@"c_dl" defaultColor:[UIColor colorWithRed:1.0 green:0.5 blue:0.5 alpha:1.0]];
    
    // --- RAGE ---------------------------------------------------------------------------
    // Every flag uses the "was it written" test so a fresh install keeps the default
    // baked into the global instead of silently turning everything off.
    gRageEnabled = [d objectForKey:@"rg_e"] ? [d boolForKey:@"rg_e"] : false;
    gRageAutoAim = [d objectForKey:@"rg_a"] ? [d boolForKey:@"rg_a"] : true;
    gRageAutoFire = [d boolForKey:@"rg_f"];
    gRageAutoScope = [d boolForKey:@"rg_sc"];
    gRageAutoReload = [d objectForKey:@"rg_r"] ? [d boolForKey:@"rg_r"] : true;
    gRageAutoPistol = [d boolForKey:@"rg_ap"];
    gRageAutoZeus = [d boolForKey:@"rg_z"];
    gRageBurst = [d boolForKey:@"rg_bst"];
    gRageAirStuck = [d boolForKey:@"rg_air"];
    gRageAutoStop = [d boolForKey:@"rg_ast"];
    gRageVisibleOnly = [d objectForKey:@"rg_vo"] ? [d boolForKey:@"rg_vo"] : true;
    gRageTeamCheck = [d objectForKey:@"rg_tc"] ? [d boolForKey:@"rg_tc"] : true;
    gRageBypassSmoke = [d boolForKey:@"rg_smoke"];
    gRageIgnoreTeammatesInFov = [d objectForKey:@"rg_itf"] ? [d boolForKey:@"rg_itf"] : true;
    gRageHitboxExpand = [d boolForKey:@"rg_hbx"];
    gRageLogShots = [d boolForKey:@"rg_log"];
    gRagePerTargetStats = [d boolForKey:@"rg_pts"];
    gRageTeleport = [d boolForKey:@"rg_tp"];
    gRageAntiAim = [d boolForKey:@"rg_aa"];
    gRageAntiAimJitter = [d boolForKey:@"rg_aaj"];
    gRageForceBaim = [d boolForKey:@"rg_fb"];
    gRageOnKey = [d boolForKey:@"rg_ok"];
    gRageDebug = [d boolForKey:@"rg_dbg"];
    
    gRageMinDamage = (int)ClampFinite([d floatForKey:@"rg_dmg"], 1.0f, 200.0f, 1.0f);
    gRageHitchance = (int)ClampFinite([d floatForKey:@"rg_hc"], 0.0f, 100.0f, 0.0f);
    gRagePriority = (int)ClampFinite([d floatForKey:@"rg_pri"], 0.0f, 3.0f, 0.0f);
    gRagePoint = (int)ClampFinite([d floatForKey:@"rg_pt"], 0.0f, 3.0f, 0.0f);
    gRageAntiAimMode = (int)ClampFinite([d floatForKey:@"rg_aam"], 0.0f, 3.0f, 0.0f);
    gRageBurstCount = (int)ClampFinite([d floatForKey:@"rg_bc"], 1.0f, 12.0f, 3.0f);
    gRageBurstPause = (int)ClampFinite([d floatForKey:@"rg_bp"], 20.0f, 2000.0f, 140.0f);
    gRageLogMax = (int)ClampFinite([d floatForKey:@"rg_logn"], 4.0f, 64.0f, 24.0f);
    
    gRageFovPx = ClampFinite([d floatForKey:@"rg_fov"], 40.0f, 2000.0f, 600.0f);
    gRageSmooth = ClampFinite([d floatForKey:@"rg_sm"], 0.0f, 0.98f, 0.35f);
    gRageSwitchDelay = ClampFinite([d floatForKey:@"rg_swd"], 0.0f, 2000.0f, 120.0f);
    gRageFireDelay = ClampFinite([d floatForKey:@"rg_fd"], 0.0f, 2000.0f, 60.0f);
    gRageSlowAim = ClampFinite([d floatForKey:@"rg_sla"], 0.0f, 500.0f, 0.0f);
    gRageMaxRange = ClampFinite([d floatForKey:@"rg_mr"], 10.0f, 600.0f, 300.0f);
    gRageAimStep = ClampFinite([d floatForKey:@"rg_stp"], 0.0f, 32.0f, 0.0f);
    gRageHitboxExpandPx = ClampFinite([d floatForKey:@"rg_hbxp"], 0.0f, 40.0f, 4.0f);
    gRageTeleportDist = ClampFinite([d floatForKey:@"rg_tpd"], 0.5f, 10.0f, 2.0f);
    gRageAntiAimYaw = ClampFinite([d floatForKey:@"rg_aay"], -180.0f, 180.0f, 180.0f);
    gRageAntiAimPitch = ClampFinite([d floatForKey:@"rg_aap"], -89.0f, 89.0f, -89.0f);
    gRageAntiAimSpin = ClampFinite([d floatForKey:@"rg_aas"], 0.0f, 3600.0f, 720.0f);
}

@end

// CONFIG SLOTS — snapshot the whole NSUserDefaults dictionary under cfg_slot_N.
static void ConfigSaveSlot(int slot) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSDictionary *all = [d dictionaryRepresentation];
    [d setObject:all forKey:[NSString stringWithFormat:@"cfg_slot_%d", slot]];
    [d synchronize];
}

static void ConfigLoadSlot(int slot) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSDictionary *all = [d dictionaryForKey:[NSString stringWithFormat:@"cfg_slot_%d", slot]];
    if (!all) {
        return;
    }
    for (NSString *k in all) {
        if ([k hasPrefix:@"cfg_slot_"]) {
            continue;
        }
        [d setObject:all[k] forKey:k];
    }
    [d synchronize];
    [ConfigManager load];
}

static void ConfigDeleteSlot(int slot) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d removeObjectForKey:[NSString stringWithFormat:@"cfg_slot_%d", slot]];
    [d synchronize];
}

// HOOKS
static bool hook_install(void* mi, void* hook, void** orig) {
    if (!mi || !hook) {
        return false;
    }
    if (((uintptr_t)mi & (sizeof(void*) - 1)) != 0) {
        return false;
    }
    
    void** slot = (void**)((uintptr_t)mi + 0x0);
    // Read through mach_vm_read_overwrite: a stale/foreign MethodInfo must fail the hook
    // instead of faulting during bootstrap.
    void* old = nullptr;
    mach_vm_size_t got = 0;
    kern_return_t rk = mach_vm_read_overwrite(mach_task_self(),
                                              (mach_vm_address_t)slot,
                                              sizeof(void*),
                                              (mach_vm_address_t)&old,
                                              &got);
    if (rk != KERN_SUCCESS || got != sizeof(void*) || !old) {
        return false;
    }
    
    long ps = sysconf(_SC_PAGESIZE);
    vm_address_t start = (vm_address_t)slot & ~((vm_address_t)ps - 1);
    vm_address_t end = ((vm_address_t)slot + sizeof(void*) + ps - 1) & ~((vm_address_t)ps - 1);
    
    if (vm_protect(mach_task_self(), start, end - start, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) {
        return false;
    }
    
    *slot = hook;
    if (orig) {
        *orig = old;
    }
    
    return true;
}

// IL2CPP compiles direct calls to a plain `b`/`bl`, so patching the MethodInfo only
// catches runtime_invoke/virtual dispatch. These helpers patch the native branch itself.
static uintptr_t UnityFrameworkBase(void) {
    // Do NOT iterate _dyld_image_count()/_dyld_get_image_name(): the image list can change
    // while another thread loads a framework during startup, and libdyld aborts
    // (SIGABRT, "image index out of range") when an index goes stale. dladdr() on a
    // symbol we already resolved is stable and gives us the containing image base.
    static uintptr_t cachedBase = 0;
    if (cachedBase) {
        return cachedBase;
    }

    void* sym = (void*)p_domain_get;
    if (!sym) {
        sym = dlsym(RTLD_DEFAULT, "il2cpp_domain_get");
    }
    if (!sym) {
        sym = dlsym(RTLD_DEFAULT, "il2cpp_init");
    }
    if (!sym) {
        return 0;
    }

    Dl_info info;
    memset(&info, 0, sizeof(info));
    if (dladdr(sym, &info) != 0 && info.dli_fbase) {
        cachedBase = (uintptr_t)info.dli_fbase;
    }
    return cachedBase;
}

// Safe 4-byte read: returns false instead of faulting when `addr` is not mapped.
// The fke RVAs are hardcoded, so after a game update they may point outside the
// UnityFramework image; a raw dereference there would SIGSEGV at startup.
static bool SafeReadU32(uintptr_t addr, uint32_t* out) {
    if (!addr || !out) {
        return false;
    }
    mach_vm_size_t got = 0;
    kern_return_t kr = mach_vm_read_overwrite(mach_task_self(),
                                              (mach_vm_address_t)addr,
                                              sizeof(uint32_t),
                                              (mach_vm_address_t)out,
                                              &got);
    return kr == KERN_SUCCESS && got == sizeof(uint32_t);
}

// Returns true when `site` holds a plain `b` whose resolved target equals `expected`.
// Used to make sure a hardcoded RVA still points at the instruction we think it does
// before we overwrite it. Only `b` is accepted because PatchBranch() rewrites the
// instruction in place as a `b`; a `bl` would need its link register preserved.
static bool BranchTargets(uintptr_t site, uintptr_t expected) {
    if (!site) {
        return false;
    }
    uint32_t insn = 0;
    if (!SafeReadU32(site, &insn)) {
        return false;
    }
    if ((insn & 0xFC000000) != 0x14000000) {
        return false;
    }
    int64_t off = (int64_t)(insn & 0x03FFFFFF) << 2;
    if (off & (1LL << 27)) {
        off -= (1LL << 28);
    }
    return (site + (uintptr_t)off) == expected;
}

static bool PatchBranch(uintptr_t site, uintptr_t target) {
    uint32_t* p = (uint32_t*)site;
    uint32_t w = *p;
    if ((w & 0xFC000000) != 0x14000000) {
        return false;
    }
    int64_t delta = (int64_t)target - (int64_t)site;
    if (delta % 4 != 0 || delta < -(1LL << 27) || delta >= (1LL << 27)) {
        return false;
    }
    uint32_t nw = 0x14000000 | ((uint32_t)(delta >> 2) & 0x03FFFFFF);
    long ps = sysconf(_SC_PAGESIZE);
    vm_address_t start = (vm_address_t)p & ~((vm_address_t)ps - 1);
    vm_address_t end = ((vm_address_t)p + 4 + ps - 1) & ~((vm_address_t)ps - 1);
    if (vm_protect(mach_task_self(), start, end - start, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) {
        return false;
    }
    *p = nw;
    __builtin___clear_cache((char*)p, (char*)p + 4);
    return true;
}

// The dylib can sit more than ±128 MB from UnityFramework, which is outside the range of a
// single `b`. Allocate a small executable page near the site and jump through it.
static void* AllocNear(uintptr_t near, size_t size) {
    uintptr_t page = 0x4000;
    uintptr_t base = near & ~(page - 1);
    for (int64_t off = 0; off < 0x8000000; off += page) {
        for (int dir = 0; dir < 2; dir++) {
            uintptr_t addr = dir == 0 ? base + off : base - off;
            if (addr < 0x100000000ULL) {
                continue;
            }
            vm_address_t a = (vm_address_t)addr;
            if (vm_allocate(mach_task_self(), &a, size, VM_FLAGS_FIXED) == KERN_SUCCESS) {
                return (void*)a;
            }
        }
    }
    return nullptr;
}

static bool PatchBranchFar(uintptr_t site, uintptr_t target) {
    int64_t delta = (int64_t)target - (int64_t)site;
    if (delta % 4 == 0 && delta >= -(1LL << 27) && delta < (1LL << 27)) {
        return PatchBranch(site, target);
    }
    uint32_t* tramp = (uint32_t*)AllocNear(site, 0x4000);
    if (!tramp) {
        return false;
    }
    tramp[0] = 0x58000050;  // ldr x16, #8
    tramp[1] = 0xD61F0200;  // br x16
    // arm64e function pointers carry a PAC in the top bits; `br` needs the raw address.
    *(uint64_t*)&tramp[2] = (uint64_t)target & 0x0000FFFFFFFFFFFFULL;
    __builtin___clear_cache((char*)tramp, (char*)tramp + 16);
    // W^X: write while RW, then flip the page to RX. If the flip fails the page is still
    // RW (non-executable), so do not point a branch at it.
    kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)tramp, 0x4000, FALSE,
                                  VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        return false;
    }
    return PatchBranch(site, (uintptr_t)tramp);
}

typedef void (*fn_CamLateUpdate)(void* self, void* mi);
static fn_CamLateUpdate orig_CamLateUpdate = nullptr;

typedef void (*fn_UiOnClickFireDown)(void* self, void* mi);
static fn_UiOnClickFireDown orig_UiOnClickFireDown = nullptr;

static void ApplyAimOnFire(void) {
    if ((!gAimOnFireEnabled && !gHotAimOnFireEnabled) || !IsFireHeld() || !g_haveTarget || !p_lookAtTarget) {
        return;
    }

    void* sceneCamera = g_localSceneChar;
    if (!alive(sceneCamera)) {
        return;
    }

    if (*(bool*)((uintptr_t)sceneCamera + off::kCamIsDisable)) {
        return;
    }

    if (*(bool*)((uintptr_t)sceneCamera + off::kCamIsBusy)) {
        return;
    }

    Vec3 aimPoint = g_targetHead;
    float smooth = gAimOnFireSmooth.load();
    if (smooth > 0.0f) {
        if (!Math::Finite(g_aimOnFireSmoothTarget)) {
            g_aimOnFireSmoothTarget = aimPoint;
        }
        Vec3 diff = aimPoint - g_aimOnFireSmoothTarget;
        g_aimOnFireSmoothTarget = g_aimOnFireSmoothTarget + diff * smooth;
        aimPoint = g_aimOnFireSmoothTarget;
    }
    if (Math::Finite(aimPoint)) {
        p_lookAtTarget(sceneCamera, aimPoint, p_lookAtTargetMI);
    }
}

static void ApplyCameraOverrides(void* self) {
    if (!alive(self) || self != g_localSceneChar) {
        return;
    }

    void* camera = *(void**)((uintptr_t)self + off::kCamComponent);
    if (!alive(camera)) {
        return;
    }

    g_localCamera = camera;

    if (gStreamMode) {
        if (p_camSetAspect && gScreenPts.height > 0.0f) {
            float defaultAspect = gScreenPts.width / gScreenPts.height;
            if (std::isfinite(defaultAspect) && defaultAspect > 0.0f) {
                p_camSetAspect(camera, defaultAspect, p_camSetAspectMI);
            }
        }
    } else if (gAspectEnabled && p_camSetAspect) {
        float aspect = gAspectVal.load();
        if (std::isfinite(aspect) && aspect >= 0.5f && aspect <= 2.5f) {
            p_camSetAspect(camera, aspect, p_camSetAspectMI);
        }
    }

    if (gCamFovEnabled) {
        float fieldOfView = gCamFovVal.load();
        if (!std::isfinite(fieldOfView)) {
            fieldOfView = 0.0f;
        }

        fieldOfView = Math::Clamp(fieldOfView, 30.0f, 140.0f);
        if (p_sceneSetFov) {
            p_sceneSetFov(self, fieldOfView, p_sceneSetFovMI);
        } else if (p_camSetFov) {
            p_camSetFov(camera, fieldOfView, p_camSetFovMI);
        }
    }

    // Third person goes last: it reads the camera transform the game just finished placing and
    // pushes it back along its own view axis. Anything earlier in this function would be
    // overwritten by the LateUpdate placement.
    ApplyThirdPerson(self, camera);
}

static void ApplyViewmodelFov(void* self) {
    if (!alive(self)) {
        return;
    }
    
    void* hands = *(void**)((uintptr_t)self + off::kCamHands);
    if (!alive(hands) || !p_getTransform) {
        return;
    }
    
    void* ht = p_getTransform(hands, p_getTransformMI);
    if (!alive(ht)) {
        return;
    }
    
    if (gViewmodelFovEnabled && p_tfSetLocalScale && p_tfGetLocalScale && p_camGetFov && g_localCamera) {
        if (!gHandsBaseCaptured) {
            gHandsBaseScale = p_tfGetLocalScale(ht, p_tfGetLocalScaleMI);
            if (!Math::Finite(gHandsBaseScale)) {
                gHandsBaseScale = Vec3(1, 1, 1);
            }
            gHandsBaseCaptured = true;
        }
        
        float camFov = p_camGetFov(g_localCamera, p_camGetFovMI);
        float vmFov = gViewmodelFovVal.load();
        
        if (!std::isfinite(camFov) || camFov < 5.0f) {
            camFov = 70.0f;
        }
        if (!std::isfinite(vmFov) || vmFov < 5.0f) {
            vmFov = 70.0f;
        }
        if (camFov > 170.0f) {
            camFov = 170.0f;
        }
        if (vmFov > 170.0f) {
            vmFov = 170.0f;
        }
        
        float factor = tanf(vmFov * Math::DEG2RAD * 0.5f) / tanf(camFov * Math::DEG2RAD * 0.5f);
        if (!std::isfinite(factor)) {
            factor = 1.0f;
        }
        factor = Math::Clamp(factor, 0.15f, 6.0f);
        
        Vec3 ns(gHandsBaseScale.x * factor, gHandsBaseScale.y * factor, gHandsBaseScale.z * factor);
        p_tfSetLocalScale(ht, ns, p_tfSetLocalScaleMI);
    }
}

static void TriggerbotTick(void);

static void hook_CamLateUpdate(void* self, void* mi) {
    if (SANE_PTR(self) && self == g_localSceneChar) {
        BallisticsCameraPre(self);
    }
    
    if (orig_CamLateUpdate) {
        orig_CamLateUpdate(self, mi);
    }
    
    if (!SANE_PTR(self) || self != g_localSceneChar) {
        return;
    }
    
    // LateUpdate runs after weapon Update — keep spread/recoil at 0 for the next shot
    if (g_localWeapon && SANE_PTR(g_localWeapon)) {
        BallisticsWeaponTick(g_localWeapon);
    }
    BallisticsTick();
    BallisticsCameraPost(self);
    
    ApplyCameraOverrides(self);
    
    ApplyViewmodelFov(self);
    
    if (*(bool*)((uintptr_t)self + off::kCamIsDisable) || *(bool*)((uintptr_t)self + off::kCamIsBusy)) {
        return;
    }
    
    const bool aimbotActive = gAimbotEnabled || gHotAimbotEnabled;
    const bool aimOnFireActive = (gAimOnFireEnabled || gHotAimOnFireEnabled) && IsFireHeld();
    if ((!aimbotActive && !aimOnFireActive) || gSilentAimEnabled || !g_haveTarget) {
        return;
    }
    
    if (p_lookAtTarget) {
        // Switch-delay gate: hold the previous target for a short window so the crosshair
        // does not snap between two enemies every frame.
        if (gAimSwitchDelayEnabled.load() && gAimSwitchDelay.load() > 0) {
            if (g_aimTargetObj != gAimLastTarget) {
                if (NowMs() - gAimLastTargetMs < (uint64_t)gAimSwitchDelay.load()) {
                    return;
                }
                gAimLastTarget = g_aimTargetObj;
                gAimLastTargetMs = NowMs();
            }
        }
        
        Vec3 aimPoint = g_targetHead;
        if (!Math::Finite(aimPoint)) {
            g_haveTarget = false;
            g_smoothTarget = Vec3(0.0f, 0.0f, 0.0f);
            return;
        }
        const float s = aimbotActive ? gAimbotSmooth.load() : gAimOnFireSmooth.load();
        if (s > 0.0f) {
            if (!Math::Finite(g_smoothTarget)) {
                g_smoothTarget = aimPoint;
            }
            Vec3 diff = aimPoint - g_smoothTarget;
            g_smoothTarget = g_smoothTarget + diff * s;
            aimPoint = g_smoothTarget;
        }
        if (gAimJitterEnabled.load()) {
            float j = gAimJitter.load();
            if (j > 0.0f) {
                float jx = ((float)arc4random_uniform(2001) / 1000.0f - 1.0f) * j * 0.01f;
                float jy = ((float)arc4random_uniform(2001) / 1000.0f - 1.0f) * j * 0.01f;
                aimPoint.x += jx;
                aimPoint.y += jy;
            }
        }
        if (Math::Finite(aimPoint)) {
            p_lookAtTarget(self, aimPoint, p_lookAtTargetMI);
        }
    }
}

static void hook_UiOnClickFireDown(void* self, void* mi) {
    gFireHeldUntil = NowMs() + 5000;
    if (SANE_PTR(self)) {
        gMobileInputsInst = self;
    }
    ApplyAimOnFire();
    BallisticsFirePre();

    if (orig_UiOnClickFireDown) {
        orig_UiOnClickFireDown(self, mi);
    }
    
    BallisticsFirePost();
}

typedef void (*fn_UiOnClickFire)(void* self, void* mi);
static fn_UiOnClickFire orig_UiOnClickFire = nullptr;

static void hook_UiOnClickFire(void* self, void* mi) {
    gFireHeldUntil = NowMs() + 1000;
    if (SANE_PTR(self)) {
        gMobileInputsInst = self;
    }
    ApplyAimOnFire();
    BallisticsFirePre();

    if (orig_UiOnClickFire) {
        orig_UiOnClickFire(self, mi);
    }
    
    BallisticsFirePost();
}

typedef void (*fn_UiOnClickFireUp)(void* self, void* mi);
static fn_UiOnClickFireUp orig_UiOnClickFireUp = nullptr;

static void hook_UiOnClickFireUp(void* self, void* mi) {
    gFireHeldUntil = 0;
    
    if (orig_UiOnClickFireUp) {
        orig_UiOnClickFireUp(self, mi);
    }
}

// =========================================================================================
// TRIGGERBOT
// Fires the real mobile-input fire path when the crosshair sits inside a small pixel
// radius around an enemy. The instance and method pointers are captured from the
// OnClickFire* hooks, so no extra offsets are required.
// =========================================================================================
// The instance used to be captured only from a real OnClickFire* tap, so the triggerbot
// did nothing until the player manually fired once. Resolve it through
// Object.FindObjectsOfType(SceneLevelUiMobileInputs) instead.
static void* FindMobileInputsInstance(void) {
    if (SANE_PTR(gMobileInputsInst)) {
        return gMobileInputsInst;
    }
    if (!gMobileInputsCls || !p_findPlayerMI || !p_runtime_invoke || !p_class_get_type || !p_type_get_object) {
        return nullptr;
    }
    void* typeObj = p_type_get_object(p_class_get_type(gMobileInputsCls));
    if (!typeObj) {
        return nullptr;
    }
    void* args[1] = { typeObj };
    void* exc = nullptr;
    void* arr = p_runtime_invoke(p_findPlayerMI, nullptr, args, &exc);
    if (exc || !SANE_PTR(arr)) {
        return nullptr;
    }
    int len = *(int*)((uintptr_t)arr + 0x18);
    if (len <= 0) {
        return nullptr;
    }
    void* inst = *(void**)((uintptr_t)arr + 0x20);
    if (SANE_PTR(inst)) {
        gMobileInputsInst = inst;
    }
    return gMobileInputsInst;
}

static void TriggerbotFireDown(void) {
    void* inst = FindMobileInputsInstance();
    if (!SANE_PTR(inst)) {
        return;
    }
    // Go through the hook so aim-on-fire and the ballistics window run for this shot too.
    hook_UiOnClickFireDown(inst, gMobileInputsFireDownMI);
}

static void TriggerbotFireUp(void) {
    void* inst = FindMobileInputsInstance();
    if (!SANE_PTR(inst)) {
        return;
    }
    hook_UiOnClickFireUp(inst, gMobileInputsFireUpMI);
}

static void TriggerbotTick(void) {
    if (!gTriggerbotEnabled.load()) {
        if (gTriggerHolding) {
            TriggerbotFireUp();
            gTriggerHolding = false;
        }
        return;
    }
    if (!FindMobileInputsInstance()) {
        return;
    }
    
    uint64_t now = NowMs();
    if (gTriggerHolding) {
        uint64_t hold = (uint64_t)gTriggerbotHold.load();
        if (hold < 10) {
            hold = 10;
        }
        if (now - gTriggerReleaseMs >= hold) {
            TriggerbotFireUp();
            gTriggerHolding = false;
            gTriggerLastFireMs = now;
        }
        return;
    }
    
    uint64_t delay = (uint64_t)gTriggerbotDelay.load();
    if (delay < 20) {
        delay = 20;
    }
    if (now - gTriggerLastFireMs < delay) {
        return;
    }
    
    if (gTriggerbotScopeOnly.load() && !gLocalScoped.load()) {
        return;
    }
    
    float fov = (float)gTriggerbotFovPx.load();
    if (!std::isfinite(fov) || fov <= 0.0f) {
        return;
    }
    CGFloat cx = gScreenPts.width / 2.0f;
    CGFloat cy = gScreenPts.height / 2.0f;
    bool found = false;
    float best = fov;
    
    for (const HudPlayerInfo& p : gHudPlayers) {
        if (p.health <= 0) {
            continue;
        }
        if (gTriggerbotTeamCheck.load() && p.team == gTeam && gTeam >= 0) {
            continue;
        }
        if (gTriggerbotVisibleOnly.load() && !p.visible) {
            continue;
        }
        CGPoint aim = gTriggerbotHeadOnly.load()
            ? p.head
            : CGPointMake(p.box.origin.x + p.box.size.width / 2.0f,
                          p.box.origin.y + p.box.size.height * 0.4f);
        float dx = (float)(aim.x - cx);
        float dy = (float)(aim.y - cy);
        float d = sqrtf(dx * dx + dy * dy);
        if (d < best) {
            best = d;
            found = true;
        }
    }
    
    if (!found) {
        return;
    }
    
    TriggerbotFireDown();
    gTriggerHolding = true;
    gTriggerReleaseMs = now;
}

// =========================================================================================
// SKIN CHANGER — catalog + apply
// =========================================================================================
static void* gSkinLastAppliedWeapon = nullptr;
static uint64_t gSkinLastCheckMs = 0;

static std::string Il2CppStringToStd(void* s) {
    if (!SANE_PTR(s)) {
        return std::string();
    }
    int len = *(int*)((uintptr_t)s + 0x10);
    if (len <= 0 || len > 4096) {
        return std::string();
    }
    const uint16_t* chars = (const uint16_t*)((uintptr_t)s + 0x14);
    std::string out;
    out.reserve((size_t)len);
    for (int i = 0; i < len; i++) {
        uint16_t c = chars[i];
        out.push_back(c < 0x80 ? (char)c : '?');
    }
    return out;
}

// Fast UTF-16 comparison against a std::string without allocating.
static bool Il2CppStringEqualsStd(void* s, const std::string& str) {
    if (!SANE_PTR(s)) {
        return str.empty();
    }
    int len = *(int*)((uintptr_t)s + 0x10);
    if (len != (int)str.size()) {
        return false;
    }
    const uint16_t* chars = (const uint16_t*)((uintptr_t)s + 0x14);
    for (int i = 0; i < len; i++) {
        if (chars[i] != (uint16_t)(unsigned char)str[i]) {
            return false;
        }
    }
    return true;
}

static void SkinRebuildFilter(void) {
    gSkinFiltered.clear();
    if (gWeaponList.empty()) {
        return;
    }
    const std::string& target = gWeaponList[gSkinTargetIndex].id;
    for (int i = 0; i < (int)gSkinCatalog.size(); i++) {
        if (gSkinCatalog[i].target == target) {
            gSkinFiltered.push_back(i);
        }
    }
    if (gSkinIndex >= (int)gSkinFiltered.size()) {
        gSkinIndex = 0;
    }
}

static void SkinSelectCurrent(void) {
    gSkinLastAppliedWeapon = nullptr;
    if (gSkinFiltered.empty()) {
        gSkinSelectedObj = nullptr;
        gSkinSelectedId.clear();
        gSkinSelectedTarget.clear();
        return;
    }
    const SkinEntry& e = gSkinCatalog[gSkinFiltered[gSkinIndex]];
    gSkinSelectedObj = e.obj;
    gSkinSelectedId = e.id;
    gSkinSelectedTarget = e.target;
}

static void SkinCatalogLoad(void) {
    if (gSkinCatalogLoaded) {
        return;
    }
    if (!gGameManagerCls || !p_findPlayerMI || !p_runtime_invoke || !gItemDataGetIdMI) {
        return;
    }
    void* typeObj = p_type_get_object(p_class_get_type(gGameManagerCls));
    if (!typeObj) {
        return;
    }
    void* args[1] = { typeObj };
    void* exc = nullptr;
    void* arr = p_runtime_invoke(p_findPlayerMI, nullptr, args, &exc);
    if (exc || !SANE_PTR(arr)) {
        return;
    }
    int len = *(int*)((uintptr_t)arr + 0x18);
    if (len <= 0) {
        return;
    }
    void* gm = *(void**)((uintptr_t)arr + 0x20);
    if (!SANE_PTR(gm)) {
        return;
    }
    void* getDataMI = p_class_get_method_from_name(gGameManagerCls, "get_Data", 0);
    if (!getDataMI) {
        return;
    }
    void* data = p_runtime_invoke(getDataMI, gm, nullptr, &exc);
    if (exc || !SANE_PTR(data)) {
        return;
    }
    void* list = *(void**)((uintptr_t)data + 0x58);
    if (!SANE_PTR(list)) {
        return;
    }
    void* items = *(void**)((uintptr_t)list + 0x10);
    int size = *(int*)((uintptr_t)list + 0x18);
    if (!SANE_PTR(items) || size <= 0) {
        return;
    }

    gSkinCatalog.clear();
    gWeaponList.clear();

    for (int i = 0; i < size; i++) {
        void* obj = *(void**)((uintptr_t)items + 0x20 + (uintptr_t)i * 8);
        if (!SANE_PTR(obj)) {
            continue;
        }
        void* klass = *(void**)obj;

        bool isSkin = (klass == gItemWeaponSkinCls || klass == gItemSkinCls);
        bool isWeapon = false;
        for (int w = 0; w < gWeaponClassCount; w++) {
            if (klass == gWeaponClasses[w]) {
                isWeapon = true;
                break;
            }
        }
        if (!isSkin && !isWeapon) {
            continue;
        }

        void* idStr = p_runtime_invoke(gItemDataGetIdMI, obj, nullptr, &exc);
        if (exc || !SANE_PTR(idStr)) {
            continue;
        }
        std::string id = Il2CppStringToStd(idStr);
        if (id.empty()) {
            continue;
        }

        if (isWeapon) {
            WeaponEntry we;
            we.id = id;
            we.label = SkinPrettyName(id);
            we.obj = obj;
            we.skinCount = 0;
            gWeaponList.push_back(we);
            continue;
        }

        std::string targetId;
        void* target = *(void**)((uintptr_t)obj + 0x70);
        if (SANE_PTR(target)) {
            void* tStr = p_runtime_invoke(gItemDataGetIdMI, target, nullptr, &exc);
            if (!exc && SANE_PTR(tStr)) {
                targetId = Il2CppStringToStd(tStr);
            }
        }
        if (targetId.empty()) {
            // Knife skins ship with a null _targetItem; they are universal melee skins.
            targetId = "Knife";
        }

        SkinEntry entry;
        entry.id = id;
        entry.target = targetId;
        entry.obj = obj;
        entry.rarity = *(int*)((uintptr_t)obj + 0x24);
        gSkinCatalog.push_back(entry);
    }

    // Any skin target that is not a WeaponData asset (C4, defuse kit) still gets a row.
    for (const SkinEntry& s : gSkinCatalog) {
        bool found = false;
        for (const WeaponEntry& w : gWeaponList) {
            if (w.id == s.target) {
                found = true;
                break;
            }
        }
        if (!found) {
            WeaponEntry we;
            we.id = s.target;
            we.label = SkinPrettyName(s.target);
            we.obj = nullptr;
            we.skinCount = 0;
            gWeaponList.push_back(we);
        }
    }

    for (WeaponEntry& w : gWeaponList) {
        w.skinCount = 0;
        for (const SkinEntry& s : gSkinCatalog) {
            if (s.target == w.id) {
                w.skinCount++;
            }
        }
    }

    std::sort(gWeaponList.begin(), gWeaponList.end(), [](const WeaponEntry& a, const WeaponEntry& b) {
        return a.label < b.label;
    });

    gSkinTargetIndex = 0;
    for (int i = 0; i < (int)gWeaponList.size(); i++) {
        if (gWeaponList[i].skinCount > 0) {
            gSkinTargetIndex = i;
            break;
        }
    }
    gSkinIndex = 0;
    SkinRebuildFilter();
    SkinSelectCurrent();

    if (!gSkinPendingId.empty()) {
        for (int i = 0; i < (int)gSkinCatalog.size(); i++) {
            if (gSkinCatalog[i].id != gSkinPendingId) {
                continue;
            }
            for (int t = 0; t < (int)gWeaponList.size(); t++) {
                if (gWeaponList[t].id == gSkinCatalog[i].target) {
                    gSkinTargetIndex = t;
                    break;
                }
            }
            SkinRebuildFilter();
            for (int k = 0; k < (int)gSkinFiltered.size(); k++) {
                if (gSkinFiltered[k] == i) {
                    gSkinIndex = k;
                    break;
                }
            }
            SkinSelectCurrent();
            break;
        }
    }

    gSkinCatalogLoaded = true;
    LOG(@"[SKIN] catalog=%d weapons=%d", (int)gSkinCatalog.size(), (int)gWeaponList.size());
}

static void SkinApplyEx(bool withEquip) {
    if (!gSkinChangerEnabled.load() || !SANE_PTR(gSkinSelectedObj) || !SANE_PTR(g_localWeapon)) {
        return;
    }
    // Only paint the weapon the selected skin actually belongs to; otherwise an AK skin
    // would be written onto whatever happens to be in hand.
    if (!gSkinSelectedTarget.empty()) {
        void* dataIdStr = *(void**)((uintptr_t)g_localWeapon + 0xB0);
        if (!Il2CppStringEqualsStd(dataIdStr, gSkinSelectedTarget)) {
            return;
        }
    }

    // The viewmodel rebuild is driven by ItemSkinDto, not by the ItemSkinData field alone.
    // Feed the same JSON the server would send through SyncItemSkinDto so both the DTO and
    // the asset pointer are populated, then fire the update event.
    if (gItemSyncSkinDtoMI && p_runtime_invoke && p_string_new) {
        std::string json = "{\"Id\":\"" + gSkinSelectedId + "\",\"DataId\":\"" + gSkinSelectedId +
                           "\",\"IsNew\":false,\"Modules\":[],\"Equip\":0,\"Status\":0,\"Pattern\":0,\"PatternWear\":0}";
        void* jsonStr = p_string_new(json.c_str());
        void* emptyStr = p_string_new("");
        if (jsonStr && emptyStr) {
            void* args[2] = { emptyStr, jsonStr };
            void* exc = nullptr;
            gSkinApplying = true;
            p_runtime_invoke(gItemSyncSkinDtoMI, g_localWeapon, args, &exc);
            gSkinApplying = false;
            if (exc) {
                LOG(@"[SKIN] SyncItemSkinDto threw");
            }
        }
    }

    // Belt and suspenders: some paths read the backing field directly.
    *(void**)((uintptr_t)g_localWeapon + 0xE8) = gSkinSelectedObj;

    void* exc = nullptr;
    if (gItemFireSkinDtoUpdateMI && p_runtime_invoke) {
        p_runtime_invoke(gItemFireSkinDtoUpdateMI, g_localWeapon, nullptr, &exc);
    }
    if (SANE_PTR(g_localSceneChar)) {
        void* hands = *(void**)((uintptr_t)g_localSceneChar + off::kCamHands);
        if (SANE_PTR(hands)) {
            if (withEquip && gHandsEquipMI && p_runtime_invoke) {
                bool spectator = false;
                void* args[2] = { g_localWeapon, &spectator };
                exc = nullptr;
                p_runtime_invoke(gHandsEquipMI, hands, args, &exc);
            }
            // Equip rebuilds the whole viewmodel (and plays the swap animation). LoadModel
            // is the direct path that swaps just the mesh, so run it afterwards as well.
            if (gHandsLoadModelMI && p_runtime_invoke) {
                void* args[1] = { gSkinSelectedObj };
                exc = nullptr;
                p_runtime_invoke(gHandsLoadModelMI, hands, args, &exc);
            }
        }
    }
    gSkinLastAppliedWeapon = g_localWeapon;
    LOG(@"[SKIN] applied id=%s target=%s", gSkinSelectedId.c_str(), gSkinSelectedTarget.c_str());
}

static void SkinApply(void) {
    SkinApplyEx(true);
}

static void SkinChangerTick(void) {
    if (!gSkinChangerEnabled.load() || !SANE_PTR(gSkinSelectedObj)) {
        return;
    }
    if (!SANE_PTR(g_localWeapon)) {
        // Death / respawn: the old weapon is gone. Forget the pointer so the new weapon is
        // painted the moment it appears (otherwise a reused address would look "already done").
        gSkinLastAppliedWeapon = nullptr;
        return;
    }
    uint64_t now = NowMs();
    if (g_localWeapon != gSkinLastAppliedWeapon) {
        // New weapon: full apply (Equip rebuilds the viewmodel).
        gSkinLastAppliedWeapon = g_localWeapon;
        gSkinLastCheckMs = now;
        SkinApplyEx(true);
        return;
    }
    // Round end / re-equip can reset the skin field without changing the weapon pointer.
    // Poll once a second and quietly re-assert the skin (no Equip, so no swap animation).
    if (now - gSkinLastCheckMs < 1000) {
        return;
    }
    gSkinLastCheckMs = now;
    void* current = *(void**)((uintptr_t)g_localWeapon + 0xE8);
    if (current != gSkinSelectedObj) {
        SkinApplyEx(false);
    }
}

// Belt and suspenders: even if the game re-reads the skin from the DTO, the property
// getter still hands out the selected skin for the matching weapon.
typedef void* (*fn_ItemGetSkinData)(void* self, void* mi);
static fn_ItemGetSkinData orig_ItemGetSkinData = nullptr;

static void* hook_ItemGetSkinData(void* self, void* mi) {
    if (gSkinChangerEnabled.load() && SANE_PTR(gSkinSelectedObj) && SANE_PTR(self) &&
        !gSkinSelectedTarget.empty()) {
        void* dataIdStr = *(void**)((uintptr_t)self + 0xB0);
        if (Il2CppStringEqualsStd(dataIdStr, gSkinSelectedTarget)) {
            return gSkinSelectedObj;
        }
    }
    if (orig_ItemGetSkinData) {
        return orig_ItemGetSkinData(self, mi);
    }
    return SANE_PTR(self) ? *(void**)((uintptr_t)self + 0xE8) : nullptr;
}

// The server re-sends ItemSkinDtoStr on respawn / re-equip and SyncItemSkinDto would wipe
// the chosen skin. Swallow that update for the matching weapon so the selection survives
// death; our own SkinApply call is flagged so it still goes through.
typedef void (*fn_SyncItemSkinDto)(void* self, void* was, void* become, void* mi);
static fn_SyncItemSkinDto orig_SyncItemSkinDto = nullptr;

static void hook_SyncItemSkinDto(void* self, void* was, void* become, void* mi) {
    if (!gSkinApplying.load() && gSkinChangerEnabled.load() && SANE_PTR(gSkinSelectedObj) &&
        SANE_PTR(self) && !gSkinSelectedTarget.empty()) {
        void* dataIdStr = *(void**)((uintptr_t)self + 0xB0);
        if (Il2CppStringEqualsStd(dataIdStr, gSkinSelectedTarget)) {
            gSkinLastAppliedWeapon = nullptr;
            return;
        }
    }
    if (orig_SyncItemSkinDto) {
        orig_SyncItemSkinDto(self, was, become, mi);
    }
}

typedef void (*fn_WepUpdate)(void* self, void* mi);
static fn_WepUpdate orig_WepUpdate = nullptr;
static fn_WepUpdate orig_WepUpdateShotgun = nullptr;
static fn_WepUpdate orig_WepUpdateRange = nullptr;

static void WeaponCommonTick(void* self) {
    if (gRapidFireEnabled) {
        *(float*)((uintptr_t)self + off::kWepLastShotTime) = 0.0f;
        *(float*)((uintptr_t)self + off::kEquipCoolTime) = 0.0f;
    }
    
    if (gInstantReloadEnabled) {
        bool* isReload = (bool*)((uintptr_t)self + off::kWepIsReload);
        if (*isReload) {
            *isReload = false;
            void* equipData = *(void**)((uintptr_t)self + off::kEquipData);
            int magCap = 30;
            if (SANE_PTR(equipData)) {
                int cap = *(int*)((uintptr_t)equipData + off::kDataAmmo);
                if (cap > 0 && cap < 1000) {
                    magCap = cap;
                }
            }
            *(int*)((uintptr_t)self + off::kWepAmmo) = magCap;
        }
    }
    
    if (gUnlimAmmoEnabled) {
        *(int*)((uintptr_t)self + off::kWepAmmoTotal) = 9999;
    }
}

static void hook_WepUpdateShotgun(void* self, void* mi) {
    if (orig_WepUpdateShotgun) {
        orig_WepUpdateShotgun(self, mi);
    }
    if (!SANE_PTR(self)) {
        return;
    }
    WeaponCommonTick(self);
    BallisticsWeaponTick(self);
}

static void hook_WepUpdateRange(void* self, void* mi) {
    if (orig_WepUpdateRange) {
        orig_WepUpdateRange(self, mi);
    }
    if (!SANE_PTR(self)) {
        return;
    }
    WeaponCommonTick(self);
    BallisticsWeaponTick(self);
}

static void hook_WepUpdate(void* self, void* mi) {
    if (orig_WepUpdate) {
        orig_WepUpdate(self, mi);
    }
    if (!SANE_PTR(self)) {
        return;
    }
    
    WeaponCommonTick(self);
    BallisticsWeaponTick(self);
}

typedef void (*fn_MoveUpdate)(void* self, void* mi);
static fn_MoveUpdate orig_MoveUpdate = nullptr;

static void hook_MoveUpdate(void* self, void* mi) {
    if (orig_MoveUpdate) {
        orig_MoveUpdate(self, mi);
    }
    if (!SANE_PTR(self)) {
        return;
    }
    
    if (g_origMoveSpeed < 0) {
        g_origMoveSpeed = *(float*)((uintptr_t)self + off::kMoveSpeed);
    }
    if (g_origJumpHeight < 0) {
        g_origJumpHeight = *(float*)((uintptr_t)self + off::kMoveJumpH);
    }
    
    if (gSpeedHackEnabled) {
        *(float*)((uintptr_t)self + off::kMoveSpeed) = g_origMoveSpeed * gSpeedHackVal;
    } else {
        *(float*)((uintptr_t)self + off::kMoveSpeed) = g_origMoveSpeed;
    }
    
    if (gJumpHackEnabled) {
        *(float*)((uintptr_t)self + off::kMoveJumpH) = g_origJumpHeight * gJumpHackVal;
    } else {
        *(float*)((uintptr_t)self + off::kMoveJumpH) = g_origJumpHeight;
    }
}

static void InstallAllHooks(void) {
    @try {
        LOG(@"[HOOK] install begin");
        void* wepCls = findClass("", "ItemEquipWeaponRange");
        void* moveCls = findClass("", "SceneLevelCharacterMovementLocal");
        void* sceneCamCls = findClass("", "SceneLevelCamera");
        void* mobileInputsCls = findClass("", "SceneLevelUiMobileInputs");
        
        if (sceneCamCls) {
            void* mi = p_class_get_method_from_name(sceneCamCls, "LateUpdate", 0);
            if (mi) {
                hook_install(mi, (void*)hook_CamLateUpdate, (void**)&orig_CamLateUpdate);
            }
        }
        
        if (mobileInputsCls) {
            void* mi = p_class_get_method_from_name(mobileInputsCls, "OnClickFireDown", 0);
            if (mi) {
                gMobileInputsFireDownMI = mi;
                hook_install(mi, (void*)hook_UiOnClickFireDown, (void**)&orig_UiOnClickFireDown);
            }
            void* miFire = p_class_get_method_from_name(mobileInputsCls, "OnClickFire", 0);
            if (miFire) {
                gMobileInputsFireMI = miFire;
                hook_install(miFire, (void*)hook_UiOnClickFire, (void**)&orig_UiOnClickFire);
            }
            void* miFireUp = p_class_get_method_from_name(mobileInputsCls, "OnClickFireUp", 0);
            if (miFireUp) {
                gMobileInputsFireUpMI = miFireUp;
                hook_install(miFireUp, (void*)hook_UiOnClickFireUp, (void**)&orig_UiOnClickFireUp);
            }
        }

        if (wepCls) {
            void* mi = p_class_get_method_from_name(wepCls, "Update", 0);
            if (mi) {
                hook_install(mi, (void*)hook_WepUpdateRange, (void**)&orig_WepUpdateRange);
            }
        }
        
        void* baseWepCls = findClass("", "ItemEquipWeapon");
        if (baseWepCls && baseWepCls != wepCls) {
            void* mi = p_class_get_method_from_name(baseWepCls, "Update", 0);
            if (mi) {
                hook_install(mi, (void*)hook_WepUpdate, (void**)&orig_WepUpdate);
            }
        }
        
        void* shotgunCls = findClass("", "ItemEquipWeaponRangeShotgun");
        if (shotgunCls) {
            void* mi = p_class_get_method_from_name(shotgunCls, "Update", 0);
            if (mi) {
                hook_install(mi, (void*)hook_WepUpdateShotgun, (void**)&orig_WepUpdateShotgun);
            }
        }
        
        gMobileInputsCls = mobileInputsCls;

        // Skin changer: resolve the data classes once. The catalog itself is built lazily
        // from GameManager.Data._items when the SKINS tab is opened.
        gItemCls = findClass("", "Item");
        gItemWeaponSkinCls = findClass("Assets.Common.Scripts.Data.Global", "ItemWeaponSkin");
        if (!gItemWeaponSkinCls) {
            gItemWeaponSkinCls = findClass("", "ItemWeaponSkin");
        }
        gItemSkinCls = findClass("Assets.Common.Scripts.Data.Global", "ItemSkin");
        if (!gItemSkinCls) {
            gItemSkinCls = findClass("", "ItemSkin");
        }
        gGameManagerCls = findClass("", "GameManager");
        gDataCls = findClass("Assets.Common.Scripts.Data", "Data");
        void* itemDataCls = findClass("Assets.Common.Scripts.Data.Level", "ItemData");
        if (!itemDataCls) {
            itemDataCls = findClass("", "ItemData");
        }
        if (itemDataCls) {
            gItemDataGetIdMI = p_class_get_method_from_name(itemDataCls, "get_Id", 0);
        }
        if (gItemCls) {
            gItemFireSkinDtoUpdateMI = p_class_get_method_from_name(gItemCls, "FireSkinDtoUpdate", 0);
            gItemSyncSkinDtoMI = p_class_get_method_from_name(gItemCls, "SyncItemSkinDto", 2);
            void* miSkin = p_class_get_method_from_name(gItemCls, "get_ItemSkinData", 0);
            if (miSkin) {
                hook_install(miSkin, (void*)hook_ItemGetSkinData, (void**)&orig_ItemGetSkinData);
            }
            if (gItemSyncSkinDtoMI) {
                hook_install(gItemSyncSkinDtoMI, (void*)hook_SyncItemSkinDto, (void**)&orig_SyncItemSkinDto);
            }
        }
        void* handsCls = findClass("", "SceneLevelHands");
        if (handsCls) {
            gHandsEquipMI = p_class_get_method_from_name(handsCls, "Equip", 2);
            gHandsLoadModelMI = p_class_get_method_from_name(handsCls, "LoadModel", 1);
        }

        // Every weapon class that can appear in Data._items. The SKINS tab lists all of
        // them, not just the ones that already have skins.
        const char* weaponNames[] = {
            "WeaponDataRange", "WeaponDataMelee", "WeaponDataGrenade",
            "WeaponDataGrenadeExplosion", "WeaponDataGrenadeFlash",
            "WeaponDataGrenadeMolotov", "WeaponDataGrenadeSmoke", "WeaponData",
            "ItemEquipDataCFour", "ItemEquipDataDefuseKit"
        };
        gWeaponClassCount = 0;
        for (int i = 0; i < (int)(sizeof(weaponNames) / sizeof(weaponNames[0])); i++) {
            void* k = findClass("Assets.Game.Scripts.Scenes.Game.Mono.Characters", weaponNames[i]);
            if (!k) {
                k = findClass("Assets.Common.Scripts.Data.Level", weaponNames[i]);
            }
            if (!k) {
                k = findClass("", weaponNames[i]);
            }
            if (k && gWeaponClassCount < 12) {
                gWeaponClasses[gWeaponClassCount++] = k;
            }
        }
        LOG(@"[SKIN] item=%p skin=%p weaponSkin=%p data=%p weapons=%d",
            gItemCls, gItemSkinCls, gItemWeaponSkinCls, gDataCls, gWeaponClassCount);

        InstallBallisticsHooks();
        LOG(@"[HOOK] ballistics done");
        
        if (moveCls) {
            void* mi = p_class_get_method_from_name(moveCls, "Update", 0);
            if (mi) {
                hook_install(mi, (void*)hook_MoveUpdate, (void**)&orig_MoveUpdate);
            }
        }
        LOG(@"[HOOK] install complete");
    } @catch (NSException* e) {
        LOG(@"Hooks: %@", SafeStr([e reason]));
    }
}

// CHAMS
static void EnsureMaterialCtorMI(void) {
    if (p_matCopyCtorMI || !gMatCls || !p_class_get_methods) {
        return;
    }
    
    void* iter = nullptr;
    while (void* mi = p_class_get_methods(gMatCls, &iter)) {
        if (!p_method_get_name) {
            continue;
        }
        const char* name = p_method_get_name(mi);
        if (!name || strcmp(name, ".ctor") != 0) {
            continue;
        }
        if (p_method_get_param_count && p_method_get_param_count(mi) != 1) {
            continue;
        }
        if (p_method_get_param && p_type_get_name) {
            void* t = p_method_get_param(mi, 0);
            if (!t) {
                continue;
            }
            char* tn = p_type_get_name(t);
            if (tn && strstr(tn, "Material")) {
                p_matCopyCtorMI = mi;
                return;
            }
        }
    }
}

static void* CreateChamsMaterial(void* source, int type, uint32_t hexColor, bool xray) {
    if (!p_object_new || !gMatCls || !p_runtime_invoke) {
        return nullptr;
    }
    
    EnsureMaterialCtorMI();
    if (!p_matCopyCtorMI) {
        return nullptr;
    }
    
    void* newMat = p_object_new(gMatCls);
    if (!newMat) {
        return nullptr;
    }
    
    void* args[1] = { source };
    void* exc = nullptr;
    p_runtime_invoke(p_matCopyCtorMI, newMat, args, &exc);
    
    if (exc) {
        return nullptr;
    }
    
    float r = ((hexColor >> 24) & 0xFF) / 255.0f;
    float g = ((hexColor >> 16) & 0xFF) / 255.0f;
    float b = ((hexColor >> 8) & 0xFF) / 255.0f;
    float a = (hexColor & 0xFF) / 255.0f;
    
    // type: 0 = Normal, 1 = Glass, 2 = Glow. X-Ray is a separate flag so the
    // selected look is preserved and only the depth test changes.
    bool glass = (type == 1);
    bool glow = (type == 2);
    float outAlpha = glass ? a : 1.0f;
    
    void* strColor = p_string_new("_Color");
    void* strBaseColor = p_string_new("_BaseColor");
    
    if (p_matSetColor) {
        UnityColor col(r, g, b, outAlpha);
        if (strColor) {
            p_matSetColor(newMat, strColor, col, p_matSetColorMI);
        }
        if (strBaseColor) {
            p_matSetColor(newMat, strBaseColor, col, p_matSetColorMI);
        }
        
        void* strEmission = p_string_new("_EmissionColor");
        if (glow) {
            UnityColor emis(r * 1.5f, g * 1.5f, b * 1.5f, 1.0f);
            if (strEmission) {
                p_matSetColor(newMat, strEmission, emis, p_matSetColorMI);
            }
        } else {
            UnityColor zero(0, 0, 0, 0);
            if (strEmission) {
                p_matSetColor(newMat, strEmission, zero, p_matSetColorMI);
            }
        }
    }
    
    if (p_matSetTexture) {
        void* strMainTex = p_string_new("_MainTex");
        if (strMainTex) {
            p_matSetTexture(newMat, strMainTex, nullptr, p_matSetTextureMI);
        }
        void* strBaseMap = p_string_new("_BaseMap");
        if (strBaseMap) {
            p_matSetTexture(newMat, strBaseMap, nullptr, p_matSetTextureMI);
        }
    }
    
    // Per-type render state.
    if (p_matSetFloat) {
        if (glass || xray) {
            void* strZWrite = p_string_new("_ZWrite");
            if (strZWrite) {
                p_matSetFloat(newMat, strZWrite, 0.0f, p_matSetFloatMI);
            }
        }
        if (xray) {
            void* strZTestF = p_string_new("_ZTest");
            if (strZTestF) {
                p_matSetFloat(newMat, strZTestF, 8.0f, p_matSetFloatMI);
            }
        }
    }
    
    if (p_matEnableKeyword) {
        if (glow) {
            void* strEmis = p_string_new("_EMISSION");
            if (strEmis) {
                p_matEnableKeyword(newMat, strEmis, p_matEnableKeywordMI);
            }
        }
        if (glass || xray) {
            void* strTransparent = p_string_new("_SURFACE_TYPE_TRANSPARENT");
            if (strTransparent) {
                p_matEnableKeyword(newMat, strTransparent, p_matEnableKeywordMI);
            }
        }
    }
    
    if (p_matSetInt) {
        if (xray) {
            // 8 = CompareFunction.Always: draw on top of all geometry.
            void* strZTest = p_string_new("_ZTest");
            void* strStencilComp = p_string_new("_StencilComp");
            void* strCull = p_string_new("_Cull");
            if (strZTest) {
                p_matSetInt(newMat, strZTest, 8, p_matSetIntMI);
            }
            if (strStencilComp) {
                p_matSetInt(newMat, strStencilComp, 8, p_matSetIntMI);
            }
            if (strCull) {
                p_matSetInt(newMat, strCull, 0, p_matSetIntMI);
            }
        }
        if (glass) {
            void* strSrc = p_string_new("_SrcBlend");
            void* strDst = p_string_new("_DstBlend");
            if (strSrc) {
                p_matSetInt(newMat, strSrc, 5, p_matSetIntMI);
            }
            if (strDst) {
                p_matSetInt(newMat, strDst, 10, p_matSetIntMI);
            }
        }
    }
    
    if (p_matSetRQ) {
        if (xray) {
            p_matSetRQ(newMat, 4000, p_matSetRQMI);
        } else if (glass) {
            p_matSetRQ(newMat, 3000, p_matSetRQMI);
        } else if (glow) {
            p_matSetRQ(newMat, 4000, p_matSetRQMI);
        }
    }
    
    return newMat;
}

static void* GetSampleMaterial(void) {
    if (gSampleMat) {
        return gSampleMat;
    }
    
    for (void* p : gCached) {
        if (!alive(p) || p == gLocal) {
            continue;
        }
        
        void* c = *(void**)((uintptr_t)p + off::kPlayerCharacter);
        if (!alive(c)) {
            continue;
        }
        
        void* ct = *(void**)((uintptr_t)c + off::kCharController);
        if (!alive(ct)) {
            continue;
        }
        
        void* rv = *(void**)((uintptr_t)ct + off::kOtherRemoteVis);
        if (!alive(rv)) {
            continue;
        }
        
        void* renderArrays[3] = {
            *(void**)((uintptr_t)rv + 0x60),
            *(void**)((uintptr_t)rv + 0x78),
            *(void**)((uintptr_t)rv + 0x98)
        };
        
        for (int ai = 0; ai < 3; ai++) {
            void* arr = renderArrays[ai];
            if (!SANE_PTR(arr)) {
                continue;
            }
            
            int len = *(int*)((uintptr_t)arr + 0x18);
            if (len <= 0) {
                continue;
            }
            
            for (int i = 0; i < len && i < 32; i++) {
                void* rend = *(void**)((uintptr_t)arr + 0x20 + i * 8);
                if (!alive(rend)) {
                    continue;
                }
                
                void* mats = p_rendGetSharedMats(rend, p_rendGetSharedMatsMI);
                if (!SANE_PTR(mats)) {
                    continue;
                }
                
                int mlen = *(int*)((uintptr_t)mats + 0x18);
                if (mlen <= 0) {
                    continue;
                }
                
                void* mat = *(void**)((uintptr_t)mats + 0x20);
                if (alive(mat)) {
                    gSampleMat = mat;
                    if (p_gchandle_new) {
                        gSampleMatHandle = p_gchandle_new(mat, true);
                    }
                    return mat;
                }
            }
        }
    }
    return nullptr;
}

static void EnsureChamsMaterials(void) {
    if (!gMatCls) {
        return;
    }
    
    EnsureMaterialCtorMI();
    if (!p_matCopyCtorMI) {
        return;
    }
    
    bool needP = false;
    bool needW = false;
    for (int i = 0; i < 6; i++) {
        if (!gChamsMatsPlayer[i]) {
            needP = true;
        }
        if (!gChamsMatsWeapon[i]) {
            needW = true;
        }
    }
    
    if (!needP && !needW) {
        return;
    }
    
    void* sample = GetSampleMaterial();
    if (!sample) {
        return;
    }
    
    uint32_t pc = gChamsPlayerColor.load();
    uint32_t wc = gChamsWeaponColor.load();
    
    for (int i = 0; i < 6; i++) {
        int type = i % 3;
        bool xray = (i >= 3);
        if (!gChamsMatsPlayer[i]) {
            gChamsMatsPlayer[i] = CreateChamsMaterial(sample, type, pc, xray);
        }
        if (!gChamsMatsWeapon[i]) {
            gChamsMatsWeapon[i] = CreateChamsMaterial(sample, type, wc, xray);
        }
    }
}

static void ApplyChamsToRenderer(void* rend, void* chamsMat) {
    if (!alive(rend) || !chamsMat || !p_rendGetSharedMats || !p_rendSetSharedMats) {
        return;
    }
    
    void* orig = p_rendGetSharedMats(rend, p_rendGetSharedMatsMI);
    if (SANE_PTR(orig)) {
        int n = *(int*)((uintptr_t)orig + 0x18);
        if (n > 0 && *(void**)((uintptr_t)orig + 0x20) == chamsMat) {
            return;
        }
    }
    
    if (gOrigMats.find(rend) == gOrigMats.end()) {
        if (SANE_PTR(orig) && p_gchandle_new) {
            uint32_t h = p_gchandle_new(orig, true);
            SavedMat saved;
            saved.array = orig;
            saved.handle = h;
            gOrigMats[rend] = saved;
        }
    }
    
    int n = SANE_PTR(orig) ? *(int*)((uintptr_t)orig + 0x18) : 1;
    if (n <= 0) {
        n = 1;
    }
    if (n > 32) {
        n = 32;
    }
    
    void* arr = nullptr;
    auto it = gAppliedMats.find(rend);
    if (it != gAppliedMats.end()) {
        arr = it->second.array;
    }
    
    if (!arr) {
        arr = p_array_new(gMatCls, (size_t)n);
        if (!arr) {
            return;
        }
        
        SavedMat saved;
        saved.array = arr;
        saved.handle = p_gchandle_new ? p_gchandle_new(arr, true) : 0;
        gAppliedMats[rend] = saved;
    }
    
    for (int i = 0; i < n; i++) {
        *(void**)((uintptr_t)arr + 0x20 + i * 8) = chamsMat;
    }
    
    p_rendSetSharedMats(rend, arr, p_rendSetSharedMatsMI);
}

static void* GetWeaponRenderersCached(void* obj) {
    if (!alive(obj)) {
        return nullptr;
    }
    
    auto it = gWeaponRenderersCache.find(obj);
    if (it != gWeaponRenderersCache.end()) {
        return it->second;
    }
    
    if (!p_getCompsInChildrenMI || !gRendererCls) {
        return nullptr;
    }
    
    void* rendTypeObj = p_type_get_object(p_class_get_type(gRendererCls));
    void* exc = nullptr;
    void* rArr = nullptr;
    
    if (p_method_get_param_count && p_method_get_param_count(p_getCompsInChildrenMI) == 2) {
        bool includeInactive = true;
        void* args[2] = { rendTypeObj, &includeInactive };
        rArr = p_runtime_invoke(p_getCompsInChildrenMI, obj, args, &exc);
    } else {
        void* args[1] = { rendTypeObj };
        rArr = p_runtime_invoke(p_getCompsInChildrenMI, obj, args, &exc);
    }
    
    if (rArr && !exc) {
        if (p_gchandle_new) {
            p_gchandle_new(rArr, true);
        }
        gWeaponRenderersCache[obj] = rArr;
        return rArr;
    }
    
    return nullptr;
}

static inline int ChamsMatIndex(int type, bool xray) {
    if (type < 0 || type > 2) {
        type = 0;
    }
    return type + (xray ? 3 : 0);
}

// -----------------------------------------------------------------------------------------
// THIRD PERSON
//
// Pulls the already-placed camera back along its own view axis. Nothing else about the view is
// touched: SceneLevelCamera.rot stays exactly as the game set it, so the aim pipeline and the
// crosshair-to-ray relationship are unchanged.
// -----------------------------------------------------------------------------------------
static void ApplyThirdPerson(void* self, void* camera) {
    if (!alive(self) || self != g_localSceneChar || !alive(camera)) {
        return;
    }

    bool on = gTpEnabled.load();

    // Turning it off restores the renderers first, otherwise the local body stays forced on in
    // first person and blocks the whole screen.
    if (!on) {
        if (gTpBodyApplied.load()) {
            for (auto& kv : gTpRendererState) {
                if (alive(kv.first) && p_rendSetEnabled) {
                    p_rendSetEnabled(kv.first, kv.second, p_rendSetEnabledMI);
                }
            }
            gTpRendererState.clear();
            gTpBodyApplied = false;
        }
        return;
    }

    if (!p_getTransform || !p_getTransformMI || !p_tfGetPos || !p_tfSetPos ||
        !p_tfGetPosMI || !p_tfSetPosMI || !p_tfGetEuler || !p_tfGetEulerMI) {
        return;
    }

    void* camT = p_getTransform(camera, p_getTransformMI);
    if (!alive(camT)) {
        return;
    }

    Vec3 pivot = p_tfGetPos(camT, p_tfGetPosMI);
    if (!Math::Finite(pivot)) {
        return;
    }

    Vec3 euler = p_tfGetEuler(camT, p_tfGetEulerMI);
    if (!Math::Finite(euler)) {
        return;
    }

    const float deg2rad = 0.017453292519943295f;
    float yaw = euler.y * deg2rad;
    float pitch = euler.x * deg2rad;

    // Unity's forward for (pitch, yaw), with pitch positive looking down:
    //   forward = (sin yaw * cos pitch, -sin pitch, cos yaw * cos pitch)
    //   right   = (cos yaw, 0, -sin yaw)
    float cp = cosf(pitch);
    Vec3 fwd(sinf(yaw) * cp, -sinf(pitch), cosf(yaw) * cp);
    Vec3 right(cosf(yaw), 0.0f, -sinf(yaw));

    float dist = gTpDistance.load();
    if (!std::isfinite(dist)) {
        dist = 2.6f;
    }
    dist = Math::Clamp(dist, 0.3f, 15.0f);

    float h = gTpHeight.load();
    if (!std::isfinite(h)) {
        h = 0.55f;
    }
    h = Math::Clamp(h, -2.0f, 4.0f);

    float sh = gTpShoulder.load();
    if (!std::isfinite(sh)) {
        sh = 0.0f;
    }
    sh = Math::Clamp(sh, -2.0f, 2.0f);

    Vec3 want = pivot - fwd * dist + Vec3(0.0f, h, 0.0f) + right * sh;
    if (!Math::Finite(want)) {
        return;
    }

    p_tfSetPos(camT, want, p_tfSetPosMI);

    // Third person usually wants a wider lens, otherwise the pulled-back view feels like
    // looking through a straw. 0 leaves the game's FOV alone.
    float tpFov = gTpFov.load();
    if (std::isfinite(tpFov) && tpFov >= 30.0f && tpFov <= 140.0f) {
        if (p_sceneSetFov) {
            p_sceneSetFov(self, tpFov, p_sceneSetFovMI);
        } else if (p_camSetFov) {
            p_camSetFov(camera, tpFov, p_camSetFovMI);
        }
    }

    // First person hides the local body. Force its renderers back on, remembering the original
    // flag so the switch back is exact.
    if (!gTpShowBody.load() || !p_getGameObject || !p_getGameObjectMI || !p_rendSetEnabled) {
        return;
    }

    void* modelContainer = *(void**)((uintptr_t)self + off::kCharModelContainer);
    if (!alive(modelContainer)) {
        return;
    }

    void* modelGO = p_getGameObject(modelContainer, p_getGameObjectMI);
    if (!alive(modelGO)) {
        return;
    }

    void* renderers = GetWeaponRenderersCached(modelGO);
    if (!renderers) {
        return;
    }

    int count = *(int*)((uintptr_t)renderers + 0x18);
    void** items = (void**)((uintptr_t)renderers + 0x20);
    if (count <= 0 || !items) {
        return;
    }
    if (count > 512) {
        count = 512;
    }

    for (int i = 0; i < count; i++) {
        void* rend = items[i];
        if (!alive(rend)) {
            continue;
        }
        if (gTpRendererState.find(rend) == gTpRendererState.end()) {
            // Remember the flag the game left on this renderer so disabling third person
            // restores exactly what first person had.
            bool wasEnabled = true;
            if (p_rendGetEnabled) {
                wasEnabled = p_rendGetEnabled(rend, p_rendGetEnabledMI);
            }
            gTpRendererState[rend] = wasEnabled;
        }
        p_rendSetEnabled(rend, true, p_rendSetEnabledMI);
    }

    gTpBodyApplied = true;
}

static void UpdateChamsForPlayer(void* player, void* charCtrl) {
    void* rv = *(void**)((uintptr_t)charCtrl + off::kOtherRemoteVis);
    if (!alive(rv)) {
        return;
    }
    
    int playerType = ChamsMatIndex(gChamsPlayerMatType.load(), gChamsPlayerXray.load());
    int weaponType = ChamsMatIndex(gChamsWeaponMatType.load(), gChamsWeaponXray.load());
    bool pEnabled = gChamsPlayerEnabled.load();
    bool wEnabled = gChamsWeaponEnabled.load();
    
    if (!pEnabled && !wEnabled) {
        return;
    }
    
    if (pEnabled && gChamsMatsPlayer[playerType]) {
        void* renderArrays[3] = {
            *(void**)((uintptr_t)rv + 0x60),
            *(void**)((uintptr_t)rv + 0x78),
            *(void**)((uintptr_t)rv + 0x98)
        };
        
        for (int ai = 0; ai < 3; ai++) {
            void* arr = renderArrays[ai];
            if (!SANE_PTR(arr)) {
                continue;
            }
            
            int len = *(int*)((uintptr_t)arr + 0x18);
            if (len <= 0 || len > 32) {
                continue;
            }
            
            for (int i = 0; i < len; i++) {
                void* rend = *(void**)((uintptr_t)arr + 0x20 + i * 8);
                if (alive(rend)) {
                    ApplyChamsToRenderer(rend, gChamsMatsPlayer[playerType]);
                }
            }
        }
    }
    
    if (wEnabled && gChamsMatsWeapon[weaponType]) {
        void* itemView = *(void**)((uintptr_t)rv + off::kRvItemView);
        if (alive(itemView)) {
            void* itemModel = *(void**)((uintptr_t)itemView + 0x38);
            if (alive(itemModel)) {
                void* weaponGO = *(void**)((uintptr_t)itemModel + 0x28);
                if (alive(weaponGO)) {
                    void* rArr = GetWeaponRenderersCached(weaponGO);
                    if (rArr) {
                        int rLen = *(int*)((uintptr_t)rArr + 0x18);
                        for (int ri = 0; ri < rLen; ri++) {
                            void* rend = *(void**)((uintptr_t)rArr + 0x20 + ri * 8);
                            if (alive(rend)) {
                                ApplyChamsToRenderer(rend, gChamsMatsWeapon[weaponType]);
                            }
                        }
                    }
                }
            }
        }
    }
}

static void UpdateLocalChams() {
    if (!gChamsWeaponEnabled) {
        return;
    }
    
    if (gStreamMode) {
        return;
    }
    
    int weaponType = ChamsMatIndex(gChamsWeaponMatType.load(), gChamsWeaponXray.load());
    if (!gChamsMatsWeapon[weaponType]) {
        return;
    }
    
    if (alive(g_localWeapon) && p_getGameObject && p_getGameObjectMI) {
        void* go = p_getGameObject(g_localWeapon, p_getGameObjectMI);
        if (alive(go)) {
            void* rArr = GetWeaponRenderersCached(go);
            if (rArr) {
                int rLen = *(int*)((uintptr_t)rArr + 0x18);
                for (int ri = 0; ri < rLen; ri++) {
                    void* rend = *(void**)((uintptr_t)rArr + 0x20 + ri * 8);
                    if (alive(rend)) {
                        ApplyChamsToRenderer(rend, gChamsMatsWeapon[weaponType]);
                    }
                }
            }
        }
    }
    
    if (alive(g_localSceneChar)) {
        void* hands = *(void**)((uintptr_t)g_localSceneChar + off::kCamHands);
        if (alive(hands) && p_getTransform && p_getGameObject) {
            void* ht = p_getTransform(hands, p_getTransformMI);
            if (alive(ht)) {
                void* hgo = p_getGameObject(ht, p_getGameObjectMI);
                if (alive(hgo)) {
                    void* rArr = GetWeaponRenderersCached(hgo);
                    if (rArr) {
                        int rLen = *(int*)((uintptr_t)rArr + 0x18);
                        for (int ri = 0; ri < rLen; ri++) {
                            void* rend = *(void**)((uintptr_t)rArr + 0x20 + ri * 8);
                            if (alive(rend)) {
                                ApplyChamsToRenderer(rend, gChamsMatsWeapon[weaponType]);
                            }
                        }
                    }
                }
            }
        }
    }
}

static void RestoreAllChams() {
    for (auto& pair : gOrigMats) {
        void* rend = pair.first;
        SavedMat& saved = pair.second;
        
        if (alive(rend) && alive(saved.array) && p_rendSetSharedMats) {
            p_rendSetSharedMats(rend, saved.array, p_rendSetSharedMatsMI);
        }
        if (saved.handle && p_gchandle_free) {
            p_gchandle_free(saved.handle);
        }
    }
    
    gOrigMats.clear();
    gWeaponRenderersCache.clear();
    
    for (auto& pair : gAppliedMats) {
        if (pair.second.handle && p_gchandle_free) {
            p_gchandle_free(pair.second.handle);
        }
    }
    gAppliedMats.clear();
}

static void CleanupDeadRenderers() {
    for (auto it = gOrigMats.begin(); it != gOrigMats.end(); ) {
        if (!alive(it->first)) {
            if (it->second.handle && p_gchandle_free) {
                p_gchandle_free(it->second.handle);
            }
            it = gOrigMats.erase(it);
        } else {
            ++it;
        }
    }
    
    for (auto it = gWeaponRenderersCache.begin(); it != gWeaponRenderersCache.end(); ) {
        if (!alive(it->first)) {
            it = gWeaponRenderersCache.erase(it);
        } else {
            ++it;
        }
    }
    
    for (auto it = gAppliedMats.begin(); it != gAppliedMats.end(); ) {
        if (!alive(it->first)) {
            if (it->second.handle && p_gchandle_free) {
                p_gchandle_free(it->second.handle);
            }
            it = gAppliedMats.erase(it);
        } else {
            ++it;
        }
    }
}

static dispatch_source_t gChamsTimer = nullptr;

static void ChamsTick() {
    @autoreleasepool {
        if (!gAttached) {
            return;
        }
        
        if (gChamsPlayerColorDirty) {
            for (int i = 0; i < 6; i++) {
                gChamsMatsPlayer[i] = nullptr;
            }
            gChamsPlayerColorDirty = false;
        }
        
        if (gChamsWeaponColorDirty) {
            for (int i = 0; i < 6; i++) {
                gChamsMatsWeapon[i] = nullptr;
            }
            gChamsWeaponColorDirty = false;
        }
        
        if (g_prevLocalWeapon != g_localWeapon) {
            g_prevLocalWeapon = g_localWeapon;
            gWeaponRenderersCache.clear();
        }
        
        if (!gChamsPlayerEnabled && !gChamsWeaponEnabled) {
            if (!gOrigMats.empty()) {
                RestoreAllChams();
            }
            return;
        }
        
        EnsureChamsMaterials();
        if (!gChamsMatsPlayer[0] && !gChamsMatsWeapon[0]) {
            return;
        }
        
        for (void* p : gCached) {
            if (!alive(p) || p == gLocal) {
                continue;
            }
            if (*(bool*)((uintptr_t)p + off::kPlayerIsDead)) {
                continue;
            }
            
            int tm = *(int*)((uintptr_t)p + off::kPlayerTeam);
            if (gAimbotNoTeam && tm == gTeam && gTeam >= 0) {
                continue;
            }
            
            void* c = *(void**)((uintptr_t)p + off::kPlayerCharacter);
            if (!alive(c) || *(bool*)((uintptr_t)c + off::kCharIsDead)) {
                continue;
            }
            
            void* ct = *(void**)((uintptr_t)c + off::kCharController);
            if (!alive(ct)) {
                continue;
            }
            
            UpdateChamsForPlayer(p, ct);
        }
        
        UpdateLocalChams();
        
        uint64_t tMs = NowMs();
        static uint64_t lastCleanup = 0;
        if (tMs - lastCleanup > 3000) {
            lastCleanup = tMs;
            CleanupDeadRenderers();
        }
    }
}

// =========================================================================================
// UI
// =========================================================================================
static UIImage* CreateFlopDLCFLogo(CGSize size) {
    UIGraphicsImageRenderer* renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext* ctx) {
        CGContextRef c = ctx.CGContext;
        CGContextClearRect(c, CGRectMake(0, 0, size.width, size.height));
        CGFloat w = size.width;
        CGFloat h = size.height;
        
        // Draw F
        CGContextSetFillColorWithColor(c, [UIColor whiteColor].CGColor);
        CGContextFillRect(c, CGRectMake(w * 0.25, h * 0.15, w * 0.2, h * 0.7));
        CGContextFillRect(c, CGRectMake(w * 0.25, h * 0.15, w * 0.45, h * 0.2));
        CGContextFillRect(c, CGRectMake(w * 0.25, h * 0.45, w * 0.35, h * 0.15));
        
        // Draw Slash
        CGContextSetBlendMode(c, kCGBlendModeClear);
        CGContextSetLineWidth(c, w * 0.08);
        CGContextSetLineCap(c, kCGLineCapRound);
        CGContextMoveToPoint(c, w * 0.05, h * 0.95);
        CGContextAddLineToPoint(c, w * 0.85, h * 0.05);
        CGContextStrokePath(c);
        CGContextSetBlendMode(c, kCGBlendModeNormal);
    }];
}

static UIImage* CreateKeyIcon(CGSize size, UIColor *color) {
    UIGraphicsImageRenderer* renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext* ctx) {
        CGContextRef c = ctx.CGContext;
        CGContextSetStrokeColorWithColor(c, color.CGColor);
        CGContextSetLineWidth(c, 2.0);
        CGContextSetLineCap(c, kCGLineCapRound);
        
        // Circle part
        CGContextStrokeEllipseInRect(c, CGRectMake(size.width * 0.2, size.height * 0.2, size.width * 0.4, size.height * 0.4));
        
        // Shaft
        CGContextMoveToPoint(c, size.width * 0.55, size.height * 0.55);
        CGContextAddLineToPoint(c, size.width * 0.85, size.height * 0.85);
        CGContextStrokePath(c);
        
        // Teeth
        CGContextMoveToPoint(c, size.width * 0.75, size.height * 0.85);
        CGContextAddLineToPoint(c, size.width * 0.85, size.height * 0.75);
        CGContextStrokePath(c);
    }];
}

@interface WatermarkView : UIView
@property (nonatomic, strong) UILabel* timeLabel;
@property (nonatomic, strong) UILabel* fpsLabel;
@property (nonatomic, strong) UILabel* ramLabel;
- (void)updateFps:(float)fps;
- (void)applyStyle;
@end

@implementation WatermarkView {
    NSTimer* _timer;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.95];
        self.layer.cornerRadius = 8.0;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:1.0].CGColor;
        self.userInteractionEnabled = NO;
        self.clipsToBounds = YES;
        
        UIStackView* stack = [[UIStackView alloc] initWithFrame:self.bounds];
        stack.axis = UILayoutConstraintAxisHorizontal;
        stack.alignment = UIStackViewAlignmentCenter;
        stack.distribution = UIStackViewDistributionEqualSpacing;
        stack.spacing = 10;
        stack.layoutMargins = UIEdgeInsetsMake(0, 15, 0, 15);
        stack.layoutMarginsRelativeArrangement = YES;
        stack.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:stack];
        
        UIImageView* logo = [[UIImageView alloc] initWithImage:CreateFlopDLCFLogo(CGSizeMake(40, 40))];
        logo.contentMode = UIViewContentModeScaleAspectFit;
        [logo.widthAnchor constraintEqualToConstant:20].active = YES;
        [logo.heightAnchor constraintEqualToConstant:20].active = YES;
        [stack addArrangedSubview:logo];
        
        UILabel* name = [[UILabel alloc] init];
        name.text = @"FlopDLC";
        name.textColor = [UIColor whiteColor];
        name.font = [UIFont boldSystemFontOfSize:15];
        [stack addArrangedSubview:name];
        
        UIView *sep1 = [[UIView alloc] init];
        sep1.backgroundColor = [UIColor grayColor];
        [sep1.widthAnchor constraintEqualToConstant:1].active = YES;
        [sep1.heightAnchor constraintEqualToConstant:16].active = YES;
        [stack addArrangedSubview:sep1];
        
        UIImageView* globe = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"globe"]];
        globe.tintColor = [UIColor colorWithRed:0.4 green:0.7 blue:1.0 alpha:1.0];
        [globe.widthAnchor constraintEqualToConstant:16].active = YES;
        [globe.heightAnchor constraintEqualToConstant:16].active = YES;
        [stack addArrangedSubview:globe];
        
        UILabel* url = [[UILabel alloc] init];
        url.text = @"FlopDLC.cc";
        url.textColor = [UIColor whiteColor];
        url.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        [stack addArrangedSubview:url];
        
        UIView *sep2 = [[UIView alloc] init];
        sep2.backgroundColor = [UIColor grayColor];
        [sep2.widthAnchor constraintEqualToConstant:1].active = YES;
        [sep2.heightAnchor constraintEqualToConstant:16].active = YES;
        [stack addArrangedSubview:sep2];
        
        UIImageView* clock = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"clock"]];
        clock.tintColor = [UIColor colorWithRed:0.9 green:0.8 blue:0.4 alpha:1.0];
        [clock.widthAnchor constraintEqualToConstant:16].active = YES;
        [clock.heightAnchor constraintEqualToConstant:16].active = YES;
        [stack addArrangedSubview:clock];
        
        _timeLabel = [[UILabel alloc] init];
        _timeLabel.text = @"00:00";
        _timeLabel.textColor = [UIColor whiteColor];
        _timeLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        [stack addArrangedSubview:_timeLabel];
        
        UIView *sep3 = [[UIView alloc] init];
        sep3.backgroundColor = [UIColor grayColor];
        [sep3.widthAnchor constraintEqualToConstant:1].active = YES;
        [sep3.heightAnchor constraintEqualToConstant:16].active = YES;
        [stack addArrangedSubview:sep3];
        
        UIImageView* speed = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"speedometer"]];
        speed.tintColor = [UIColor colorWithRed:0.6 green:0.4 blue:1.0 alpha:1.0];
        [speed.widthAnchor constraintEqualToConstant:16].active = YES;
        [speed.heightAnchor constraintEqualToConstant:16].active = YES;
        [stack addArrangedSubview:speed];
        
        _fpsLabel = [[UILabel alloc] init];
        _fpsLabel.text = @"60 FPS";
        _fpsLabel.textColor = [UIColor whiteColor];
        _fpsLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        [stack addArrangedSubview:_fpsLabel];
        
        UIView *sep4 = [[UIView alloc] init];
        sep4.backgroundColor = [UIColor grayColor];
        [sep4.widthAnchor constraintEqualToConstant:1].active = YES;
        [sep4.heightAnchor constraintEqualToConstant:16].active = YES;
        [stack addArrangedSubview:sep4];
        
        UIImageView* memIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"memorychip"]];
        memIcon.tintColor = [UIColor colorWithRed:0.4 green:0.8 blue:0.6 alpha:1.0];
        [memIcon.widthAnchor constraintEqualToConstant:16].active = YES;
        [memIcon.heightAnchor constraintEqualToConstant:16].active = YES;
        [stack addArrangedSubview:memIcon];
        
        _ramLabel = [[UILabel alloc] init];
        _ramLabel.text = @"0 MB / 0 MB";
        _ramLabel.textColor = [UIColor whiteColor];
        _ramLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        [stack addArrangedSubview:_ramLabel];
        
        _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(updateTime) userInfo:nil repeats:YES];
        [self updateTime];
    }
    return self;
}

- (void)updateTime {
    NSDateFormatter* fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"HH:mm";
    _timeLabel.text = [fmt stringFromDate:[NSDate date]];
    
    struct mach_task_basic_info info{};
    mach_msg_type_number_t size = MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t kerr = task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &size);
    
    uint64_t used_mb = 0;
    if (kerr == KERN_SUCCESS) {
        used_mb = info.resident_size / (1024 * 1024);
    }
    
    uint64_t max_mb = 0;
    typedef uint64_t (*fn_os_proc_available_memory)();
    fn_os_proc_available_memory p_avail = (fn_os_proc_available_memory)dlsym(RTLD_DEFAULT, "os_proc_available_memory");
    
    if (p_avail) {
        uint64_t available = p_avail();
        uint64_t resident = kerr == KERN_SUCCESS ? info.resident_size : 0;
        max_mb = (resident + available) / (1024 * 1024);
    } else {
        max_mb = [NSProcessInfo processInfo].physicalMemory / (1024 * 1024);
    }
    
    _ramLabel.text = SafeFmt(@"%llu MB / %llu MB", used_mb, max_mb);
}

- (void)updateFps:(float)fps {
    if (!std::isfinite(fps)) {
        fps = 60;
    }
    if (gWatermarkShowPlayers.load()) {
        int n = (int)gHudPlayers.size();
        _fpsLabel.text = SafeFmt(@"%.0f FPS  %dP", fps, n);
    } else {
        _fpsLabel.text = SafeFmt(@"%.0f FPS", fps);
    }
}

- (void)applyStyle {
    float a = gWatermarkAlpha.load();
    if (!std::isfinite(a) || a < 0.1f) {
        a = 0.95f;
    }
    self.alpha = a;
    
    float s = gWatermarkScale.load();
    if (!std::isfinite(s) || s < 0.3f) {
        s = 1.0f;
    }
    self.transform = CGAffineTransformMakeScale(s, s);
    
    UIColor* accent = gWatermarkAccent ?: [UIColor colorWithWhite:0.3 alpha:1.0];
    self.layer.borderColor = accent.CGColor;
    
    self.timeLabel.hidden = !gWatermarkShowTime.load();
    self.fpsLabel.hidden = !gWatermarkShowFps.load();
}

- (void)dealloc {
    [_timer invalidate];
}

@end

// =========================================================================================
// KEY SYSTEM (Neverlose Style Mobile Adjusted)
// =========================================================================================
@interface SnowView : UIView
@end

@implementation SnowView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = NO;
        
        CAEmitterLayer *emitter = [CAEmitterLayer layer];
        emitter.emitterPosition = CGPointMake(frame.size.width / 2, -50);
        emitter.emitterSize = CGSizeMake(frame.size.width * 2, 1);
        emitter.emitterShape = kCAEmitterLayerLine;
        emitter.emitterMode = kCAEmitterLayerSurface;
        
        CAEmitterCell *snowflake = [CAEmitterCell emitterCell];
        snowflake.birthRate = 40.0;
        snowflake.lifetime = 12.0;
        snowflake.velocity = 30;
        snowflake.velocityRange = 25;
        snowflake.yAcceleration = 15;
        snowflake.emissionRange = 0.5 * M_PI;
        snowflake.spinRange = 0.5 * M_PI;
        
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(6, 6), NO, 0.0);
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        CGContextSetFillColorWithColor(ctx, [UIColor whiteColor].CGColor);
        CGContextFillEllipseInRect(ctx, CGRectMake(0, 0, 6, 6));
        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        
        snowflake.contents = (id)img.CGImage;
        snowflake.scale = 0.4;
        snowflake.scaleRange = 0.6;
        snowflake.alphaSpeed = -0.04;
        
        emitter.emitterCells = @[snowflake];
        [self.layer addSublayer:emitter];
    }
    return self;
}

@end

@interface KeySystemView : UIView <UITextFieldDelegate>
@property (nonatomic, copy) void (^onSuccess)(void);
- (instancetype)initWithFrame:(CGRect)frame;
@end

@implementation KeySystemView {
    UITextField *_keyField;
    UILabel *_errorLabel;
    UIView *_mainContainer;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.02 alpha:1.0];
        
        // Background Logo (Stretched & Angled)
        UIImageView *bgLogo = [[UIImageView alloc] initWithImage:CreateFlopDLCFLogo(CGSizeMake(800, 800))];
        bgLogo.contentMode = UIViewContentModeScaleAspectFit;
        bgLogo.frame = CGRectMake(-200, -100, frame.size.width + 400, frame.size.height + 200);
        bgLogo.transform = CGAffineTransformMakeRotation(M_PI / 8);
        bgLogo.alpha = 0.05;
        [self addSubview:bgLogo];
        
        // Glow Effects
        UIView *glow1 = [[UIView alloc] initWithFrame:CGRectMake(-100, -100, 400, 400)];
        glow1.backgroundColor = [UIColor colorWithRed:0.4 green:0.1 blue:0.8 alpha:0.3];
        glow1.layer.cornerRadius = 200;
        glow1.layer.masksToBounds = YES;
        [self addSubview:glow1];
        
        UIView *glow2 = [[UIView alloc] initWithFrame:CGRectMake(frame.size.width - 200, frame.size.height - 200, 400, 400)];
        glow2.backgroundColor = [UIColor colorWithRed:0.4 green:0.1 blue:0.8 alpha:0.3];
        glow2.layer.cornerRadius = 200;
        glow2.layer.masksToBounds = YES;
        [self addSubview:glow2];
        
        // Snow
        SnowView *snow = [[SnowView alloc] initWithFrame:frame];
        [self addSubview:snow];
        
        // Main Container (Mobile Friendly)
        CGFloat cw = MIN(frame.size.width - 40, 340);
        CGFloat ch = 400;
        
        _mainContainer = [[UIView alloc] initWithFrame:CGRectMake((frame.size.width - cw)/2, (frame.size.height - ch)/2, cw, ch)];
        _mainContainer.backgroundColor = [UIColor colorWithRed:0.08 green:0.08 blue:0.12 alpha:0.95];
        _mainContainer.layer.cornerRadius = 16;
        _mainContainer.layer.borderWidth = 1;
        _mainContainer.layer.borderColor = [UIColor colorWithRed:0.4 green:0.2 blue:0.8 alpha:1.0].CGColor;
        _mainContainer.clipsToBounds = YES;
        [self addSubview:_mainContainer];
        
        // Logo
        UIImageView *logo = [[UIImageView alloc] initWithImage:CreateFlopDLCFLogo(CGSizeMake(80, 80))];
        logo.center = CGPointMake(cw / 2, 60);
        logo.layer.shadowColor = [UIColor colorWithRed:0.5 green:0.2 blue:1.0 alpha:1.0].CGColor;
        logo.layer.shadowRadius = 15;
        logo.layer.shadowOpacity = 0.8;
        logo.layer.shadowOffset = CGSizeZero;
        [_mainContainer addSubview:logo];
        
        // Title
        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 110, cw, 30)];
        title.text = @"Key System";
        title.textColor = [UIColor whiteColor];
        title.font = [UIFont boldSystemFontOfSize:22];
        title.textAlignment = NSTextAlignmentCenter;
        [_mainContainer addSubview:title];
        
        // Subtitle
        UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectMake(0, 145, cw, 40)];
        subtitle.text = @"Enter your key to activate FlopDLC.\n(Free Key in @FlopDLC)";
        subtitle.textColor = [UIColor lightGrayColor];
        subtitle.font = [UIFont systemFontOfSize:12];
        subtitle.numberOfLines = 2;
        subtitle.textAlignment = NSTextAlignmentCenter;
        [_mainContainer addSubview:subtitle];
        
        // Input Field
        UIView *inputBg = [[UIView alloc] initWithFrame:CGRectMake(20, 200, cw - 40, 50)];
        inputBg.backgroundColor = [UIColor colorWithWhite:0.05 alpha:1.0];
        inputBg.layer.cornerRadius = 8;
        inputBg.layer.borderWidth = 1;
        inputBg.layer.borderColor = [UIColor colorWithWhite:0.2 alpha:1.0].CGColor;
        [_mainContainer addSubview:inputBg];
        
        UIImageView *inputIcon = [[UIImageView alloc] initWithImage:CreateKeyIcon(CGSizeMake(20, 20), [UIColor colorWithWhite:0.4 alpha:1.0])];
        inputIcon.frame = CGRectMake(15, 15, 20, 20);
        [inputBg addSubview:inputIcon];
        
        _keyField = [[UITextField alloc] initWithFrame:CGRectMake(45, 0, cw - 90, 50)];
        _keyField.textColor = [UIColor whiteColor];
        _keyField.font = [UIFont systemFontOfSize:14];
        _keyField.placeholder = @"Enter your key...";
        _keyField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"Enter your key..." attributes:@{NSForegroundColorAttributeName: [UIColor grayColor]}];
        _keyField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        _keyField.autocorrectionType = UITextAutocorrectionTypeNo;
        _keyField.delegate = self;
        [inputBg addSubview:_keyField];
        
        // Activate Button
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.frame = CGRectMake(20, 270, cw - 40, 50);
        [btn setTitle:@"Activate Key" forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        btn.backgroundColor = [UIColor colorWithRed:0.4 green:0.2 blue:0.8 alpha:1.0];
        btn.layer.cornerRadius = 8;
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
        [btn setImage:[UIImage systemImageNamed:@"bolt.fill"] forState:UIControlStateNormal];
        btn.tintColor = [UIColor whiteColor];
        btn.imageEdgeInsets = UIEdgeInsetsMake(0, -10, 0, 0);
        [btn addTarget:self action:@selector(activate) forControlEvents:UIControlEventTouchUpInside];
        [_mainContainer addSubview:btn];
        
        _errorLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 330, cw - 40, 20)];
        _errorLabel.textColor = [UIColor redColor];
        _errorLabel.font = [UIFont systemFontOfSize:12];
        _errorLabel.textAlignment = NSTextAlignmentCenter;
        [_mainContainer addSubview:_errorLabel];
        
        // Bottom Bar
        UIView *bottomBar = [[UIView alloc] initWithFrame:CGRectMake(0, ch - 40, cw, 40)];
        bottomBar.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.5];
        [_mainContainer addSubview:bottomBar];
        
        UIView *topBorder = [[UIView alloc] initWithFrame:CGRectMake(0, 0, cw, 1)];
        topBorder.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.5];
        [bottomBar addSubview:topBorder];
        
        UIView *statusView = [[UIView alloc] initWithFrame:CGRectMake((cw - 120)/2, 10, 120, 20)];
        statusView.backgroundColor = [UIColor colorWithWhite:0.1 alpha:1.0];
        statusView.layer.cornerRadius = 10;
        statusView.layer.borderWidth = 1;
        statusView.layer.borderColor = [UIColor colorWithRed:0.2 green:0.6 blue:0.2 alpha:1.0].CGColor;
        [bottomBar addSubview:statusView];
        
        UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(10, 6, 8, 8)];
        dot.backgroundColor = [UIColor greenColor];
        dot.layer.cornerRadius = 4;
        [statusView addSubview:dot];
        
        UILabel *statusText = [[UILabel alloc] initWithFrame:CGRectMake(25, 0, 90, 20)];
        statusText.text = @"Ready";
        statusText.textColor = [UIColor whiteColor];
        statusText.font = [UIFont systemFontOfSize:11];
        [statusView addSubview:statusText];
    }
    return self;
}

- (void)activate {
    NSString *entered = _keyField.text;
    if ([entered isEqualToString:@"FlopDLC1122"]) {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"flop_authed"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        
        if (self.onSuccess) {
            self.onSuccess();
        }
        [self removeFromSuperview];
    } else {
        _errorLabel.text = @"Неверный ключ!";
        
        CAKeyframeAnimation *anim = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
        anim.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
        anim.duration = 0.4;
        anim.values = @[@(-10), @(10), @(-10), @(10), @(-5), @(5), @(0)];
        [_mainContainer.layer addAnimation:anim forKey:@"shake"];
    }
}

@end

// =========================================================================================
// UI COMPONENTS
// =========================================================================================
@interface NLGroupBox : UIView
@property (nonatomic, strong) UILabel *titleLabel;
@end

// Neverlose palette: near-black surfaces, one violet accent, hairline borders.
static UIColor* NLAccent(void) {
    return gMenuAccent ?: [UIColor colorWithRed:0.545 green:0.361 blue:0.965 alpha:1.0];
}
static UIColor* NLSurface(void) {
    return [UIColor colorWithRed:0.055 green:0.055 blue:0.070 alpha:1.0];
}
static UIColor* NLSurfaceHi(void) {
    return [UIColor colorWithRed:0.086 green:0.086 blue:0.106 alpha:1.0];
}
static UIColor* NLBorder(void) {
    return [UIColor colorWithRed:0.145 green:0.145 blue:0.176 alpha:1.0];
}
static UIColor* NLTextDim(void) {
    return [UIColor colorWithRed:0.545 green:0.545 blue:0.596 alpha:1.0];
}

@implementation NLGroupBox

- (instancetype)initWithTitle:(NSString*)title frame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.layer.borderColor = NLBorder().CGColor;
        self.layer.borderWidth = 1.0;
        self.layer.cornerRadius = 10.0;
        self.backgroundColor = NLSurfaceHi();
        
        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, 200, 16)];
        lbl.text = SafeStr(title);
        lbl.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
        lbl.textColor = NLAccent();
        [self addSubview:lbl];
        self.titleLabel = lbl;
    }
    return self;
}

@end

@interface NLCheckbox : UIView
@property (nonatomic, assign) BOOL isOn;
@property (nonatomic, assign) BOOL isDisabled;
@property (nonatomic, copy) void (^onToggle)(BOOL);
@end

@implementation NLCheckbox {
    UIView *_inner;
    UILabel *_xMark;
}

- (instancetype)initWithFrame:(CGRect)frame {
    // Call sites pass 18x18; Neverlose uses a pill, so force the pill size here.
    self = [super initWithFrame:CGRectMake(frame.origin.x, frame.origin.y, 36, 20)];
    if (self) {
        self.layer.cornerRadius = 10;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = NLBorder().CGColor;
        self.backgroundColor = NLSurface();
        self.userInteractionEnabled = YES;
        
        _inner = [[UIView alloc] initWithFrame:CGRectMake(2, 2, 16, 16)];
        _inner.layer.cornerRadius = 8;
        _inner.backgroundColor = NLTextDim();
        _inner.userInteractionEnabled = NO;
        [self addSubview:_inner];
        
        _xMark = [[UILabel alloc] initWithFrame:self.bounds];
        _xMark.text = @"✖";
        _xMark.textColor = [UIColor redColor];
        _xMark.textAlignment = NSTextAlignmentCenter;
        _xMark.font = [UIFont boldSystemFontOfSize:12];
        _xMark.hidden = YES;
        [self addSubview:_xMark];
        
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggle)];
        [self addGestureRecognizer:tap];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _xMark.frame = self.bounds;
}

- (void)toggle {
    if (self.isDisabled) {
        return;
    }
    
    self.isOn = !self.isOn;
    if (self.onToggle) {
        self.onToggle(self.isOn);
    }
}

- (void)setIsOn:(BOOL)isOn {
    _isOn = isOn;
    __weak NLCheckbox* weakSelf = self;
    [UIView animateWithDuration:0.15 animations:^{
        NLCheckbox* s = weakSelf;
        if (!s) {
            return;
        }
        s.backgroundColor = isOn ? NLAccent() : NLSurface();
        s->_inner.backgroundColor = isOn ? [UIColor whiteColor] : NLTextDim();
        s->_inner.frame = CGRectMake(isOn ? 18 : 2, 2, 16, 16);
    }];
}

- (void)setIsDisabled:(BOOL)isDisabled {
    _isDisabled = isDisabled;
    if (isDisabled) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = NLSurface();
        self.layer.borderColor = NLBorder().CGColor;
        _inner.hidden = YES;
        _xMark.hidden = NO;
    } else {
        self.userInteractionEnabled = YES;
        self.backgroundColor = _isOn ? NLAccent() : NLSurface();
        self.layer.borderColor = NLBorder().CGColor;
        _xMark.hidden = YES;
        _inner.hidden = NO;
    }
}

@end

@interface NLColorSwatch : UIView
@property (nonatomic, strong) UIColor *color;
@property (nonatomic, copy) void (^onTap)(void);
@end

@implementation NLColorSwatch

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.layer.cornerRadius = 3;
        self.layer.borderWidth = 1;
        self.layer.borderColor = [UIColor whiteColor].CGColor;
        
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapAction)];
        [self addGestureRecognizer:tap];
    }
    return self;
}

- (void)setColor:(UIColor *)color {
    _color = color;
    self.backgroundColor = color ?: [UIColor whiteColor];
}

- (void)tapAction {
    if (self.onTap) {
        self.onTap();
    }
}

@end

@interface NLSlider : UIView
@property (nonatomic, assign) float value;
@property (nonatomic, assign) float min;
@property (nonatomic, assign) float max;
@property (nonatomic, copy) void (^onChange)(float);
@property (nonatomic, copy) void (^onRelease)(float);
@property (nonatomic, strong) UILabel *valLabel;
@end

@implementation NLSlider {
    UIView *_track;
    UIView *_fill;
    UIView *_knob;
    NSString *_suffix;
    float _w;
}

- (instancetype)initWithFrame:(CGRect)frame suffix:(NSString*)suffix {
    self = [super initWithFrame:frame];
    if (self) {
        _suffix = SafeStr(suffix);
        _w = frame.size.width - 35;
        self.userInteractionEnabled = YES;
        
        _track = [[UIView alloc] initWithFrame:CGRectMake(0, frame.size.height/2 - 1.5, _w, 3)];
        _track.backgroundColor = NLBorder();
        _track.layer.cornerRadius = 1.5;
        [self addSubview:_track];
        
        _fill = [[UIView alloc] initWithFrame:CGRectMake(0, 0, _w, 3)];
        _fill.backgroundColor = NLAccent();
        _fill.layer.cornerRadius = 1.5;
        [_track addSubview:_fill];
        
        _knob = [[UIView alloc] initWithFrame:CGRectMake(0, frame.size.height/2 - 5, 10, 10)];
        _knob.backgroundColor = [UIColor whiteColor];
        _knob.layer.cornerRadius = 5;
        [self addSubview:_knob];
        
        _valLabel = [[UILabel alloc] initWithFrame:CGRectMake(_w + 5, 0, 30, frame.size.height)];
        _valLabel.textColor = [UIColor whiteColor];
        _valLabel.font = [UIFont systemFontOfSize:10];
        _valLabel.textAlignment = NSTextAlignmentRight;
        [self addSubview:_valLabel];
        
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panAction:)];
        [self addGestureRecognizer:pan];
    }
    return self;
}

- (void)setValue:(float)value {
    if (!std::isfinite(value)) {
        return;
    }
    
    _value = MAX(self.min, MIN(self.max, value));
    float pct = (_value - self.min) / (self.max - self.min);
    
    _fill.frame = CGRectMake(0, 0, pct * _w, 3);
    _knob.center = CGPointMake(pct * _w, _track.center.y);
    
    if (_suffix.length > 0) {
        _valLabel.text = SafeFmt(@"%.1f%@", _value, _suffix);
    } else {
        _valLabel.text = SafeFmt(@"%.2f", _value);
    }
    
    if (self.onChange) {
        self.onChange(_value);
    }
}

- (void)panAction:(UIPanGestureRecognizer*)p {
    CGPoint pt = [p locationInView:self];
    float pct = MAX(0, MIN(1, pt.x / _w));
    float v = self.min + pct * (self.max - self.min);
    self.value = roundf(v * 10) / 10.0f;
    
    if (p.state == UIGestureRecognizerStateEnded && self.onRelease) {
        self.onRelease(self.value);
    }
}

@end

@interface NLButton : UIView
@property (nonatomic, copy) void (^onTap)(void);
@property (nonatomic, strong) UILabel *titleLabel;
@end

@implementation NLButton

- (instancetype)initWithTitle:(NSString*)title {
    self = [super initWithFrame:CGRectMake(0, 0, 80, 16)];
    if (self) {
        self.backgroundColor = NLSurfaceHi();
        self.layer.cornerRadius = 6;
        self.layer.borderWidth = 1;
        self.layer.borderColor = NLBorder().CGColor;
        self.userInteractionEnabled = YES;
        
        _titleLabel = [[UILabel alloc] initWithFrame:self.bounds];
        _titleLabel.text = SafeStr(title);
        _titleLabel.textColor = [UIColor whiteColor];
        _titleLabel.font = [UIFont systemFontOfSize:9 weight:UIFontWeightSemibold];
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        [self addSubview:_titleLabel];
        
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapAction)];
        [self addGestureRecognizer:tap];
    }
    return self;
}

- (void)tapAction {
    if (self.onTap) {
        self.onTap();
    }
}

@end

// =========================================================================================
// NLSkinRow — one row in the SKINS tab: rarity dot, name, right-side detail, check mark.
// =========================================================================================
@interface NLSkinRow : UIView
@property (nonatomic, copy) void (^onTap)(void);
- (instancetype)initWithTitle:(NSString*)title detail:(NSString*)detail rarity:(int)rarity selected:(BOOL)selected;
@end

@implementation NLSkinRow

- (instancetype)initWithTitle:(NSString*)title detail:(NSString*)detail rarity:(int)rarity selected:(BOOL)selected {
    self = [super initWithFrame:CGRectMake(0, 0, 260, 26)];
    if (self) {
        self.backgroundColor = selected
            ? [NLAccent() colorWithAlphaComponent:0.85]
            : NLSurfaceHi();
        self.layer.cornerRadius = 5;
        self.layer.borderWidth = selected ? 1.0 : 0.5;
        self.layer.borderColor = selected
            ? [UIColor colorWithRed:0.45 green:0.75 blue:1.0 alpha:1.0].CGColor
            : [UIColor colorWithWhite:0.30 alpha:0.6].CGColor;
        self.userInteractionEnabled = YES;

        UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(9, 9, 8, 8)];
        dot.backgroundColor = SkinRarityColor(rarity);
        dot.layer.cornerRadius = 4;
        [self addSubview:dot];

        UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(24, 0, self.bounds.size.width - 92, 26)];
        name.text = SafeStr(title);
        name.textColor = [UIColor whiteColor];
        name.font = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
        name.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [self addSubview:name];

        if (detail.length > 0) {
            UILabel *d = [[UILabel alloc] initWithFrame:CGRectMake(self.bounds.size.width - 92, 0, 70, 26)];
            d.text = detail;
            d.textColor = [UIColor colorWithWhite:0.72 alpha:1.0];
            d.font = [UIFont systemFontOfSize:9 weight:UIFontWeightMedium];
            d.textAlignment = NSTextAlignmentRight;
            d.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
            [self addSubview:d];
        }

        if (selected) {
            UILabel *check = [[UILabel alloc] initWithFrame:CGRectMake(self.bounds.size.width - 22, 0, 18, 26)];
            check.text = @"✓";
            check.textColor = [UIColor whiteColor];
            check.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
            check.textAlignment = NSTextAlignmentCenter;
            check.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
            [self addSubview:check];
        }

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapAction)];
        [self addGestureRecognizer:tap];
    }
    return self;
}

- (void)tapAction {
    if (self.onTap) {
        self.onTap();
    }
}

@end

@interface NLRow : UIView
@end

@implementation NLRow

- (instancetype)initWithTitle:(NSString*)title y:(CGFloat)y control:(UIView*)control swatch:(NLColorSwatch*)swatch {
    self = [super initWithFrame:CGRectMake(15, y, 210, 22)]; 
    if (self) {
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 100, 22)];
        l.text = SafeStr(title);
        l.textColor = [UIColor colorWithWhite:0.92 alpha:1.0];
        l.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        [self addSubview:l];
        
        if (swatch) {
            swatch.frame = CGRectMake(105, 3, 16, 16);
            [self addSubview:swatch];
        }
        
        if (control) {
            CGRect f = control.frame;
            f.origin.x = 210 - f.size.width;
            f.origin.y = (22 - f.size.height) / 2;
            control.frame = f;
            [self addSubview:control];
        }
    }
    return self;
}

@end

// CONFIG ROW — label + Save / Load / Del, used by the CONFIG tab.
@interface NLConfigRow : UIView
- (instancetype)initWithTitle:(NSString*)title y:(CGFloat)y
                       onSave:(void(^)(void))onSave
                       onLoad:(void(^)(void))onLoad
                     onDelete:(void(^)(void))onDelete;
@end

@implementation NLConfigRow

- (instancetype)initWithTitle:(NSString*)title y:(CGFloat)y
                       onSave:(void(^)(void))onSave
                       onLoad:(void(^)(void))onLoad
                     onDelete:(void(^)(void))onDelete {
    self = [super initWithFrame:CGRectMake(15, y, 210, 22)];
    if (self) {
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 90, 22)];
        l.text = SafeStr(title);
        l.textColor = [UIColor colorWithWhite:0.92 alpha:1.0];
        l.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        [self addSubview:l];
        
        NLButton *bSave = [[NLButton alloc] initWithTitle:@"Save"];
        bSave.frame = CGRectMake(96, 3, 34, 16);
        bSave.onTap = onSave;
        [self addSubview:bSave];
        
        NLButton *bLoad = [[NLButton alloc] initWithTitle:@"Load"];
        bLoad.frame = CGRectMake(134, 3, 34, 16);
        bLoad.onTap = onLoad;
        [self addSubview:bLoad];
        
        NLButton *bDel = [[NLButton alloc] initWithTitle:@"Del"];
        bDel.frame = CGRectMake(172, 3, 34, 16);
        bDel.onTap = onDelete;
        [self addSubview:bDel];
    }
    return self;
}

@end

@interface ColorPickerView : UIView
@property (nonatomic, copy) void (^onColorSelected)(UIColor *color);
- (instancetype)initWithFrame:(CGRect)frame currentColor:(UIColor*)color;
@end

@implementation ColorPickerView {
    UIImageView *_wheelView;
    UIView *_brightnessSlider;
    UIView *_knob;
    UIView *_preview;
    CAGradientLayer *_gradientLayer;
    CGFloat _hue;
    CGFloat _sat;
    CGFloat _brightness;
    CGPoint _center;
    CGFloat _radius;
}

- (instancetype)initWithFrame:(CGRect)frame currentColor:(UIColor*)color {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.95];
        self.layer.cornerRadius = 12;
        self.layer.borderWidth = 1;
        self.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:0.8].CGColor;
        
        CGFloat alpha = 1.0;
        if (![color getHue:&_hue saturation:&_sat brightness:&_brightness alpha:&alpha]) {
            _hue = 0;
            _sat = 1;
            _brightness = 1;
        }
        if (_sat == 0) {
            _hue = 0;
            _sat = 1;
        }
        
        _center = CGPointMake(frame.size.width / 2, 150);
        _radius = 100;
        
        _wheelView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, _radius*2, _radius*2)];
        _wheelView.center = _center;
        _wheelView.image = [self generateColorWheel:_radius];
        _wheelView.userInteractionEnabled = YES;
        [self addSubview:_wheelView];
        
        _brightnessSlider = [[UIView alloc] initWithFrame:CGRectMake(40, 280, frame.size.width - 80, 20)];
        _brightnessSlider.backgroundColor = [UIColor darkGrayColor];
        _brightnessSlider.layer.cornerRadius = 10;
        _brightnessSlider.layer.masksToBounds = YES;
        [self addSubview:_brightnessSlider];
        
        _gradientLayer = [CAGradientLayer layer];
        _gradientLayer.frame = _brightnessSlider.bounds;
        _gradientLayer.startPoint = CGPointMake(0, 0.5);
        _gradientLayer.endPoint = CGPointMake(1, 0.5);
        [_brightnessSlider.layer addSublayer:_gradientLayer];
        
        _knob = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 24, 24)];
        _knob.backgroundColor = [UIColor whiteColor];
        _knob.layer.cornerRadius = 12;
        _knob.layer.borderWidth = 2;
        _knob.layer.borderColor = [UIColor blackColor].CGColor;
        [_brightnessSlider addSubview:_knob];
        
        _preview = [[UIView alloc] initWithFrame:CGRectMake((frame.size.width - 60) / 2, 320, 60, 60)];
        _preview.layer.cornerRadius = 30;
        _preview.layer.borderWidth = 2;
        _preview.layer.borderColor = [UIColor whiteColor].CGColor;
        [self addSubview:_preview];
        
        [self updateUI];
    }
    return self;
}

- (UIImage*)generateColorWheel:(CGFloat)radius {
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(radius*2, radius*2)];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull context) {
        CGContextRef ctx = context.CGContext;
        int numSegments = 360;
        
        for (int i = 0; i < numSegments; i++) {
            CGFloat startAngle = (i * M_PI / 180.0) - M_PI_2;
            CGFloat endAngle = ((i + 1) * M_PI / 180.0) - M_PI_2;
            
            CGContextMoveToPoint(ctx, radius, radius);
            CGContextAddArc(ctx, radius, radius, radius, startAngle, endAngle, 0);
            CGContextClosePath(ctx);
            
            UIColor *c = [UIColor colorWithHue:(CGFloat)i/numSegments saturation:1.0 brightness:1.0 alpha:1.0];
            CGContextSetFillColorWithColor(ctx, c.CGColor);
            CGContextFillPath(ctx);
        }
        
        CGGradientRef gradient;
        CGColorSpaceRef colorspace;
        size_t num_locations = 2;
        CGFloat locations[2] = { 0.0, 1.0 };
        CGFloat components[8] = { 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.0 };
        
        colorspace = CGColorSpaceCreateDeviceRGB();
        gradient = CGGradientCreateWithColorComponents(colorspace, components, locations, num_locations);
        CGContextDrawRadialGradient(ctx, gradient, CGPointMake(radius, radius), 0, CGPointMake(radius, radius), radius, 0);
        
        CGGradientRelease(gradient);
        CGColorSpaceRelease(colorspace);
    }];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch* t = [touches anyObject];
    if (t) {
        [self handleTouch:t];
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch* t = [touches anyObject];
    if (t) {
        [self handleTouch:t];
    }
}

- (void)handleTouch:(UITouch*)touch {
    CGPoint pt = [touch locationInView:self];
    CGFloat dx = pt.x - _center.x;
    CGFloat dy = pt.y - _center.y;
    CGFloat dist = sqrt(dx*dx + dy*dy);
    
    if (dist <= _radius + 20 && pt.y < 250) {
        _hue = (atan2(dy, dx) + M_PI_2) / (2*M_PI);
        if (_hue < 0) {
            _hue += 1.0;
        }
        _sat = MIN(1.0, dist / _radius);
        [self updateUI];
        [self sendColor];
    } else if (CGRectContainsPoint(_brightnessSlider.frame, pt)) {
        CGFloat pct = (pt.x - 40) / (self.frame.size.width - 80);
        _brightness = MAX(0, MIN(1, pct));
        [self updateUI];
        [self sendColor];
    }
}

- (void)updateUI {
    _knob.center = CGPointMake(_brightness * _brightnessSlider.bounds.size.width, _brightnessSlider.bounds.size.height/2);
    
    UIColor *c = [UIColor colorWithHue:_hue saturation:_sat brightness:_brightness alpha:1.0];
    _preview.backgroundColor = c;
    
    UIColor *pureHue = [UIColor colorWithHue:_hue saturation:_sat brightness:1.0 alpha:1.0];
    _gradientLayer.colors = @[(id)[UIColor blackColor].CGColor, (id)pureHue.CGColor];
}

- (void)sendColor {
    if (self.onColorSelected) {
        self.onColorSelected([UIColor colorWithHue:_hue saturation:_sat brightness:_brightness alpha:1.0]);
    }
}

@end

@interface ESPView : UIView
@property (nonatomic, strong) NSMutableArray<NSValue*>* boxes;
@property (nonatomic, strong) NSMutableArray<NSString*>* labels;
@property (nonatomic, strong) NSMutableArray<NSNumber*>* hps;
@property (nonatomic, strong) NSMutableArray<NSNumber*>* armors;
@property (nonatomic, strong) NSMutableArray<NSValue*>* skeletonLines;
@property (nonatomic, strong) NSMutableArray<NSValue*>* nameTexts;
@property (nonatomic, strong) NSMutableArray<NSString*>* names;
@property (nonatomic, strong) NSMutableArray<NSValue*>* tracers;
@property (nonatomic, strong) NSMutableArray<NSValue*>* oofDirs;
@property (nonatomic, strong) NSMutableArray<NSValue*>* weaponBoxes;
@property (nonatomic, strong) NSMutableArray<NSString*>* weaponLabels;
@property (nonatomic, strong) NSMutableArray<NSValue*>* headDots;
@property (nonatomic, strong) NSMutableArray<NSValue*>* snapLines;
@property (nonatomic, strong) NSMutableArray<UIColor*>* boxColors;
@property (nonatomic, strong) NSMutableArray<NSString*>* healthTexts;
@property (nonatomic, strong) NSMutableArray<NSNumber*>* dists;
@end

@implementation ESPView

- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = NO;
        self.opaque = NO;
        self.clearsContextBeforeDrawing = NO;
        
        _boxes = [NSMutableArray arrayWithCapacity:32];
        _labels = [NSMutableArray arrayWithCapacity:32];
        _hps = [NSMutableArray arrayWithCapacity:32];
        _armors = [NSMutableArray arrayWithCapacity:32];
        _skeletonLines = [NSMutableArray arrayWithCapacity:64];
        _nameTexts = [NSMutableArray arrayWithCapacity:32];
        _names = [NSMutableArray arrayWithCapacity:32];
        _tracers = [NSMutableArray arrayWithCapacity:32];
        _oofDirs = [NSMutableArray arrayWithCapacity:32];
        _weaponBoxes = [NSMutableArray arrayWithCapacity:32];
        _weaponLabels = [NSMutableArray arrayWithCapacity:32];
        _headDots = [NSMutableArray arrayWithCapacity:32];
        _snapLines = [NSMutableArray arrayWithCapacity:32];
        _boxColors = [NSMutableArray arrayWithCapacity:32];
        _healthTexts = [NSMutableArray arrayWithCapacity:32];
        _dists = [NSMutableArray arrayWithCapacity:32];
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) {
        return;
    }
    
    // Stream mode: no ESP at all, so a capture never shows boxes/names/tracers.
    if (gStreamMode) {
        return;
    }
    
    static UIFont *fontBold11 = nil;
    static UIFont *fontBold9 = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fontBold11 = [UIFont boldSystemFontOfSize:11];
        fontBold9 = [UIFont boldSystemFontOfSize:9];
    });
    
    NSDictionary *a = @{
        NSFontAttributeName: fontBold11 ?: [UIFont boldSystemFontOfSize:11],
        NSForegroundColorAttributeName: gNameColor ?: [UIColor whiteColor]
    };
    
    NSDictionary *fa = @{
        NSFontAttributeName: fontBold9 ?: [UIFont boldSystemFontOfSize:9],
        NSForegroundColorAttributeName: [UIColor whiteColor]
    };
    
    // ---- tracers -------------------------------------------------------
    if (gTracersEnabled && self.tracers.count > 0) {
        CGContextSetLineWidth(ctx, 1.0);
        CGContextSetStrokeColorWithColor(ctx, (gTracerColor ?: [UIColor whiteColor]).CGColor);
        CGFloat cx = rect.size.width / 2.0f;
        CGFloat cy = rect.size.height / 2.0f;
        for (NSValue *v in self.tracers) {
            CGPoint endPt = [v CGPointValue];
            CGContextMoveToPoint(ctx, cx, cy);
            CGContextAddLineToPoint(ctx, endPt.x, endPt.y);
        }
        CGContextStrokePath(ctx);
    }
    
    // ---- boxes / names / hp -------------------------------------------
    if (gEspEnabled || gHotEspEnabled) {
        float boxW = gBoxThickness.load();
        if (!std::isfinite(boxW) || boxW < 0.5f) {
            boxW = 1.0f;
        }
        int hbStyle = gHealthBarStyle.load();
        float hbWidth = gHealthBarWidth.load();
        if (!std::isfinite(hbWidth) || hbWidth < 1.0f) {
            hbWidth = 2.0f;
        }
        bool filled = gBoxFilled.load();
        float fillAlpha = gBoxFillAlpha.load();
        if (!std::isfinite(fillAlpha)) {
            fillAlpha = 0.12f;
        }
        bool gradient = gEspHealthGradient.load();
        bool armorBar = gEspArmorBar.load();
        bool distAbove = gDistanceAbove.load();
        int distFmt = gDistanceFormat.load();
        
        for (NSUInteger i = 0; i < self.boxes.count; i++) {
            CGRect r = [self.boxes[i] CGRectValue];
            UIColor *bc = (i < self.boxColors.count) ? self.boxColors[i] : gBoxColor;
            if (!bc) {
                bc = [UIColor redColor];
            }
            
            float fade = 1.0f;
            if (gEspFadeEnabled.load() && i < self.dists.count) {
                float d = [self.dists[i] floatValue];
                float s = gEspFadeStart.load();
                float e = gEspFadeEnd.load();
                if (std::isfinite(d) && std::isfinite(s) && std::isfinite(e) && e > s) {
                    fade = 1.0f - Math::Clamp((d - s) / (e - s), 0.0f, 1.0f);
                    fade = Math::Clamp(fade, 0.15f, 1.0f);
                }
            }
            
            UIColor *stroke = [bc colorWithAlphaComponent:fade];
            CGContextSetStrokeColorWithColor(ctx, stroke.CGColor);
            CGContextSetLineWidth(ctx, boxW);
            
            if (filled) {
                CGContextSetFillColorWithColor(ctx, [bc colorWithAlphaComponent:fillAlpha * fade].CGColor);
                CGContextFillRect(ctx, r);
            }
            
            int boxStyle = gBoxStyle.load();
            if (boxStyle == 1) {
                CGFloat cl = MIN(r.size.width, r.size.height) * gBoxCornerLen.load();
                CGContextMoveToPoint(ctx, r.origin.x, r.origin.y + cl);
                CGContextAddLineToPoint(ctx, r.origin.x, r.origin.y);
                CGContextAddLineToPoint(ctx, r.origin.x + cl, r.origin.y);
                CGContextMoveToPoint(ctx, r.origin.x + r.size.width - cl, r.origin.y);
                CGContextAddLineToPoint(ctx, r.origin.x + r.size.width, r.origin.y);
                CGContextAddLineToPoint(ctx, r.origin.x + r.size.width, r.origin.y + cl);
                CGContextMoveToPoint(ctx, r.origin.x + r.size.width, r.origin.y + r.size.height - cl);
                CGContextAddLineToPoint(ctx, r.origin.x + r.size.width, r.origin.y + r.size.height);
                CGContextAddLineToPoint(ctx, r.origin.x + r.size.width - cl, r.origin.y + r.size.height);
                CGContextMoveToPoint(ctx, r.origin.x + cl, r.origin.y + r.size.height);
                CGContextAddLineToPoint(ctx, r.origin.x, r.origin.y + r.size.height);
                CGContextAddLineToPoint(ctx, r.origin.x, r.origin.y + r.size.height - cl);
                CGContextStrokePath(ctx);
            } else {
                CGContextStrokeRect(ctx, r);
            }
            
            if (gNameEnabled && i < self.names.count && i < self.nameTexts.count) {
                NSString *name = SafeStr(self.names[i]);
                CGPoint pt = [self.nameTexts[i] CGPointValue];
                CGSize size = [name sizeWithAttributes:a];
                CGFloat nx = pt.x - size.width / 2.0f;
                if (gNameBgEnabled.load()) {
                    CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.0 alpha:0.45 * fade].CGColor);
                    CGContextFillRect(ctx, CGRectMake(nx - 2.0f, pt.y - 1.0f, size.width + 4.0f, size.height + 2.0f));
                }
                NSDictionary *na = @{
                    NSFontAttributeName: fontBold11 ?: [UIFont boldSystemFontOfSize:11],
                    NSForegroundColorAttributeName: [(gNameColor ?: [UIColor whiteColor]) colorWithAlphaComponent:fade]
                };
                [name drawAtPoint:CGPointMake(nx, pt.y) withAttributes:na];
            }
            
            if (i < self.labels.count) {
                NSString *lbl = SafeStr(self.labels[i]);
                if (distFmt == 1 && i < self.dists.count) {
                    lbl = SafeFmt(@"%.0f", [self.dists[i] floatValue]);
                }
                CGSize size = [lbl sizeWithAttributes:fa];
                CGFloat lx = r.origin.x + r.size.width + 2.0f;
                CGFloat ly = r.origin.y + r.size.height / 2.0f - size.height / 2.0f;
                if (distAbove) {
                    lx = r.origin.x + r.size.width / 2.0f - size.width / 2.0f;
                    ly = r.origin.y - size.height - 2.0f;
                }
                if (gEspDistanceShadow.load()) {
                    NSDictionary *sa = @{
                        NSFontAttributeName: fontBold9 ?: [UIFont boldSystemFontOfSize:9],
                        NSForegroundColorAttributeName: [[UIColor blackColor] colorWithAlphaComponent:0.8 * fade]
                    };
                    [lbl drawAtPoint:CGPointMake(lx + 1.0f, ly + 1.0f) withAttributes:sa];
                }
                NSDictionary *la = @{
                    NSFontAttributeName: fontBold9 ?: [UIFont boldSystemFontOfSize:9],
                    NSForegroundColorAttributeName: [[UIColor whiteColor] colorWithAlphaComponent:fade]
                };
                [lbl drawAtPoint:CGPointMake(lx, ly) withAttributes:la];
            }
            
            if (gHealthTextEnabled && i < self.healthTexts.count) {
                NSString *hp = SafeStr(self.healthTexts[i]);
                CGSize hsz = [hp sizeWithAttributes:fa];
                [hp drawAtPoint:CGPointMake(r.origin.x + r.size.width / 2.0f - hsz.width / 2.0f, r.origin.y + r.size.height + 2.0f) withAttributes:fa];
            }
            
            if (gHealthBarEnabled && i < self.hps.count) {
                float h = [self.hps[i] floatValue];
                float aa = (i < self.armors.count) ? [self.armors[i] floatValue] : 0.0f;
                if (!std::isfinite(h)) h = 0.0f;
                if (!std::isfinite(aa)) aa = 0.0f;
                float ht = r.size.height;
                float pct = Math::Clamp(h / 100.0f, 0.0f, 1.0f);
                
                CGRect bg, fg;
                if (hbStyle == 2) {
                    bg = CGRectMake(r.origin.x, r.origin.y - hbWidth - 2.0f, r.size.width, hbWidth);
                    fg = CGRectMake(r.origin.x, r.origin.y - hbWidth - 2.0f, r.size.width * pct, hbWidth);
                } else if (hbStyle == 1) {
                    bg = CGRectMake(r.origin.x + r.size.width + 3.0f, r.origin.y, hbWidth, ht);
                    fg = CGRectMake(r.origin.x + r.size.width + 3.0f, r.origin.y + ht * (1.0f - pct), hbWidth, ht * pct);
                } else {
                    bg = CGRectMake(r.origin.x - hbWidth - 3.0f, r.origin.y, hbWidth, ht);
                    fg = CGRectMake(r.origin.x - hbWidth - 3.0f, r.origin.y + ht * (1.0f - pct), hbWidth, ht * pct);
                }
                
                CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.1 alpha:0.8 * fade].CGColor);
                CGContextFillRect(ctx, bg);
                
                UIColor *hpColor = gradient
                    ? [UIColor colorWithRed:(1.0f - pct) green:pct blue:0.0f alpha:fade]
                    : [UIColor colorWithRed:0.2f green:0.9f blue:0.3f alpha:fade];
                CGContextSetFillColorWithColor(ctx, hpColor.CGColor);
                CGContextFillRect(ctx, fg);
                
                if (armorBar && aa > 0) {
                    float apct = Math::Clamp(aa / 100.0f, 0.0f, 1.0f);
                    CGRect abg, afg;
                    if (hbStyle == 2) {
                        abg = CGRectMake(r.origin.x, r.origin.y - hbWidth * 2.0f - 4.0f, r.size.width, hbWidth);
                        afg = CGRectMake(r.origin.x, r.origin.y - hbWidth * 2.0f - 4.0f, r.size.width * apct, hbWidth);
                    } else if (hbStyle == 1) {
                        abg = CGRectMake(r.origin.x + r.size.width + 3.0f + hbWidth + 1.0f, r.origin.y, hbWidth, ht);
                        afg = CGRectMake(r.origin.x + r.size.width + 3.0f + hbWidth + 1.0f, r.origin.y + ht * (1.0f - apct), hbWidth, ht * apct);
                    } else {
                        abg = CGRectMake(r.origin.x - hbWidth * 2.0f - 4.0f, r.origin.y, hbWidth, ht);
                        afg = CGRectMake(r.origin.x - hbWidth * 2.0f - 4.0f, r.origin.y + ht * (1.0f - apct), hbWidth, ht * apct);
                    }
                    CGContextSetFillColorWithColor(ctx, [UIColor colorWithRed:0.2 green:0.5 blue:1 alpha:0.5 * fade].CGColor);
                    CGContextFillRect(ctx, abg);
                    CGContextSetFillColorWithColor(ctx, [UIColor colorWithRed:0.4 green:0.8 blue:1 alpha:fade].CGColor);
                    CGContextFillRect(ctx, afg);
                }
            }
        }
    }
    
    // ---- weapon esp ----------------------------------------------------
    if (gWeaponEspEnabled.load() && self.weaponBoxes.count > 0) {
        float ww = gWeaponEspThickness.load();
        if (!std::isfinite(ww) || ww < 0.5f) ww = 1.0f;
        CGContextSetLineWidth(ctx, ww);
        CGContextSetStrokeColorWithColor(ctx, (gWeaponEspColor ?: [UIColor orangeColor]).CGColor);
        for (NSValue *v in self.weaponBoxes) {
            CGContextStrokeRect(ctx, [v CGRectValue]);
        }
        NSDictionary *wa = @{
            NSFontAttributeName: fontBold9 ?: [UIFont boldSystemFontOfSize:9],
            NSForegroundColorAttributeName: gWeaponEspColor ?: [UIColor orangeColor]
        };
        for (NSUInteger i = 0; i < self.weaponLabels.count && i < self.weaponBoxes.count; i++) {
            CGRect r = [self.weaponBoxes[i] CGRectValue];
            NSString *lbl = SafeStr(self.weaponLabels[i]);
            CGSize sz = [lbl sizeWithAttributes:wa];
            [lbl drawAtPoint:CGPointMake(r.origin.x + r.size.width / 2.0f - sz.width / 2.0f, r.origin.y - sz.height - 1.0f) withAttributes:wa];
        }
    }
    
    // ---- skeleton ------------------------------------------------------
    if (gSkeletonEnabled && self.skeletonLines.count > 0) {
        CGContextSetStrokeColorWithColor(ctx, (gSkelColor ?: [UIColor greenColor]).CGColor);
        CGContextSetLineWidth(ctx, gSkelThickness.load());
        for (NSValue *v in self.skeletonLines) {
            CGRect r = [v CGRectValue];
            CGContextMoveToPoint(ctx, r.origin.x, r.origin.y);
            CGContextAddLineToPoint(ctx, r.size.width, r.size.height);
        }
        CGContextStrokePath(ctx);
    }
    
    // ---- head dots -----------------------------------------------------
    if (gHeadDotEnabled && self.headDots.count > 0) {
        float hd = gHeadDotSize.load();
        if (!std::isfinite(hd) || hd < 1.0f) hd = 2.5f;
        for (NSUInteger i = 0; i < self.headDots.count; i++) {
            CGPoint p = [self.headDots[i] CGPointValue];
            UIColor *hc = (i < self.boxColors.count) ? self.boxColors[i] : (gBoxColor ?: [UIColor redColor]);
            CGContextSetFillColorWithColor(ctx, (hc ?: [UIColor redColor]).CGColor);
            CGContextFillEllipseInRect(ctx, CGRectMake(p.x - hd, p.y - hd, hd * 2.0f, hd * 2.0f));
        }
    }
    
    // ---- snap lines ----------------------------------------------------
    if (gSnapBottomEnabled && self.snapLines.count > 0) {
        CGContextSetLineWidth(ctx, 1.0);
        CGContextSetStrokeColorWithColor(ctx, (gTracerColor ?: [UIColor whiteColor]).CGColor);
        CGFloat bx = rect.size.width / 2.0f;
        CGFloat by = rect.size.height;
        for (NSValue *v in self.snapLines) {
            CGPoint p = [v CGPointValue];
            CGContextMoveToPoint(ctx, bx, by);
            CGContextAddLineToPoint(ctx, p.x, p.y);
        }
        CGContextStrokePath(ctx);
    }
    
    // ---- offscreen arrows ---------------------------------------------
    if (gOofEnabled && gEspOffscreenArrows.load() && self.oofDirs.count > 0) {
        float oofW = gOofThickness.load();
        if (!std::isfinite(oofW) || oofW < 0.5f) oofW = 2.0f;
        float oofS = gOofSize.load();
        if (!std::isfinite(oofS) || oofS < 4.0f) oofS = 12.0f;
        CGContextSetLineWidth(ctx, oofW);
        CGContextSetStrokeColorWithColor(ctx, (gOofColor ?: [UIColor whiteColor]).CGColor);
        
        CGFloat cx = rect.size.width / 2.0f;
        CGFloat cy = rect.size.height / 2.0f;
        CGFloat margin = gEspOffscreenMargin.load();
        if (!std::isfinite(margin) || margin < 10.0f) margin = 40.0f;
        CGFloat R = MIN(rect.size.width, rect.size.height) / 2.0f - margin;
        
        for (NSValue *v in self.oofDirs) {
            CGPoint dir = [v CGPointValue];
            CGFloat ex = cx + dir.x * R;
            CGFloat ey = cy + dir.y * R;
            CGFloat ang = atan2(dir.y, dir.x);
            CGFloat ax1 = ex + cosf(ang + 2.5f) * oofS;
            CGFloat ay1 = ey + sinf(ang + 2.5f) * oofS;
            CGFloat ax2 = ex + cosf(ang - 2.5f) * oofS;
            CGFloat ay2 = ey + sinf(ang - 2.5f) * oofS;
            CGContextMoveToPoint(ctx, ax1, ay1);
            CGContextAddLineToPoint(ctx, ex, ey);
            CGContextAddLineToPoint(ctx, ax2, ay2);
            CGContextStrokePath(ctx);
        }
    }
}

@end

@interface MenuView : UIView
- (void)togglePlayerChamsMenu:(UIButton*)sender;
- (void)toggleWeaponChamsMenu:(UIButton*)sender;
- (void)selectPlayerChamsMat:(UIButton*)sender;
- (void)selectWeaponChamsMat:(UIButton*)sender;
- (void)skyPresetTap:(UIButton*)sender;
@end

@interface HotZoneView : UIView
@end

@interface HotkeyView : UIView
@property (nonatomic, strong) UIButton *hkbAimbot;
@property (nonatomic, strong) UIButton *hkbAimFire;
@property (nonatomic, strong) UIButton *hkbEsp;
@property (nonatomic, strong) UILabel *dragHandle;
- (void)updateTitles;
@end

static ESPView* gEspView = nil;
static MenuView* gMenuView = nil;
static HotZoneView* gHotZone = nil;
static WatermarkView* gWatermark = nil;
static ColorPickerView* gColorPicker = nil;
static UIWindow* gMainWin = nil;
static UIView* gOverlayContainer = nil;
static UITextField* gSecureField = nil;
static HotkeyView* gHotkeyView = nil;
static SnowView* gSnowOverlay = nil;
static void RefreshHotkeyView(void);
static void ApplyFpsLimit(void);

static void SnowOverlaySetEnabled(bool enabled) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (enabled) {
            if (!gSnowOverlay && gOverlayContainer) {
                gSnowOverlay = [[SnowView alloc] initWithFrame:gOverlayContainer.bounds];
                gSnowOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                [gOverlayContainer insertSubview:gSnowOverlay atIndex:0];
            }
            gSnowOverlay.hidden = NO;
        } else {
            gSnowOverlay.hidden = YES;
        }
    });
}

@interface PassthroughView : UIView
@end

@implementation PassthroughView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    return v == self ? nil : v;
}

@end

@interface SecureTextField : UITextField
@end

@implementation SecureTextField

- (BOOL)canBecomeFirstResponder {
    return NO;
}

- (BOOL)becomeFirstResponder {
    return NO;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    return (v == self || !v) ? nil : v;
}

@end

static void UpdateStreamMode(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!gOverlayContainer || !gMainWin) {
                return;
            }
            RefreshHotkeyView();
            
            if (gStreamMode) {
                RestoreAllChams();
                gWatermark.hidden = YES;
                gHotkeyView.hidden = YES;
                gMenuView.hidden = YES;
                
                if (!gSecureField) {
                    gSecureField = [[SecureTextField alloc] initWithFrame:gMainWin.bounds];
                    gSecureField.secureTextEntry = YES;
                    gSecureField.backgroundColor = [UIColor clearColor];
                    gSecureField.userInteractionEnabled = YES;
                    gSecureField.text = @" ";
                }
                
                if (gSecureField.superview != gMainWin) {
                    [gMainWin addSubview:gSecureField];
                }
                [gMainWin bringSubviewToFront:gSecureField];
                
                UIView *canvas = nil;
                for (UIView *sub in gSecureField.subviews) {
                    if ([NSStringFromClass([sub class]) containsString:@"Canvas"] || [NSStringFromClass([sub class]) containsString:@"ContentView"]) {
                        canvas = sub;
                        break;
                    }
                }
                
                if (!canvas && gSecureField.subviews.count > 0) {
                    canvas = gSecureField.subviews[0];
                }
                
                [gOverlayContainer removeFromSuperview];
                if (canvas) {
                    canvas.userInteractionEnabled = YES;
                    [canvas addSubview:gOverlayContainer];
                } else {
                    [gSecureField addSubview:gOverlayContainer];
                }
            } else {
                gWatermark.hidden = NO;
                gHotkeyView.hidden = gMenuOpen;
                [gOverlayContainer removeFromSuperview];
                [gMainWin addSubview:gOverlayContainer];
                
                if (gSecureField) {
                    [gSecureField removeFromSuperview];
                }
            }
        } @catch (NSException* e) {
        }
    });
}

@implementation HotZoneView

- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;
        
        UITapGestureRecognizer *t = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapAction)];
        t.numberOfTapsRequired = 3;
        [self addGestureRecognizer:t];
    }
    return self;
}

- (void)tapAction {
    @try {
        bool open = !gMenuOpen;
        gMenuOpen = open;
        
        if (open) {
            gHotZone.hidden = YES;
            gEspView.hidden = YES;
            gWatermark.hidden = YES;
            gHotkeyView.hidden = YES;
            gMenuView.hidden = NO;
            gMenuView.alpha = 0;
            gMenuView.transform = CGAffineTransformMakeScale(0.95, 0.95);
            
            [gOverlayContainer bringSubviewToFront:gMenuView];
            
            [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.5 options:UIViewAnimationOptionAllowUserInteraction animations:^{
                gMenuView.alpha = 1.0;
                gMenuView.transform = CGAffineTransformIdentity;
            } completion:nil];
        } else {
            gMenuOpen = false;
            [UIView animateWithDuration:0.25 animations:^{
                gMenuView.transform = CGAffineTransformMakeScale(0.95, 0.95);
                gMenuView.alpha = 0.0;
            } completion:^(BOOL finished) {
                gMenuView.hidden = YES;
                gMenuView.transform = CGAffineTransformIdentity;
                gMenuView.alpha = 1.0;
                gHotZone.hidden = NO;
                gEspView.hidden = NO;
                RefreshHotkeyView();
                gHotkeyView.hidden = gStreamMode;
                if (!gStreamMode) {
                    gWatermark.hidden = NO;
                }
            }];
        }
    } @catch (NSException* e) {
    }
}

@end

// ---------------------------------------------------------------------------------------------
// Menu building blocks shared by the RAGE tab.
//
// The RAGE tab has ~40 rows; without these three helpers the tab would be 600 lines of
// copy-pasted checkbox wiring, and a missed [ConfigManager save] in one of them is exactly the
// class of bug that silently loses a setting.
// ---------------------------------------------------------------------------------------------
static NLCheckbox* RageMakeCheckbox(BOOL on, void (^toggle)(BOOL)) {
    NLCheckbox *cb = [[NLCheckbox alloc] initWithFrame:CGRectMake(0, 0, 18, 18)];
    cb.isOn = on;
    cb.onToggle = toggle;
    return cb;
}

static NLSlider* RageMakeSlider(float value, float lo, float hi, NSString* suffix,
                                void (^change)(float), void (^release)(float)) {
    NLSlider *s = [[NLSlider alloc] initWithFrame:CGRectMake(0, 0, 110, 18) suffix:suffix];
    s.min = lo;
    s.max = hi;
    s.value = value;
    s.onChange = change;
    s.onRelease = release;
    return s;
}

// A button that cycles through a fixed list of labels and reports the chosen index.
static NLButton* RageMakeCycle(NSString* initial, NSArray<NSString*>* labels, NSInteger index,
                               void (^onPick)(NSInteger)) {
    NLButton *b = [[NLButton alloc] initWithTitle:initial];
    __block NSInteger cur = index;
    b.onTap = ^{
        cur += 1;
        if (cur >= (NSInteger)labels.count) {
            cur = 0;
        }
        [b.titleLabel setText:[labels objectAtIndex:cur]];
        onPick(cur);
    };
    return b;
}

@implementation MenuView {
    UIVisualEffectView *_blurView;
    UIView *_sidebar;
    UIView *_topBar;
    UIView *_content;
    UIScrollView *_scrollView;
    NSMutableArray *_tabs;
    int _currentTab;
    BOOL _isMinimized;
    CGRect _origFrame;
}

static const CGFloat kSidebarW = 108.0;

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _origFrame = frame;
        self.layer.cornerRadius = 12;
        self.clipsToBounds = YES;
        self.userInteractionEnabled = YES;
        self.layer.borderWidth = 1;
        self.layer.borderColor = [NLAccent() colorWithAlphaComponent:0.35].CGColor;
        
        _blurView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
        _blurView.frame = self.bounds;
        _blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_blurView];
        
        CAGradientLayer *grad = [CAGradientLayer layer];
        grad.frame = self.bounds;
        grad.colors = @[(id)[UIColor colorWithRed:0.035 green:0.035 blue:0.047 alpha:0.92].CGColor,
                        (id)[UIColor colorWithRed:0.075 green:0.055 blue:0.115 alpha:0.92].CGColor];
        grad.startPoint = CGPointMake(0, 0);
        grad.endPoint = CGPointMake(1, 1);
        [self.layer insertSublayer:grad atIndex:0];
        
        SnowView *menuSnow = [[SnowView alloc] initWithFrame:self.bounds];
        menuSnow.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        menuSnow.userInteractionEnabled = NO;
        [self addSubview:menuSnow];
        
        _sidebar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kSidebarW, frame.size.height)];
        _sidebar.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.28];
        _sidebar.layer.borderWidth = 0.5;
        _sidebar.layer.borderColor = NLBorder().CGColor;
        [self addSubview:_sidebar];
        
        UILabel *brand = [[UILabel alloc] initWithFrame:CGRectMake(14, 14, kSidebarW - 20, 18)];
        brand.text = @"FLOPDLC";
        brand.textColor = [UIColor whiteColor];
        brand.font = [UIFont systemFontOfSize:12 weight:UIFontWeightHeavy];
        [_sidebar addSubview:brand];
        
        UILabel *brandSub = [[UILabel alloc] initWithFrame:CGRectMake(14, 30, kSidebarW - 20, 12)];
        brandSub.text = @"v136.3";
        brandSub.textColor = NLAccent();
        brandSub.font = [UIFont systemFontOfSize:8 weight:UIFontWeightBold];
        [_sidebar addSubview:brandSub];
        
        UIView *userCard = [[UIView alloc] initWithFrame:CGRectMake(8, frame.size.height - 56, kSidebarW - 16, 44)];
        userCard.backgroundColor = NLSurfaceHi();
        userCard.layer.cornerRadius = 8;
        userCard.layer.borderWidth = 1;
        userCard.layer.borderColor = NLBorder().CGColor;
        [_sidebar addSubview:userCard];
        
        UIView *avatar = [[UIView alloc] initWithFrame:CGRectMake(8, 8, 28, 28)];
        avatar.backgroundColor = NLAccent();
        avatar.layer.cornerRadius = 14;
        [userCard addSubview:avatar];
        
        UILabel *avatarText = [[UILabel alloc] initWithFrame:avatar.bounds];
        avatarText.text = @"F";
        avatarText.textColor = [UIColor whiteColor];
        avatarText.textAlignment = NSTextAlignmentCenter;
        avatarText.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
        [avatar addSubview:avatarText];
        
        UILabel *userName = [[UILabel alloc] initWithFrame:CGRectMake(44, 8, kSidebarW - 60, 14)];
        userName.text = @"Player";
        userName.textColor = [UIColor whiteColor];
        userName.font = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
        [userCard addSubview:userName];
        
        UILabel *userRole = [[UILabel alloc] initWithFrame:CGRectMake(44, 22, kSidebarW - 60, 12)];
        userRole.text = @"User";
        userRole.textColor = NLTextDim();
        userRole.font = [UIFont systemFontOfSize:8 weight:UIFontWeightMedium];
        [userCard addSubview:userRole];
        
        _topBar = [[UIView alloc] initWithFrame:CGRectMake(kSidebarW, 0, frame.size.width - kSidebarW, 35)];
        _topBar.backgroundColor = [UIColor clearColor];
        _topBar.layer.borderWidth = 0.5;
        _topBar.layer.borderColor = NLBorder().CGColor;
        _topBar.userInteractionEnabled = YES;
        
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panAction:)];
        [_topBar addGestureRecognizer:pan];
        [self addSubview:_topBar];
        
        UILabel *pageTitle = [[UILabel alloc] initWithFrame:CGRectMake(14, 0, 160, 35)];
        pageTitle.text = @"Dashboard";
        pageTitle.textColor = [UIColor whiteColor];
        pageTitle.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        [_topBar addSubview:pageTitle];
        
        _tabs = [NSMutableArray array];
        // LEGIT first, RAGE right beside it: the two aim tabs stay adjacent so switching
        // between the legit aimbot and the rage pipeline is one tap.
        [self addTab:@"LEGIT" x:112];
        [self addTab:@"RAGE" x:162];
        [self addTab:@"VISUALS" x:212];
        [self addTab:@"WORLD" x:262];
        [self addTab:@"PLAYER" x:312];
        [self addTab:@"MISC" x:362];
        [self addTab:@"SETTINGS" x:412];
        [self addTab:@"SKINS" x:462];
        [self addTab:@"CONFIG" x:512];
        
        UIButton *cfg = [UIButton buttonWithType:UIButtonTypeCustom];
        cfg.frame = CGRectMake(_topBar.bounds.size.width - 90, 10, 15, 15);
        [cfg setImage:[UIImage systemImageNamed:@"gearshape"] forState:UIControlStateNormal];
        cfg.tintColor = NLTextDim();
        [cfg addTarget:self action:@selector(openSettings) forControlEvents:UIControlEventTouchUpInside];
        [_topBar addSubview:cfg];
        
        UIButton *mb = [UIButton buttonWithType:UIButtonTypeCustom];
        mb.frame = CGRectMake(_topBar.bounds.size.width - 60, 10, 15, 15);
        [mb setImage:[UIImage systemImageNamed:@"minus"] forState:UIControlStateNormal];
        mb.tintColor = [UIColor lightGrayColor];
        [mb addTarget:self action:@selector(minimizeAction) forControlEvents:UIControlEventTouchUpInside];
        [_topBar addSubview:mb];
        
        UIButton *cb = [UIButton buttonWithType:UIButtonTypeCustom];
        cb.frame = CGRectMake(_topBar.bounds.size.width - 30, 10, 15, 15);
        [cb setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
        cb.tintColor = [UIColor lightGrayColor];
        [cb addTarget:self action:@selector(closeAction) forControlEvents:UIControlEventTouchUpInside];
        [_topBar addSubview:cb];
        
        _content = [[UIView alloc] initWithFrame:CGRectMake(kSidebarW, 35, frame.size.width - kSidebarW, frame.size.height - 35)];
        [self addSubview:_content];
        
        _scrollView = [[UIScrollView alloc] initWithFrame:_content.bounds];
        _scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _scrollView.showsVerticalScrollIndicator = NO;
        // VISUALS is the tallest tab (the third-person group sits at y 2660 + 240), so the
        // scroll area has to cover it.
        _scrollView.contentSize = CGSizeMake(frame.size.width - kSidebarW, 3400);
        [_content addSubview:_scrollView];
        
        [self switchToTab:0];
    }
    return self;
}

- (void)showColorPickerForSwatch:(NLColorSwatch*)swatch currentColor:(UIColor*)color saveKey:(NSString*)key {
    @try {
        if (gColorPicker) {
            [gColorPicker removeFromSuperview];
        }
        if (!swatch || !key) {
            return;
        }
        
        gColorPicker = [[ColorPickerView alloc] initWithFrame:CGRectMake((self.bounds.size.width - 300)/2, (self.bounds.size.height - 400)/2, 300, 400) currentColor:color ?: [UIColor whiteColor]];
        
        __weak NLColorSwatch *weakSwatch = swatch;
        __weak NSString *weakKey = key;
        __weak MenuView* weakSelf = self;
        
        gColorPicker.onColorSelected = ^(UIColor *newColor) {
            if (!newColor || !weakSwatch || !weakKey) {
                return;
            }
            
            weakSwatch.color = newColor;
            
            if ([weakKey isEqualToString:@"c_b"]) {
                gBoxColor = newColor;
            } else if ([weakKey isEqualToString:@"c_s"]) {
                gSkelColor = newColor;
            } else if ([weakKey isEqualToString:@"c_n"]) {
                gNameColor = newColor;
            } else if ([weakKey isEqualToString:@"c_t"]) {
                gTracerColor = newColor;
            } else if ([weakKey isEqualToString:@"v_sky_c"]) {
                CGFloat r, g, b, a;
                [newColor getRed:&r green:&g blue:&b alpha:&a];
                uint32_t hex = ((int)(r*255) << 24) | ((int)(g*255) << 16) | ((int)(b*255) << 8) | (int)(a*255);
                gSkyboxColorHex = hex;
                gSkyboxDirty = true;
                [[NSUserDefaults standardUserDefaults] setInteger:(NSInteger)hex forKey:weakKey];
                [[NSUserDefaults standardUserDefaults] synchronize];
                return;
            } else if ([weakKey isEqualToString:@"v_chams_pl_c"]) {
                CGFloat r, g, b, a;
                [newColor getRed:&r green:&g blue:&b alpha:&a];
                uint32_t hex = ((int)(r*255) << 24) | ((int)(g*255) << 16) | ((int)(b*255) << 8) | (int)(a*255);
                gChamsPlayerColor = hex;
                gChamsPlayerColorDirty = true;
                [[NSUserDefaults standardUserDefaults] setInteger:(NSInteger)hex forKey:weakKey];
                [[NSUserDefaults standardUserDefaults] synchronize];
                return;
            } else if ([weakKey isEqualToString:@"v_chams_wep_c"]) {
                CGFloat r, g, b, a;
                [newColor getRed:&r green:&g blue:&b alpha:&a];
                uint32_t hex = ((int)(r*255) << 24) | ((int)(g*255) << 16) | ((int)(b*255) << 8) | (int)(a*255);
                gChamsWeaponColor = hex;
                gChamsWeaponColorDirty = true;
                [[NSUserDefaults standardUserDefaults] setInteger:(NSInteger)hex forKey:weakKey];
                [[NSUserDefaults standardUserDefaults] synchronize];
                return;
            } else if ([weakKey isEqualToString:@"wv_amb_c"]) {
                CGFloat r, g, b, a;
                [newColor getRed:&r green:&g blue:&b alpha:&a];
                uint32_t hex = ((int)(r*255) << 24) | ((int)(g*255) << 16) | ((int)(b*255) << 8) | (int)(a*255);
                gAmbientColorHex = hex;
                [[NSUserDefaults standardUserDefaults] setInteger:(NSInteger)hex forKey:weakKey];
                [[NSUserDefaults standardUserDefaults] synchronize];
                return;
            }
            
            else if ([weakKey isEqualToString:@"c_team"]) {
                gTeamColor = newColor;
            } else if ([weakKey isEqualToString:@"c_vis"]) {
                gVisibleColor = newColor;
            } else if ([weakKey isEqualToString:@"c_hid"]) {
                gHiddenColor = newColor;
            } else if ([weakKey isEqualToString:@"c_hm"]) {
                gHitMarkerColor = newColor;
            } else if ([weakKey isEqualToString:@"c_dn"]) {
                gDamageNumberColor = newColor;
            } else if ([weakKey isEqualToString:@"c_radar"]) {
                gRadarColor = newColor;
            } else if ([weakKey isEqualToString:@"c_cross"]) {
                gCrosshairColor = newColor;
            } else if ([weakKey isEqualToString:@"c_fov"]) {
                gFovCircleColor = newColor;
            } else if ([weakKey isEqualToString:@"c_plist"]) {
                gPlayerListColor = newColor;
            } else if ([weakKey isEqualToString:@"c_elog"]) {
                gEventLogColor = newColor;
            } else if ([weakKey isEqualToString:@"c_kf"]) {
                gKillFeedColor = newColor;
            } else if ([weakKey isEqualToString:@"c_oof"]) {
                gOofColor = newColor;
            } else if ([weakKey isEqualToString:@"c_wm"]) {
                gWatermarkAccent = newColor;
                [gWatermark applyStyle];
            } else if ([weakKey isEqualToString:@"c_ip"]) {
                gInfoPanelColor = newColor;
            } else if ([weakKey isEqualToString:@"c_wep"]) {
                gWeaponEspColor = newColor;
            } else if ([weakKey isEqualToString:@"c_stats"]) {
                gStatsColor = newColor;
            } else if ([weakKey isEqualToString:@"c_ai"]) {
                gAimInfoColor = newColor;
            } else if ([weakKey isEqualToString:@"c_dl"]) {
                gDamageLogColor = newColor;
            } else if ([weakKey isEqualToString:@"m_accent"]) {
                gMenuAccent = newColor;
                [weakSelf buildContent];
            }
            
            [ConfigManager saveColor:newColor forKey:weakKey];
        };
        
        UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        closeBtn.frame = CGRectMake(gColorPicker.bounds.size.width - 40, 10, 30, 30);
        [closeBtn setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
        closeBtn.tintColor = [UIColor whiteColor];
        [closeBtn addTarget:self action:@selector(closeColorPicker) forControlEvents:UIControlEventTouchUpInside];
        [gColorPicker addSubview:closeBtn];
        
        [self addSubview:gColorPicker];
        
        gColorPicker.transform = CGAffineTransformMakeScale(0.8, 0.8);
        gColorPicker.alpha = 0;
        
        [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.6 initialSpringVelocity:0.5 options:UIViewAnimationOptionAllowUserInteraction animations:^{
            gColorPicker.transform = CGAffineTransformIdentity;
            gColorPicker.alpha = 1;
        } completion:nil];
    } @catch (NSException* e) {
    }
}

- (void)closeColorPicker {
    if (!gColorPicker) {
        return;
    }
    [UIView animateWithDuration:0.2 animations:^{
        gColorPicker.alpha = 0;
        gColorPicker.transform = CGAffineTransformMakeScale(0.8, 0.8);
    } completion:^(BOOL finished) {
        [gColorPicker removeFromSuperview];
        gColorPicker = nil;
    }];
}

static NSString* NLIconForTab(NSString* title) {
    if ([title isEqualToString:@"LEGIT"]) return @"scope";
    if ([title isEqualToString:@"RAGE"]) return @"flame";
    if ([title isEqualToString:@"VISUALS"]) return @"eye";
    if ([title isEqualToString:@"WORLD"]) return @"globe";
    if ([title isEqualToString:@"PLAYER"]) return @"person";
    if ([title isEqualToString:@"MISC"]) return @"wrench.and.screwdriver";
    if ([title isEqualToString:@"SETTINGS"]) return @"gearshape";
    if ([title isEqualToString:@"SKINS"]) return @"paintpalette";
    return nil;
}

- (void)addTab:(NSString*)title x:(CGFloat)x {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    NSUInteger idx = _tabs.count;
    b.frame = CGRectMake(8, 52 + idx * 34, kSidebarW - 16, 30);
    [b setTitle:SafeStr(title) forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
    b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    b.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 0);
    NSString *icon = NLIconForTab(title);
    if (icon) {
        [b setImage:[UIImage systemImageNamed:icon] forState:UIControlStateNormal];
        b.tintColor = NLTextDim();
        b.imageEdgeInsets = UIEdgeInsetsMake(0, 0, 0, 8);
    }
    [b setTitleColor:NLTextDim() forState:UIControlStateNormal];
    b.backgroundColor = [UIColor clearColor];
    b.layer.cornerRadius = 8;
    [b addTarget:self action:@selector(tabTap:) forControlEvents:UIControlEventTouchUpInside];
    [_sidebar addSubview:b];
    [_tabs addObject:b];
}

- (void)tabTap:(UIButton*)sender {
    NSUInteger idx = [_tabs indexOfObject:sender];
    if (idx != NSNotFound) {
        [self switchToTab:(int)idx];
    }
}

- (void)switchToTab:(int)tabIndex {
    _currentTab = tabIndex;
    
    for (int i = 0; i < (int)_tabs.count; i++) {
        UIButton *b = _tabs[i];
        if (i == tabIndex) {
            [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            b.tintColor = [UIColor whiteColor];
            b.backgroundColor = [NLAccent() colorWithAlphaComponent:0.18];
        } else {
            [b setTitleColor:NLTextDim() forState:UIControlStateNormal];
            b.tintColor = NLTextDim();
            b.backgroundColor = [UIColor clearColor];
        }
    }
    
    [self buildContent];
}

- (void)openSettings {
    [self switchToTab:6];
}

- (void)applyMenuStyle {
    CGFloat s = gMenuScale.load();
    if (!std::isfinite(s) || s < 0.5f) {
        s = 1.0f;
    }
    self.transform = CGAffineTransformMakeScale(s, s);
    _blurView.hidden = !gMenuBlurEnabled.load();
}

- (void)buildContent {
    @try {
        [self applyMenuStyle];
        __weak MenuView* weakSelf = self;
        
        for (UIView *v in _scrollView.subviews) {
            [v removeFromSuperview];
        }
        
        CGFloat colW = (_scrollView.bounds.size.width - 45) / 2;
        CGFloat yBase = 20;
        CGFloat columnHeight = MAX(0, _scrollView.contentSize.height - yBase);
        
        UIView *c1 = [[UIView alloc] initWithFrame:CGRectMake(15, yBase, colW, columnHeight)];
        UIView *c2 = [[UIView alloc] initWithFrame:CGRectMake(15 + colW + 15, yBase, colW, columnHeight)];
        [_scrollView addSubview:c1];
        [_scrollView addSubview:c2];
        
        if (_currentTab == 0) {
            NLGroupBox *gAuto = [[NLGroupBox alloc] initWithTitle:@"Auto" frame:CGRectMake(0, 0, colW, 350)];
            [c1 addSubview:gAuto];
            CGFloat y = 30;
            
            NLCheckbox *cbAim = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbAim.isOn = gAimbotEnabled;
            cbAim.onToggle = ^(BOOL v) {
                gAimbotEnabled = v;
                // Aimbot is useless if the shot is still fighting spread and recoil, so arming it
                // also arms both ballistics neutralisers (never switches them back off).
                LegitAimModeChanged(v);
                [ConfigManager save];
                [weakSelf buildContent];
            };
            [gAuto addSubview:[[NLRow alloc] initWithTitle:@"Aimbot" y:y control:cbAim swatch:nil]];
            y += 30;

            NLCheckbox *cbAimOnFire = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbAimOnFire.isOn = gAimOnFireEnabled;
            cbAimOnFire.onToggle = ^(BOOL v) {
                gAimOnFireEnabled = v;
                LegitAimModeChanged(v);
                [ConfigManager save];
                [weakSelf buildContent];
            };
            [gAuto addSubview:[[NLRow alloc] initWithTitle:@"Aim On Fire" y:y control:cbAimOnFire swatch:nil]];
            y += 30;

            // Mirrors the PLAYER-tab toggles so the forced-on state is visible right here.
            NLCheckbox *cbNS = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbNS.isOn = gNoSpreadEnabled;
            cbNS.onToggle = ^(BOOL v) {
                gNoSpreadEnabled = v;
                [ConfigManager save];
            };
            [gAuto addSubview:[[NLRow alloc] initWithTitle:@"No Spread" y:y control:cbNS swatch:nil]];
            y += 30;

            NLCheckbox *cbNR = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbNR.isOn = gNoRecoilEnabled;
            cbNR.onToggle = ^(BOOL v) {
                gNoRecoilEnabled = v;
                [ConfigManager save];
            };
            [gAuto addSubview:[[NLRow alloc] initWithTitle:@"No Recoil" y:y control:cbNR swatch:nil]];
            y += 30;
            
            NLButton *bBone = [[NLButton alloc] initWithTitle:@"Head"];
            __weak NLButton *weakBone = bBone;
            if (gAimBone == 10) [bBone.titleLabel setText:@"Head"];
            else if (gAimBone == 8) [bBone.titleLabel setText:@"Chest"];
            else [bBone.titleLabel setText:@"Hips"];
            
            bBone.onTap = ^{
                int cur = gAimBone;
                if (cur == 10) cur = 8;
                else if (cur == 8) cur = 0;
                else cur = 10;
                gAimBone = cur;
                
                if (cur == 10) [weakBone.titleLabel setText:@"Head"];
                else if (cur == 8) [weakBone.titleLabel setText:@"Chest"];
                else [weakBone.titleLabel setText:@"Hips"];
                
                [ConfigManager save];
            };
            [gAuto addSubview:[[NLRow alloc] initWithTitle:@"Target Bone" y:y control:bBone swatch:nil]];
            y += 30;
            
            NLCheckbox *cbSA = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbSA.isOn = gSilentAimEnabled;
            cbSA.onToggle = ^(BOOL v) {
                gSilentAimEnabled = v;
                [ConfigManager save];
            };
            [gAuto addSubview:[[NLRow alloc] initWithTitle:@"Silent Aim (Experimental)" y:y control:cbSA swatch:nil]];
            y += 30;
            
            NLCheckbox *cbVO = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbVO.isOn = gAimbotVisibleOnly;
            cbVO.onToggle = ^(BOOL v) {
                gAimbotVisibleOnly = v;
                [ConfigManager save];
            };
            [gAuto addSubview:[[NLRow alloc] initWithTitle:@"Visible Only" y:y control:cbVO swatch:nil]];
            y += 30;
            
            NLCheckbox *cbNT = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbNT.isOn = gAimbotNoTeam;
            cbNT.onToggle = ^(BOOL v) {
                gAimbotNoTeam = v;
                [ConfigManager save];
            };
            [gAuto addSubview:[[NLRow alloc] initWithTitle:@"No Team" y:y control:cbNT swatch:nil]];
            y += 30;
            
            NLSlider *s1 = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,110,18) suffix:@"px"];
            s1.min = 50;
            s1.max = 800;
            s1.value = gAimbotFovPx;
            s1.onChange = ^(float v) {
                gAimbotFovPx = (int)v;
            };
            s1.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gAuto addSubview:[[NLRow alloc] initWithTitle:@"FOV" y:y control:s1 swatch:nil]];
            y += 30;
            
            NLSlider *s2 = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,110,18) suffix:@""];
            s2.min = 0.0f;
            s2.max = 1.0f;
            s2.value = gAimbotSmooth;
            s2.onChange = ^(float v) {
                gAimbotSmooth = v;
            };
            s2.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gAuto addSubview:[[NLRow alloc] initWithTitle:@"Smooth" y:y control:s2 swatch:nil]];
            y += 30;

            NLSlider *s3 = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,110,18) suffix:@""];
            s3.min = 0.0f;
            s3.max = 1.0f;
            s3.value = gAimOnFireSmooth;
            s3.onChange = ^(float v) {
                gAimOnFireSmooth = v;
            };
            s3.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gAuto addSubview:[[NLRow alloc] initWithTitle:@"Aim On Fire Smooth" y:y control:s3 swatch:nil]];
            y += 30;
            
            NLGroupBox *gTrig = [[NLGroupBox alloc] initWithTitle:@"Triggerbot" frame:CGRectMake(0, 0, colW, 300)];
            [c2 addSubview:gTrig];
            CGFloat ty = 30;
            
            NLCheckbox *cbTB = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbTB.isOn = gTriggerbotEnabled;
            cbTB.onToggle = ^(BOOL v) {
                gTriggerbotEnabled = v;
                [ConfigManager save];
            };
            [gTrig addSubview:[[NLRow alloc] initWithTitle:@"Triggerbot" y:ty control:cbTB swatch:nil]];
            ty += 30;
            
            NLSlider *sTBDelay = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"ms"];
            sTBDelay.min = 20.0f;
            sTBDelay.max = 500.0f;
            sTBDelay.value = (float)gTriggerbotDelay.load();
            sTBDelay.onChange = ^(float v) { gTriggerbotDelay = (int)v; };
            sTBDelay.onRelease = ^(float v) { [ConfigManager save]; };
            [gTrig addSubview:[[NLRow alloc] initWithTitle:@"Delay" y:ty control:sTBDelay swatch:nil]];
            ty += 30;
            
            NLSlider *sTBFov = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"px"];
            sTBFov.min = 2.0f;
            sTBFov.max = 80.0f;
            sTBFov.value = (float)gTriggerbotFovPx.load();
            sTBFov.onChange = ^(float v) { gTriggerbotFovPx = (int)v; };
            sTBFov.onRelease = ^(float v) { [ConfigManager save]; };
            [gTrig addSubview:[[NLRow alloc] initWithTitle:@"Radius" y:ty control:sTBFov swatch:nil]];
            ty += 30;
            
            NLSlider *sTBHold = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"ms"];
            sTBHold.min = 10.0f;
            sTBHold.max = 200.0f;
            sTBHold.value = (float)gTriggerbotHold.load();
            sTBHold.onChange = ^(float v) { gTriggerbotHold = (int)v; };
            sTBHold.onRelease = ^(float v) { [ConfigManager save]; };
            [gTrig addSubview:[[NLRow alloc] initWithTitle:@"Hold" y:ty control:sTBHold swatch:nil]];
            ty += 30;
            
            NLCheckbox *cbTBVis = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbTBVis.isOn = gTriggerbotVisibleOnly;
            cbTBVis.onToggle = ^(BOOL v) { gTriggerbotVisibleOnly = v; [ConfigManager save]; };
            [gTrig addSubview:[[NLRow alloc] initWithTitle:@"Visible Only" y:ty control:cbTBVis swatch:nil]];
            ty += 30;
            
            NLCheckbox *cbTBTeam = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbTBTeam.isOn = gTriggerbotTeamCheck;
            cbTBTeam.onToggle = ^(BOOL v) { gTriggerbotTeamCheck = v; [ConfigManager save]; };
            [gTrig addSubview:[[NLRow alloc] initWithTitle:@"Team Check" y:ty control:cbTBTeam swatch:nil]];
            ty += 30;
            
            NLCheckbox *cbTBScope = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbTBScope.isOn = gTriggerbotScopeOnly;
            cbTBScope.onToggle = ^(BOOL v) { gTriggerbotScopeOnly = v; [ConfigManager save]; };
            [gTrig addSubview:[[NLRow alloc] initWithTitle:@"Scope Only" y:ty control:cbTBScope swatch:nil]];
            ty += 30;
            
            NLCheckbox *cbTBHead = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbTBHead.isOn = gTriggerbotHeadOnly;
            cbTBHead.onToggle = ^(BOOL v) { gTriggerbotHeadOnly = v; [ConfigManager save]; };
            [gTrig addSubview:[[NLRow alloc] initWithTitle:@"Head Only" y:ty control:cbTBHead swatch:nil]];
            ty += 30;
            
            NLGroupBox *gAimX = [[NLGroupBox alloc] initWithTitle:@"Aim Extras" frame:CGRectMake(0, 310, colW, 270)];
            [c2 addSubview:gAimX];
            CGFloat ax = 30;
            
            NLCheckbox *cbPred = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbPred.isOn = gPredictionEnabled;
            cbPred.onToggle = ^(BOOL v) { gPredictionEnabled = v; [ConfigManager save]; };
            [gAimX addSubview:[[NLRow alloc] initWithTitle:@"Prediction" y:ax control:cbPred swatch:nil]];
            ax += 30;
            
            NLSlider *sPred = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@""];
            sPred.min = 0.0f;
            sPred.max = 1.0f;
            sPred.value = gPredictionAmount;
            sPred.onChange = ^(float v) { gPredictionAmount = v; };
            sPred.onRelease = ^(float v) { [ConfigManager save]; };
            [gAimX addSubview:[[NLRow alloc] initWithTitle:@"Lead" y:ax control:sPred swatch:nil]];
            ax += 30;
            
            NLCheckbox *cbJit = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbJit.isOn = gAimJitterEnabled;
            cbJit.onToggle = ^(BOOL v) { gAimJitterEnabled = v; [ConfigManager save]; };
            [gAimX addSubview:[[NLRow alloc] initWithTitle:@"Humanize" y:ax control:cbJit swatch:nil]];
            ax += 30;
            
            NLSlider *sJit = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@""];
            sJit.min = 0.0f;
            sJit.max = 5.0f;
            sJit.value = gAimJitter;
            sJit.onChange = ^(float v) { gAimJitter = v; };
            sJit.onRelease = ^(float v) { [ConfigManager save]; };
            [gAimX addSubview:[[NLRow alloc] initWithTitle:@"Jitter" y:ax control:sJit swatch:nil]];
            ax += 30;
            
            NLCheckbox *cbSwD = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbSwD.isOn = gAimSwitchDelayEnabled;
            cbSwD.onToggle = ^(BOOL v) { gAimSwitchDelayEnabled = v; [ConfigManager save]; };
            [gAimX addSubview:[[NLRow alloc] initWithTitle:@"Switch Delay" y:ax control:cbSwD swatch:nil]];
            ax += 30;
            
            NLSlider *sSwD = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"ms"];
            sSwD.min = 0.0f;
            sSwD.max = 800.0f;
            sSwD.value = (float)gAimSwitchDelay.load();
            sSwD.onChange = ^(float v) { gAimSwitchDelay = (int)v; };
            sSwD.onRelease = ^(float v) { [ConfigManager save]; };
            [gAimX addSubview:[[NLRow alloc] initWithTitle:@"Switch Time" y:ax control:sSwD swatch:nil]];
            ax += 30;
            
            NLCheckbox *cbDrawT = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbDrawT.isOn = gAimDrawTarget;
            cbDrawT.onToggle = ^(BOOL v) { gAimDrawTarget = v; [ConfigManager save]; };
            [gAimX addSubview:[[NLRow alloc] initWithTitle:@"Draw Target" y:ax control:cbDrawT swatch:nil]];
            ax += 30;
            
            NLCheckbox *cbDrawF = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbDrawF.isOn = gAimDrawFov;
            cbDrawF.onToggle = ^(BOOL v) { gAimDrawFov = v; [ConfigManager save]; };
            [gAimX addSubview:[[NLRow alloc] initWithTitle:@"Draw FOV" y:ax control:cbDrawF swatch:nil]];
            ax += 30;
            
            NLGroupBox *gCombat = [[NLGroupBox alloc] initWithTitle:@"Combat" frame:CGRectMake(0, 590, colW, 300)];
            [c2 addSubview:gCombat];
            CGFloat cby = 30;
            
            NLButton *bPrio = [[NLButton alloc] initWithTitle:(gTargetPriority == 0 ? @"Nearest" : (gTargetPriority == 1 ? @"Low HP" : @"Crosshair"))];
            __weak NLButton *weakPrio = bPrio;
            bPrio.onTap = ^{
                int s = gTargetPriority.load();
                s = (s + 1) % 3;
                gTargetPriority = s;
                [weakPrio.titleLabel setText:(s == 0 ? @"Nearest" : (s == 1 ? @"Low HP" : @"Crosshair"))];
                [ConfigManager save];
            };
            [gCombat addSubview:[[NLRow alloc] initWithTitle:@"Target Priority" y:cby control:bPrio swatch:nil]];
            cby += 30;
            
            NLCheckbox *cbVG = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbVG.isOn = gVelocityGraphEnabled;
            cbVG.onToggle = ^(BOOL v) { gVelocityGraphEnabled = v; [ConfigManager save]; };
            [gCombat addSubview:[[NLRow alloc] initWithTitle:@"Velocity Graph" y:cby control:cbVG swatch:nil]];
            cby += 30;
            
            NLCheckbox *cbSI = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbSI.isOn = gSessionInfoEnabled;
            cbSI.onToggle = ^(BOOL v) { gSessionInfoEnabled = v; [ConfigManager save]; };
            [gCombat addSubview:[[NLRow alloc] initWithTitle:@"Session Info" y:cby control:cbSI swatch:nil]];
            cby += 30;
            
            NLCheckbox *cbDLP = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbDLP.isOn = gDamageLogPanelEnabled;
            cbDLP.onToggle = ^(BOOL v) { gDamageLogPanelEnabled = v; [ConfigManager save]; };
            [gCombat addSubview:[[NLRow alloc] initWithTitle:@"Damage Log" y:cby control:cbDLP swatch:nil]];
            cby += 30;
            
            NLCheckbox *cbTL = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbTL.isOn = gTargetListEnabled;
            cbTL.onToggle = ^(BOOL v) { gTargetListEnabled = v; [ConfigManager save]; };
            [gCombat addSubview:[[NLRow alloc] initWithTitle:@"Target List" y:cby control:cbTL swatch:nil]];
            cby += 30;
            
            NLCheckbox *cbCD = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbCD.isOn = gCrosshairDebugEnabled;
            cbCD.onToggle = ^(BOOL v) { gCrosshairDebugEnabled = v; [ConfigManager save]; };
            [gCombat addSubview:[[NLRow alloc] initWithTitle:@"Crosshair Debug" y:cby control:cbCD swatch:nil]];
            cby += 30;
            
            NLCheckbox *cbAB = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbAB.isOn = gAmmoBarEnabled;
            cbAB.onToggle = ^(BOOL v) { gAmmoBarEnabled = v; [ConfigManager save]; };
            [gCombat addSubview:[[NLRow alloc] initWithTitle:@"Ammo Bar" y:cby control:cbAB swatch:nil]];
            cby += 30;
            
        } else if (_currentTab == 2) {
            NLGroupBox *gEsp = [[NLGroupBox alloc] initWithTitle:@"Players" frame:CGRectMake(0, 0, colW, 340)];
            [c1 addSubview:gEsp];
            CGFloat y = 30;
            
            NLCheckbox *cbE = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbE.isOn = gEspEnabled;
            cbE.onToggle = ^(BOOL v) {
                gEspEnabled = v;
                [ConfigManager save];
            };
            [gEsp addSubview:[[NLRow alloc] initWithTitle:@"Enable ESP" y:y control:cbE swatch:nil]];
            y += 30;
            
            NLColorSwatch *swBox = [[NLColorSwatch alloc] initWithFrame:CGRectMake(0,0,16,16)];
            swBox.color = gBoxColor;
            __weak NLColorSwatch *weakSwBox = swBox;
            swBox.onTap = ^{
                [weakSelf showColorPickerForSwatch:weakSwBox currentColor:weakSwBox.color saveKey:@"c_b"];
            };
            
            NLCheckbox *cbH = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbH.isOn = gHealthBarEnabled;
            cbH.onToggle = ^(BOOL v) {
                gHealthBarEnabled = v;
                [ConfigManager save];
            };
            [gEsp addSubview:[[NLRow alloc] initWithTitle:@"Boxes & HP" y:y control:cbH swatch:swBox]];
            y += 30;
            
            NLColorSwatch *swName = [[NLColorSwatch alloc] initWithFrame:CGRectMake(0,0,16,16)];
            swName.color = gNameColor;
            __weak NLColorSwatch *weakSwName = swName;
            swName.onTap = ^{
                [weakSelf showColorPickerForSwatch:weakSwName currentColor:weakSwName.color saveKey:@"c_n"];
            };
            
            NLCheckbox *cbN = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbN.isOn = gNameEnabled;
            cbN.onToggle = ^(BOOL v) {
                gNameEnabled = v;
                [ConfigManager save];
            };
            [gEsp addSubview:[[NLRow alloc] initWithTitle:@"Names" y:y control:cbN swatch:swName]];
            y += 30;
            
            NLColorSwatch *swSkel = [[NLColorSwatch alloc] initWithFrame:CGRectMake(0,0,16,16)];
            swSkel.color = gSkelColor;
            __weak NLColorSwatch *weakSwSkel = swSkel;
            swSkel.onTap = ^{
                [weakSelf showColorPickerForSwatch:weakSwSkel currentColor:weakSwSkel.color saveKey:@"c_s"];
            };
            
            NLCheckbox *cbS = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbS.isOn = gSkeletonEnabled;
            cbS.onToggle = ^(BOOL v) {
                gSkeletonEnabled = v;
                [ConfigManager save];
            };
            [gEsp addSubview:[[NLRow alloc] initWithTitle:@"Skeleton" y:y control:cbS swatch:swSkel]];
            y += 30;
            
            NLColorSwatch *swTracer = [[NLColorSwatch alloc] initWithFrame:CGRectMake(0,0,16,16)];
            swTracer.color = gTracerColor;
            __weak NLColorSwatch *weakSwTracer = swTracer;
            swTracer.onTap = ^{
                [weakSelf showColorPickerForSwatch:weakSwTracer currentColor:weakSwTracer.color saveKey:@"c_t"];
            };
            
            NLCheckbox *cbTr = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbTr.isOn = gTracersEnabled;
            cbTr.onToggle = ^(BOOL v) {
                gTracersEnabled = v;
                [ConfigManager save];
            };
            [gEsp addSubview:[[NLRow alloc] initWithTitle:@"Snaplines" y:y control:cbTr swatch:swTracer]];
            y += 30;

            NLGroupBox *gWorld = [[NLGroupBox alloc] initWithTitle:@"World" frame:CGRectMake(0, 0, colW, 210)];
            [c2 addSubview:gWorld];
            y = 30;
            
            NLCheckbox *cbKS = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbKS.isOn = gKillSoundEnabled;
            cbKS.onToggle = ^(BOOL v) {
                gKillSoundEnabled = v;
                [ConfigManager save];
            };
            [gWorld addSubview:[[NLRow alloc] initWithTitle:@"Kill Sound" y:y control:cbKS swatch:nil]];
            y += 30;
            
            NLGroupBox *gChams = [[NLGroupBox alloc] initWithTitle:@"Chams" frame:CGRectMake(0, 140, colW, 360)];
            [c2 addSubview:gChams];
            CGFloat cy = 30;
            
            NLCheckbox *cbChamsPl = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbChamsPl.isOn = gChamsPlayerEnabled;
            cbChamsPl.onToggle = ^(BOOL v) {
                gChamsPlayerEnabled = v;
                [ConfigManager save];
            };
            
            NLColorSwatch *swChamsPl = [[NLColorSwatch alloc] initWithFrame:CGRectMake(0,0,16,16)];
            uint32_t hPl = gChamsPlayerColor.load();
            swChamsPl.color = [UIColor colorWithRed:((hPl>>24)&0xFF)/255.0 green:((hPl>>16)&0xFF)/255.0 blue:((hPl>>8)&0xFF)/255.0 alpha:(hPl&0xFF)/255.0];
            __weak NLColorSwatch *weakSwChamsPl = swChamsPl;
            swChamsPl.onTap = ^{
                [weakSelf showColorPickerForSwatch:weakSwChamsPl currentColor:weakSwChamsPl.color saveKey:@"v_chams_pl_c"];
            };
            
            [gChams addSubview:[[NLRow alloc] initWithTitle:@"Players" y:cy control:cbChamsPl swatch:swChamsPl]];
            
            UIButton *chevPl = [UIButton buttonWithType:UIButtonTypeSystem];
            chevPl.frame = CGRectMake(colW - 32, cy + 3, 18, 16);
            [chevPl setTitle:@"^" forState:UIControlStateNormal];
            [chevPl setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            chevPl.titleLabel.font = [UIFont systemFontOfSize:12];
            chevPl.tag = 100;
            [chevPl addTarget:weakSelf action:@selector(togglePlayerChamsMenu:) forControlEvents:UIControlEventTouchUpInside];
            [gChams addSubview:chevPl];
            cy += 30;
            
            UIView *matSelPl = [[UIView alloc] initWithFrame:CGRectMake(15, cy, colW - 30, 22)];
            matSelPl.tag = 200;
            matSelPl.hidden = YES;
            
            NSArray *matNames = @[@"Normal", @"Glass", @"Glow"];
            CGFloat bw = (colW - 30 - 6) / 3.0;
            
            for (int i = 0; i < 3; i++) {
                UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
                b.frame = CGRectMake(i * (bw + 3), 0, bw, 20);
                b.backgroundColor = ((int)gChamsPlayerMatType == i) ? [UIColor colorWithWhite:0.4 alpha:1.0] : [UIColor colorWithWhite:0.15 alpha:1.0];
                [b setTitle:matNames[i] forState:UIControlStateNormal];
                [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
                b.titleLabel.font = [UIFont systemFontOfSize:9];
                b.layer.cornerRadius = 3;
                b.tag = 1000 + i;
                [b addTarget:weakSelf action:@selector(selectPlayerChamsMat:) forControlEvents:UIControlEventTouchUpInside];
                [matSelPl addSubview:b];
            }
            
            [gChams addSubview:matSelPl];
            cy += 30;
            
            NLCheckbox *cbChamsPlX = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbChamsPlX.isOn = gChamsPlayerXray;
            cbChamsPlX.onToggle = ^(BOOL v) {
                gChamsPlayerXray = v;
                [ConfigManager save];
            };
            [gChams addSubview:[[NLRow alloc] initWithTitle:@"Player X-Ray" y:cy control:cbChamsPlX swatch:nil]];
            cy += 30;
            
            NLCheckbox *cbChamsWep = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbChamsWep.isOn = gChamsWeaponEnabled;
            cbChamsWep.onToggle = ^(BOOL v) {
                gChamsWeaponEnabled = v;
                [ConfigManager save];
            };
            
            NLColorSwatch *swChamsWep = [[NLColorSwatch alloc] initWithFrame:CGRectMake(0,0,16,16)];
            uint32_t hWep = gChamsWeaponColor.load();
            swChamsWep.color = [UIColor colorWithRed:((hWep>>24)&0xFF)/255.0 green:((hWep>>16)&0xFF)/255.0 blue:((hWep>>8)&0xFF)/255.0 alpha:(hWep&0xFF)/255.0];
            __weak NLColorSwatch *weakSwChamsWep = swChamsWep;
            swChamsWep.onTap = ^{
                [weakSelf showColorPickerForSwatch:weakSwChamsWep currentColor:weakSwChamsWep.color saveKey:@"v_chams_wep_c"];
            };
            
            [gChams addSubview:[[NLRow alloc] initWithTitle:@"Weapons" y:cy control:cbChamsWep swatch:swChamsWep]];
            
            UIButton *chevWep = [UIButton buttonWithType:UIButtonTypeSystem];
            chevWep.frame = CGRectMake(colW - 32, cy + 3, 18, 16);
            [chevWep setTitle:@"^" forState:UIControlStateNormal];
            [chevWep setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            chevWep.titleLabel.font = [UIFont systemFontOfSize:12];
            chevWep.tag = 101;
            [chevWep addTarget:weakSelf action:@selector(toggleWeaponChamsMenu:) forControlEvents:UIControlEventTouchUpInside];
            [gChams addSubview:chevWep];
            cy += 30;
            
            UIView *matSelWep = [[UIView alloc] initWithFrame:CGRectMake(15, cy, colW - 30, 22)];
            matSelWep.tag = 201;
            matSelWep.hidden = YES;
            
            for (int i = 0; i < 3; i++) {
                UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
                b.frame = CGRectMake(i * (bw + 3), 0, bw, 20);
                b.backgroundColor = ((int)gChamsWeaponMatType == i) ? [UIColor colorWithWhite:0.4 alpha:1.0] : [UIColor colorWithWhite:0.15 alpha:1.0];
                [b setTitle:matNames[i] forState:UIControlStateNormal];
                [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
                b.titleLabel.font = [UIFont systemFontOfSize:9];
                b.layer.cornerRadius = 3;
                b.tag = 1010 + i;
                [b addTarget:weakSelf action:@selector(selectWeaponChamsMat:) forControlEvents:UIControlEventTouchUpInside];
                [matSelWep addSubview:b];
            }
            
            [gChams addSubview:matSelWep];
            cy += 30;
            
            NLCheckbox *cbChamsWepX = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbChamsWepX.isOn = gChamsWeaponXray;
            cbChamsWepX.onToggle = ^(BOOL v) {
                gChamsWeaponXray = v;
                [ConfigManager save];
            };
            [gChams addSubview:[[NLRow alloc] initWithTitle:@"Weapon X-Ray" y:cy control:cbChamsWepX swatch:nil]];
            cy += 30;
            
            NLGroupBox *gHud = [[NLGroupBox alloc] initWithTitle:@"HUD & Extras" frame:CGRectMake(0, 510, colW, 940)];
            [c2 addSubview:gHud];
            CGFloat hy = 30;
            
            NLCheckbox *cbHD = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbHD.isOn = gHeadDotEnabled;
            cbHD.onToggle = ^(BOOL v) {
                gHeadDotEnabled = v;
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Head Dot" y:hy control:cbHD swatch:nil]];
            hy += 30;
            
            NLCheckbox *cbDist = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbDist.isOn = gDistanceEnabled;
            cbDist.onToggle = ^(BOOL v) {
                gDistanceEnabled = v;
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Distance" y:hy control:cbDist swatch:nil]];
            hy += 30;
            
            NLCheckbox *cbHP = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbHP.isOn = gHealthTextEnabled;
            cbHP.onToggle = ^(BOOL v) {
                gHealthTextEnabled = v;
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Health Text" y:hy control:cbHP swatch:nil]];
            hy += 30;
            
            NLColorSwatch *swHM = [[NLColorSwatch alloc] initWithFrame:CGRectMake(0,0,16,16)];
            swHM.color = gHitMarkerColor;
            __weak NLColorSwatch *weakSwHM = swHM;
            swHM.onTap = ^{
                [weakSelf showColorPickerForSwatch:weakSwHM currentColor:weakSwHM.color saveKey:@"c_hm"];
            };
            
            NLCheckbox *cbHM = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbHM.isOn = gHitMarkerEnabled;
            cbHM.onToggle = ^(BOOL v) {
                gHitMarkerEnabled = v;
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Hit Marker" y:hy control:cbHM swatch:swHM]];
            hy += 30;
            
            NLButton *bHMStyle = [[NLButton alloc] initWithTitle:(gHitMarkerStyle == 0 ? @"Cross" : (gHitMarkerStyle == 1 ? @"Dot" : @"Both"))];
            __weak NLButton *weakHMStyle = bHMStyle;
            bHMStyle.onTap = ^{
                int s = gHitMarkerStyle.load();
                s = (s + 1) % 3;
                gHitMarkerStyle = s;
                [weakHMStyle.titleLabel setText:(s == 0 ? @"Cross" : (s == 1 ? @"Dot" : @"Both"))];
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Hit Style" y:hy control:bHMStyle swatch:nil]];
            hy += 30;
            
            NLSlider *sHMSize = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"px"];
            sHMSize.min = 6.0f;
            sHMSize.max = 26.0f;
            sHMSize.value = gHitMarkerSize;
            sHMSize.onChange = ^(float v) {
                gHitMarkerSize = v;
            };
            sHMSize.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Hit Size" y:hy control:sHMSize swatch:nil]];
            hy += 30;
            
            NLSlider *sHMSpeed = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"ms"];
            sHMSpeed.min = 100.0f;
            sHMSpeed.max = 800.0f;
            sHMSpeed.value = (float)gHitMarkerDuration.load();
            sHMSpeed.onChange = ^(float v) {
                gHitMarkerDuration = (int)v;
            };
            sHMSpeed.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Hit Speed" y:hy control:sHMSpeed swatch:nil]];
            hy += 30;
            
            NLCheckbox *cbHMDmg = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbHMDmg.isOn = gHitMarkerShowDamage;
            cbHMDmg.onToggle = ^(BOOL v) {
                gHitMarkerShowDamage = v;
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Hit Damage" y:hy control:cbHMDmg swatch:nil]];
            hy += 30;
            
            NLColorSwatch *swDN = [[NLColorSwatch alloc] initWithFrame:CGRectMake(0,0,16,16)];
            swDN.color = gDamageNumberColor;
            __weak NLColorSwatch *weakSwDN = swDN;
            swDN.onTap = ^{
                [weakSelf showColorPickerForSwatch:weakSwDN currentColor:weakSwDN.color saveKey:@"c_dn"];
            };
            
            NLCheckbox *cbDN = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbDN.isOn = gDamageNumbersEnabled;
            cbDN.onToggle = ^(BOOL v) {
                gDamageNumbersEnabled = v;
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Damage Numbers" y:hy control:cbDN swatch:swDN]];
            hy += 30;
            
            NLSlider *sDNSize = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"px"];
            sDNSize.min = 9.0f;
            sDNSize.max = 28.0f;
            sDNSize.value = gDamageNumberSize;
            sDNSize.onChange = ^(float v) {
                gDamageNumberSize = v;
            };
            sDNSize.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Damage Size" y:hy control:sDNSize swatch:nil]];
            hy += 30;
            
            NLSlider *sDNDur = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"ms"];
            sDNDur.min = 250.0f;
            sDNDur.max = 2500.0f;
            sDNDur.value = (float)gDamageNumberDuration.load();
            sDNDur.onChange = ^(float v) {
                gDamageNumberDuration = (int)v;
            };
            sDNDur.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Damage Speed" y:hy control:sDNDur swatch:nil]];
            hy += 30;
            
            NLSlider *sDNRise = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"px"];
            sDNRise.min = 0.0f;
            sDNRise.max = 80.0f;
            sDNRise.value = gDamageNumberRise;
            sDNRise.onChange = ^(float v) {
                gDamageNumberRise = v;
            };
            sDNRise.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Damage Rise" y:hy control:sDNRise swatch:nil]];
            hy += 30;
            
            NLCheckbox *cbDNOut = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbDNOut.isOn = gDamageNumberOutline;
            cbDNOut.onToggle = ^(BOOL v) {
                gDamageNumberOutline = v;
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Damage Outline" y:hy control:cbDNOut swatch:nil]];
            hy += 30;
            
            NLCheckbox *cbRadar = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbRadar.isOn = gRadarEnabled;
            cbRadar.onToggle = ^(BOOL v) {
                gRadarEnabled = v;
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Radar" y:hy control:cbRadar swatch:nil]];
            hy += 30;
            
            NLCheckbox *cbCross = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbCross.isOn = gCrosshairEnabled;
            cbCross.onToggle = ^(BOOL v) {
                gCrosshairEnabled = v;
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Dynamic Crosshair" y:hy control:cbCross swatch:nil]];
            hy += 30;
            
            NLCheckbox *cbScope = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbScope.isOn = gScopeOverlayEnabled;
            cbScope.onToggle = ^(BOOL v) {
                gScopeOverlayEnabled = v;
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Scope Overlay" y:hy control:cbScope swatch:nil]];
            hy += 30;
            
            NLCheckbox *cbAL = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbAL.isOn = gAimLineEnabled;
            cbAL.onToggle = ^(BOOL v) {
                gAimLineEnabled = v;
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Aim Line" y:hy control:cbAL swatch:nil]];
            hy += 30;
            
            NLColorSwatch *swTeam = [[NLColorSwatch alloc] initWithFrame:CGRectMake(0,0,16,16)];
            swTeam.color = gTeamColor;
            __weak NLColorSwatch *weakSwTeam = swTeam;
            swTeam.onTap = ^{
                [weakSelf showColorPickerForSwatch:weakSwTeam currentColor:weakSwTeam.color saveKey:@"c_team"];
            };
            
            NLCheckbox *cbTC = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbTC.isOn = gTeamColorEnabled;
            cbTC.onToggle = ^(BOOL v) {
                gTeamColorEnabled = v;
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Team Colors" y:hy control:cbTC swatch:swTeam]];
            hy += 30;
            
            NLColorSwatch *swVis = [[NLColorSwatch alloc] initWithFrame:CGRectMake(0,0,16,16)];
            swVis.color = gVisibleColor;
            __weak NLColorSwatch *weakSwVis = swVis;
            swVis.onTap = ^{
                [weakSelf showColorPickerForSwatch:weakSwVis currentColor:weakSwVis.color saveKey:@"c_vis"];
            };
            
            NLCheckbox *cbVC = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbVC.isOn = gVisibleColorEnabled;
            cbVC.onToggle = ^(BOOL v) {
                gVisibleColorEnabled = v;
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Visible Colors" y:hy control:cbVC swatch:swVis]];
            hy += 30;
            
            NLCheckbox *cbSB = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbSB.isOn = gSnapBottomEnabled;
            cbSB.onToggle = ^(BOOL v) {
                gSnapBottomEnabled = v;
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Snap From Bottom" y:hy control:cbSB swatch:nil]];
            hy += 30;
            
            NLCheckbox *cbKF = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbKF.isOn = gKillFeedEnabled;
            cbKF.onToggle = ^(BOOL v) {
                gKillFeedEnabled = v;
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Kill Feed" y:hy control:cbKF swatch:nil]];
            hy += 30;
            
            NLButton *bBoxStyle = [[NLButton alloc] initWithTitle:(gBoxStyle == 0 ? @"Full" : @"Corner")];
            __weak NLButton *weakBoxStyle = bBoxStyle;
            bBoxStyle.onTap = ^{
                int s = gBoxStyle;
                s = (s == 0) ? 1 : 0;
                gBoxStyle = s;
                [weakBoxStyle.titleLabel setText:(s == 0 ? @"Full" : @"Corner")];
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Box Style" y:hy control:bBoxStyle swatch:nil]];
            hy += 30;
            
            NLSlider *sSkel = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"px"];
            sSkel.min = 0.5f;
            sSkel.max = 4.0f;
            sSkel.value = gSkelThickness;
            sSkel.onChange = ^(float v) {
                gSkelThickness = v;
            };
            sSkel.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Skeleton Width" y:hy control:sSkel swatch:nil]];
            hy += 30;
            
            NLSlider *sRadarRange = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"m"];
            sRadarRange.min = 20.0f;
            sRadarRange.max = 150.0f;
            sRadarRange.value = (float)gRadarRange;
            sRadarRange.onChange = ^(float v) {
                gRadarRange = (int)v;
            };
            sRadarRange.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Radar Range" y:hy control:sRadarRange swatch:nil]];
            hy += 30;
            
            NLSlider *sRadarSize = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"px"];
            sRadarSize.min = 70.0f;
            sRadarSize.max = 220.0f;
            sRadarSize.value = gRadarSize;
            sRadarSize.onChange = ^(float v) {
                gRadarSize = v;
            };
            sRadarSize.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Radar Size" y:hy control:sRadarSize swatch:nil]];
            hy += 30;
            
            NLCheckbox *cbRR = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbRR.isOn = gRadarRotate;
            cbRR.onToggle = ^(BOOL v) {
                gRadarRotate = v;
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Radar Rotate" y:hy control:cbRR swatch:nil]];
            hy += 30;
            
            NLCheckbox *cbFps = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbFps.isOn = gFpsEnabled;
            cbFps.onToggle = ^(BOOL v) {
                gFpsEnabled = v;
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"FPS Graph" y:hy control:cbFps swatch:nil]];
            hy += 30;
            
            NLGroupBox *gEspStyle = [[NLGroupBox alloc] initWithTitle:@"ESP Style" frame:CGRectMake(0, 350, colW, 900)];
            [c1 addSubview:gEspStyle];
            CGFloat ey = 30;
            
            NLSlider *sBoxW = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"px"];
            sBoxW.min = 0.5f;
            sBoxW.max = 5.0f;
            sBoxW.value = gBoxThickness;
            sBoxW.onChange = ^(float v) { gBoxThickness = v; };
            sBoxW.onRelease = ^(float v) { [ConfigManager save]; };
            [gEspStyle addSubview:[[NLRow alloc] initWithTitle:@"Box Width" y:ey control:sBoxW swatch:nil]];
            ey += 30;
            
            NLCheckbox *cbBoxFill = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbBoxFill.isOn = gBoxFilled;
            cbBoxFill.onToggle = ^(BOOL v) { gBoxFilled = v; [ConfigManager save]; };
            [gEspStyle addSubview:[[NLRow alloc] initWithTitle:@"Box Filled" y:ey control:cbBoxFill swatch:nil]];
            ey += 30;
            
            NLSlider *sBoxFillA = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@""];
            sBoxFillA.min = 0.02f;
            sBoxFillA.max = 0.5f;
            sBoxFillA.value = gBoxFillAlpha;
            sBoxFillA.onChange = ^(float v) { gBoxFillAlpha = v; };
            sBoxFillA.onRelease = ^(float v) { [ConfigManager save]; };
            [gEspStyle addSubview:[[NLRow alloc] initWithTitle:@"Fill Alpha" y:ey control:sBoxFillA swatch:nil]];
            ey += 30;
            
            NLButton *bHBStyle = [[NLButton alloc] initWithTitle:(gHealthBarStyle == 0 ? @"Left" : (gHealthBarStyle == 1 ? @"Right" : @"Top"))];
            __weak NLButton *weakHBStyle = bHBStyle;
            bHBStyle.onTap = ^{
                int s = gHealthBarStyle.load();
                s = (s + 1) % 3;
                gHealthBarStyle = s;
                [weakHBStyle.titleLabel setText:(s == 0 ? @"Left" : (s == 1 ? @"Right" : @"Top"))];
                [ConfigManager save];
            };
            [gEspStyle addSubview:[[NLRow alloc] initWithTitle:@"HP Bar Style" y:ey control:bHBStyle swatch:nil]];
            ey += 30;
            
            NLSlider *sHBW = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"px"];
            sHBW.min = 1.0f;
            sHBW.max = 6.0f;
            sHBW.value = gHealthBarWidth;
            sHBW.onChange = ^(float v) { gHealthBarWidth = v; };
            sHBW.onRelease = ^(float v) { [ConfigManager save]; };
            [gEspStyle addSubview:[[NLRow alloc] initWithTitle:@"HP Bar Width" y:ey control:sHBW swatch:nil]];
            ey += 30;
            
            NLCheckbox *cbHPGrad = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbHPGrad.isOn = gEspHealthGradient;
            cbHPGrad.onToggle = ^(BOOL v) { gEspHealthGradient = v; [ConfigManager save]; };
            [gEspStyle addSubview:[[NLRow alloc] initWithTitle:@"HP Gradient" y:ey control:cbHPGrad swatch:nil]];
            ey += 30;
            
            NLCheckbox *cbArmor = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbArmor.isOn = gEspArmorBar;
            cbArmor.onToggle = ^(BOOL v) { gEspArmorBar = v; [ConfigManager save]; };
            [gEspStyle addSubview:[[NLRow alloc] initWithTitle:@"Armor Bar" y:ey control:cbArmor swatch:nil]];
            ey += 30;
            
            NLButton *bDistFmt = [[NLButton alloc] initWithTitle:(gDistanceFormat == 0 ? @"Meters" : @"Units")];
            __weak NLButton *weakDistFmt = bDistFmt;
            bDistFmt.onTap = ^{
                int s = gDistanceFormat.load();
                s = (s == 0) ? 1 : 0;
                gDistanceFormat = s;
                [weakDistFmt.titleLabel setText:(s == 0 ? @"Meters" : @"Units")];
                [ConfigManager save];
            };
            [gEspStyle addSubview:[[NLRow alloc] initWithTitle:@"Distance Fmt" y:ey control:bDistFmt swatch:nil]];
            ey += 30;
            
            NLCheckbox *cbDistAbove = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbDistAbove.isOn = gDistanceAbove;
            cbDistAbove.onToggle = ^(BOOL v) { gDistanceAbove = v; [ConfigManager save]; };
            [gEspStyle addSubview:[[NLRow alloc] initWithTitle:@"Distance Above" y:ey control:cbDistAbove swatch:nil]];
            ey += 30;
            
            NLCheckbox *cbFade = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbFade.isOn = gEspFadeEnabled;
            cbFade.onToggle = ^(BOOL v) { gEspFadeEnabled = v; [ConfigManager save]; };
            [gEspStyle addSubview:[[NLRow alloc] initWithTitle:@"Distance Fade" y:ey control:cbFade swatch:nil]];
            ey += 30;
            
            NLSlider *sFadeS = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"m"];
            sFadeS.min = 5.0f;
            sFadeS.max = 200.0f;
            sFadeS.value = gEspFadeStart;
            sFadeS.onChange = ^(float v) { gEspFadeStart = v; };
            sFadeS.onRelease = ^(float v) { [ConfigManager save]; };
            [gEspStyle addSubview:[[NLRow alloc] initWithTitle:@"Fade Start" y:ey control:sFadeS swatch:nil]];
            ey += 30;
            
            NLSlider *sFadeE = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"m"];
            sFadeE.min = 10.0f;
            sFadeE.max = 400.0f;
            sFadeE.value = gEspFadeEnd;
            sFadeE.onChange = ^(float v) { gEspFadeEnd = v; };
            sFadeE.onRelease = ^(float v) { [ConfigManager save]; };
            [gEspStyle addSubview:[[NLRow alloc] initWithTitle:@"Fade End" y:ey control:sFadeE swatch:nil]];
            ey += 30;
            
            NLSlider *sOofS = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"px"];
            sOofS.min = 4.0f;
            sOofS.max = 30.0f;
            sOofS.value = gOofSize;
            sOofS.onChange = ^(float v) { gOofSize = v; };
            sOofS.onRelease = ^(float v) { [ConfigManager save]; };
            [gEspStyle addSubview:[[NLRow alloc] initWithTitle:@"OOF Size" y:ey control:sOofS swatch:nil]];
            ey += 30;
            
            NLSlider *sOofW = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"px"];
            sOofW.min = 0.5f;
            sOofW.max = 6.0f;
            sOofW.value = gOofThickness;
            sOofW.onChange = ^(float v) { gOofThickness = v; };
            sOofW.onRelease = ^(float v) { [ConfigManager save]; };
            [gEspStyle addSubview:[[NLRow alloc] initWithTitle:@"OOF Width" y:ey control:sOofW swatch:nil]];
            ey += 30;
            
            NLColorSwatch *swOof = [[NLColorSwatch alloc] initWithFrame:CGRectMake(0,0,16,16)];
            swOof.color = gOofColor;
            __weak NLColorSwatch *weakSwOof = swOof;
            swOof.onTap = ^{
                [weakSelf showColorPickerForSwatch:weakSwOof currentColor:weakSwOof.color saveKey:@"c_oof"];
            };
            NLCheckbox *cbOof = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbOof.isOn = gOofEnabled;
            cbOof.onToggle = ^(BOOL v) { gOofEnabled = v; [ConfigManager save]; };
            [gEspStyle addSubview:[[NLRow alloc] initWithTitle:@"Offscreen" y:ey control:cbOof swatch:swOof]];
            ey += 30;
            
            NLSlider *sHeadDot = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"px"];
            sHeadDot.min = 1.0f;
            sHeadDot.max = 8.0f;
            sHeadDot.value = gHeadDotSize;
            sHeadDot.onChange = ^(float v) { gHeadDotSize = v; };
            sHeadDot.onRelease = ^(float v) { [ConfigManager save]; };
            [gEspStyle addSubview:[[NLRow alloc] initWithTitle:@"Head Dot Size" y:ey control:sHeadDot swatch:nil]];
            ey += 30;
            
            NLCheckbox *cbNameBg = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbNameBg.isOn = gNameBgEnabled;
            cbNameBg.onToggle = ^(BOOL v) { gNameBgEnabled = v; [ConfigManager save]; };
            [gEspStyle addSubview:[[NLRow alloc] initWithTitle:@"Name Background" y:ey control:cbNameBg swatch:nil]];
            ey += 30;
            
            NLColorSwatch *swWep = [[NLColorSwatch alloc] initWithFrame:CGRectMake(0,0,16,16)];
            swWep.color = gWeaponEspColor;
            __weak NLColorSwatch *weakSwWep = swWep;
            swWep.onTap = ^{
                [weakSelf showColorPickerForSwatch:weakSwWep currentColor:weakSwWep.color saveKey:@"c_wep"];
            };
            NLCheckbox *cbWepEsp = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbWepEsp.isOn = gWeaponEspEnabled;
            cbWepEsp.onToggle = ^(BOOL v) { gWeaponEspEnabled = v; [ConfigManager save]; };
            [gEspStyle addSubview:[[NLRow alloc] initWithTitle:@"Weapon ESP" y:ey control:cbWepEsp swatch:swWep]];
            ey += 30;
            
            NLSlider *sWepW = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"px"];
            sWepW.min = 0.5f;
            sWepW.max = 4.0f;
            sWepW.value = gWeaponEspThickness;
            sWepW.onChange = ^(float v) { gWeaponEspThickness = v; };
            sWepW.onRelease = ^(float v) { [ConfigManager save]; };
            [gEspStyle addSubview:[[NLRow alloc] initWithTitle:@"Weapon Width" y:ey control:sWepW swatch:nil]];
            ey += 30;
            
            NLCheckbox *cbOofArrows = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbOofArrows.isOn = gEspOffscreenArrows;
            cbOofArrows.onToggle = ^(BOOL v) { gEspOffscreenArrows = v; [ConfigManager save]; };
            [gEspStyle addSubview:[[NLRow alloc] initWithTitle:@"OOF Arrows" y:ey control:cbOofArrows swatch:nil]];
            ey += 30;
            
            NLSlider *sOofMargin = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"px"];
            sOofMargin.min = 10.0f;
            sOofMargin.max = 120.0f;
            sOofMargin.value = gEspOffscreenMargin;
            sOofMargin.onChange = ^(float v) { gEspOffscreenMargin = v; };
            sOofMargin.onRelease = ^(float v) { [ConfigManager save]; };
            [gEspStyle addSubview:[[NLRow alloc] initWithTitle:@"OOF Margin" y:ey control:sOofMargin swatch:nil]];
            ey += 30;
            
            NLSlider *sRadarBlip = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"px"];
            sRadarBlip.min = 1.0f;
            sRadarBlip.max = 8.0f;
            sRadarBlip.value = gRadarBlipSize;
            sRadarBlip.onChange = ^(float v) { gRadarBlipSize = v; };
            sRadarBlip.onRelease = ^(float v) { [ConfigManager save]; };
            [gEspStyle addSubview:[[NLRow alloc] initWithTitle:@"Radar Blip" y:ey control:sRadarBlip swatch:nil]];
            ey += 30;
            
            NLSlider *sRadarOp = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@""];
            sRadarOp.min = 0.05f;
            sRadarOp.max = 0.9f;
            sRadarOp.value = gRadarOpacity;
            sRadarOp.onChange = ^(float v) { gRadarOpacity = v; };
            sRadarOp.onRelease = ^(float v) { [ConfigManager save]; };
            [gEspStyle addSubview:[[NLRow alloc] initWithTitle:@"Radar Opacity" y:ey control:sRadarOp swatch:nil]];
            ey += 30;
            
            NLSlider *sCornerLen = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@""];
            sCornerLen.min = 0.1f;
            sCornerLen.max = 0.5f;
            sCornerLen.value = gBoxCornerLen;
            sCornerLen.onChange = ^(float v) { gBoxCornerLen = v; };
            sCornerLen.onRelease = ^(float v) { [ConfigManager save]; };
            [gEspStyle addSubview:[[NLRow alloc] initWithTitle:@"Corner Length" y:ey control:sCornerLen swatch:nil]];
            ey += 30;
            
            NLSlider *sNameLen = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@""];
            sNameLen.min = 4.0f;
            sNameLen.max = 32.0f;
            sNameLen.value = (float)gNameMaxLen.load();
            sNameLen.onChange = ^(float v) { gNameMaxLen = (int)v; };
            sNameLen.onRelease = ^(float v) { [ConfigManager save]; };
            [gEspStyle addSubview:[[NLRow alloc] initWithTitle:@"Name Max Len" y:ey control:sNameLen swatch:nil]];
            ey += 30;
            
            NLCheckbox *cbDmgStack = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbDmgStack.isOn = gDamageStack;
            cbDmgStack.onToggle = ^(BOOL v) { gDamageStack = v; [ConfigManager save]; };
            [gEspStyle addSubview:[[NLRow alloc] initWithTitle:@"Damage Stack" y:ey control:cbDmgStack swatch:nil]];
            ey += 30;
            
            NLCheckbox *cbSkelUp = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbSkelUp.isOn = gSkeletonUpperOnly;
            cbSkelUp.onToggle = ^(BOOL v) { gSkeletonUpperOnly = v; [ConfigManager save]; };
            [gEspStyle addSubview:[[NLRow alloc] initWithTitle:@"Skeleton Upper" y:ey control:cbSkelUp swatch:nil]];
            ey += 30;
            
            NLGroupBox *gCross = [[NLGroupBox alloc] initWithTitle:@"Crosshair & FOV" frame:CGRectMake(0, 1260, colW, 400)];
            [c1 addSubview:gCross];
            CGFloat cy2 = 30;
            
            NLButton *bCHStyle = [[NLButton alloc] initWithTitle:(gCrosshairStyle == 0 ? @"Cross" : (gCrosshairStyle == 1 ? @"Dot" : (gCrosshairStyle == 2 ? @"Circle" : (gCrosshairStyle == 3 ? @"T" : @"X"))))];
            __weak NLButton *weakCHStyle = bCHStyle;
            bCHStyle.onTap = ^{
                int s = gCrosshairStyle.load();
                s = (s + 1) % 5;
                gCrosshairStyle = s;
                NSString *t = (s == 0 ? @"Cross" : (s == 1 ? @"Dot" : (s == 2 ? @"Circle" : (s == 3 ? @"T" : @"X"))));
                [weakCHStyle.titleLabel setText:t];
                [ConfigManager save];
            };
            [gCross addSubview:[[NLRow alloc] initWithTitle:@"Cross Style" y:cy2 control:bCHStyle swatch:nil]];
            cy2 += 30;
            
            NLSlider *sCHGap = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"px"];
            sCHGap.min = 0.0f;
            sCHGap.max = 60.0f;
            sCHGap.value = gCrosshairGap;
            sCHGap.onChange = ^(float v) { gCrosshairGap = v; };
            sCHGap.onRelease = ^(float v) { [ConfigManager save]; };
            [gCross addSubview:[[NLRow alloc] initWithTitle:@"Cross Gap" y:cy2 control:sCHGap swatch:nil]];
            cy2 += 30;
            
            NLSlider *sCHLen = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"px"];
            sCHLen.min = 2.0f;
            sCHLen.max = 40.0f;
            sCHLen.value = gCrosshairLength;
            sCHLen.onChange = ^(float v) { gCrosshairLength = v; };
            sCHLen.onRelease = ^(float v) { [ConfigManager save]; };
            [gCross addSubview:[[NLRow alloc] initWithTitle:@"Cross Length" y:cy2 control:sCHLen swatch:nil]];
            cy2 += 30;
            
            NLSlider *sCHTh = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"px"];
            sCHTh.min = 0.5f;
            sCHTh.max = 5.0f;
            sCHTh.value = gCrosshairThickness;
            sCHTh.onChange = ^(float v) { gCrosshairThickness = v; };
            sCHTh.onRelease = ^(float v) { [ConfigManager save]; };
            [gCross addSubview:[[NLRow alloc] initWithTitle:@"Cross Width" y:cy2 control:sCHTh swatch:nil]];
            cy2 += 30;
            
            NLSlider *sCHDot = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"px"];
            sCHDot.min = 0.0f;
            sCHDot.max = 6.0f;
            sCHDot.value = gCrosshairDot;
            sCHDot.onChange = ^(float v) { gCrosshairDot = v; };
            sCHDot.onRelease = ^(float v) { [ConfigManager save]; };
            [gCross addSubview:[[NLRow alloc] initWithTitle:@"Cross Dot" y:cy2 control:sCHDot swatch:nil]];
            cy2 += 30;
            
            NLCheckbox *cbCHOut = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbCHOut.isOn = gCrosshairOutline;
            cbCHOut.onToggle = ^(BOOL v) { gCrosshairOutline = v; [ConfigManager save]; };
            [gCross addSubview:[[NLRow alloc] initWithTitle:@"Cross Outline" y:cy2 control:cbCHOut swatch:nil]];
            cy2 += 30;
            
            NLColorSwatch *swCross = [[NLColorSwatch alloc] initWithFrame:CGRectMake(0,0,16,16)];
            swCross.color = gCrosshairColor;
            __weak NLColorSwatch *weakSwCross = swCross;
            swCross.onTap = ^{
                [weakSelf showColorPickerForSwatch:weakSwCross currentColor:weakSwCross.color saveKey:@"c_cross"];
            };
            NLCheckbox *cbCrossE = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbCrossE.isOn = gCrosshairEnabled;
            cbCrossE.onToggle = ^(BOOL v) { gCrosshairEnabled = v; [ConfigManager save]; };
            [gCross addSubview:[[NLRow alloc] initWithTitle:@"Crosshair" y:cy2 control:cbCrossE swatch:swCross]];
            cy2 += 30;
            
            NLButton *bFCStyle = [[NLButton alloc] initWithTitle:(gFovCircleStyle == 0 ? @"Circle" : (gFovCircleStyle == 1 ? @"Square" : @"Corners"))];
            __weak NLButton *weakFCStyle = bFCStyle;
            bFCStyle.onTap = ^{
                int s = gFovCircleStyle.load();
                s = (s + 1) % 3;
                gFovCircleStyle = s;
                [weakFCStyle.titleLabel setText:(s == 0 ? @"Circle" : (s == 1 ? @"Square" : @"Corners"))];
                [ConfigManager save];
            };
            [gCross addSubview:[[NLRow alloc] initWithTitle:@"FOV Style" y:cy2 control:bFCStyle swatch:nil]];
            cy2 += 30;
            
            NLSlider *sFCTh = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"px"];
            sFCTh.min = 0.5f;
            sFCTh.max = 5.0f;
            sFCTh.value = gFovCircleThickness;
            sFCTh.onChange = ^(float v) { gFovCircleThickness = v; };
            sFCTh.onRelease = ^(float v) { [ConfigManager save]; };
            [gCross addSubview:[[NLRow alloc] initWithTitle:@"FOV Width" y:cy2 control:sFCTh swatch:nil]];
            cy2 += 30;
            
            NLCheckbox *cbFCFill = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbFCFill.isOn = gFovCircleFilled;
            cbFCFill.onToggle = ^(BOOL v) { gFovCircleFilled = v; [ConfigManager save]; };
            [gCross addSubview:[[NLRow alloc] initWithTitle:@"FOV Filled" y:cy2 control:cbFCFill swatch:nil]];
            cy2 += 30;
            
            NLColorSwatch *swFov = [[NLColorSwatch alloc] initWithFrame:CGRectMake(0,0,16,16)];
            swFov.color = gFovCircleColor;
            __weak NLColorSwatch *weakSwFov = swFov;
            swFov.onTap = ^{
                [weakSelf showColorPickerForSwatch:weakSwFov currentColor:weakSwFov.color saveKey:@"c_fov"];
            };
            NLCheckbox *cbFCE = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbFCE.isOn = gFovCircleEnabled;
            cbFCE.onToggle = ^(BOOL v) { gFovCircleEnabled = v; [ConfigManager save]; };
            [gCross addSubview:[[NLRow alloc] initWithTitle:@"FOV Circle" y:cy2 control:cbFCE swatch:swFov]];
            cy2 += 30;
            
            NLGroupBox *gPanels = [[NLGroupBox alloc] initWithTitle:@"Panels" frame:CGRectMake(0, 1460, colW, 830)];
            [c2 addSubview:gPanels];
            CGFloat py = 30;
            
            NLCheckbox *cbPL = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbPL.isOn = gPlayerListEnabled;
            cbPL.onToggle = ^(BOOL v) { gPlayerListEnabled = v; [ConfigManager save]; };
            [gPanels addSubview:[[NLRow alloc] initWithTitle:@"Player List" y:py control:cbPL swatch:nil]];
            py += 30;
            
            NLCheckbox *cbPLH = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbPLH.isOn = gPlayerListHealth;
            cbPLH.onToggle = ^(BOOL v) { gPlayerListHealth = v; [ConfigManager save]; };
            [gPanels addSubview:[[NLRow alloc] initWithTitle:@"List Health" y:py control:cbPLH swatch:nil]];
            py += 30;
            
            NLCheckbox *cbPLD = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbPLD.isOn = gPlayerListDistance;
            cbPLD.onToggle = ^(BOOL v) { gPlayerListDistance = v; [ConfigManager save]; };
            [gPanels addSubview:[[NLRow alloc] initWithTitle:@"List Distance" y:py control:cbPLD swatch:nil]];
            py += 30;
            
            NLCheckbox *cbPLT = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbPLT.isOn = gPlayerListTeam;
            cbPLT.onToggle = ^(BOOL v) { gPlayerListTeam = v; [ConfigManager save]; };
            [gPanels addSubview:[[NLRow alloc] initWithTitle:@"List Team" y:py control:cbPLT swatch:nil]];
            py += 30;
            
            NLSlider *sPLMax = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@""];
            sPLMax.min = 1.0f;
            sPLMax.max = 16.0f;
            sPLMax.value = (float)gPlayerListMax.load();
            sPLMax.onChange = ^(float v) { gPlayerListMax = (int)v; };
            sPLMax.onRelease = ^(float v) { [ConfigManager save]; };
            [gPanels addSubview:[[NLRow alloc] initWithTitle:@"List Max" y:py control:sPLMax swatch:nil]];
            py += 30;
            
            NLSlider *sPLScale = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"x"];
            sPLScale.min = 0.6f;
            sPLScale.max = 2.0f;
            sPLScale.value = gPlayerListScale;
            sPLScale.onChange = ^(float v) { gPlayerListScale = v; };
            sPLScale.onRelease = ^(float v) { [ConfigManager save]; };
            [gPanels addSubview:[[NLRow alloc] initWithTitle:@"List Scale" y:py control:sPLScale swatch:nil]];
            py += 30;
            
            NLCheckbox *cbIP = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbIP.isOn = gInfoPanelEnabled;
            cbIP.onToggle = ^(BOOL v) { gInfoPanelEnabled = v; [ConfigManager save]; };
            [gPanels addSubview:[[NLRow alloc] initWithTitle:@"Info Panel" y:py control:cbIP swatch:nil]];
            py += 30;
            
            NLCheckbox *cbIPH = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbIPH.isOn = gInfoPanelHealth;
            cbIPH.onToggle = ^(BOOL v) { gInfoPanelHealth = v; [ConfigManager save]; };
            [gPanels addSubview:[[NLRow alloc] initWithTitle:@"Info Health" y:py control:cbIPH swatch:nil]];
            py += 30;
            
            NLCheckbox *cbIPA = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbIPA.isOn = gInfoPanelAmmo;
            cbIPA.onToggle = ^(BOOL v) { gInfoPanelAmmo = v; [ConfigManager save]; };
            [gPanels addSubview:[[NLRow alloc] initWithTitle:@"Info Ammo" y:py control:cbIPA swatch:nil]];
            py += 30;
            
            NLCheckbox *cbIPF = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbIPF.isOn = gInfoPanelFps;
            cbIPF.onToggle = ^(BOOL v) { gInfoPanelFps = v; [ConfigManager save]; };
            [gPanels addSubview:[[NLRow alloc] initWithTitle:@"Info FPS" y:py control:cbIPF swatch:nil]];
            py += 30;
            
            NLCheckbox *cbIPS = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbIPS.isOn = gInfoPanelSpeed;
            cbIPS.onToggle = ^(BOOL v) { gInfoPanelSpeed = v; [ConfigManager save]; };
            [gPanels addSubview:[[NLRow alloc] initWithTitle:@"Info Speed" y:py control:cbIPS swatch:nil]];
            py += 30;
            
            NLCheckbox *cbEL = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbEL.isOn = gEventLogEnabled;
            cbEL.onToggle = ^(BOOL v) { gEventLogEnabled = v; [ConfigManager save]; };
            [gPanels addSubview:[[NLRow alloc] initWithTitle:@"Event Log" y:py control:cbEL swatch:nil]];
            py += 30;
            
            NLSlider *sELMax = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@""];
            sELMax.min = 1.0f;
            sELMax.max = 12.0f;
            sELMax.value = (float)gEventLogMax.load();
            sELMax.onChange = ^(float v) { gEventLogMax = (int)v; };
            sELMax.onRelease = ^(float v) { [ConfigManager save]; };
            [gPanels addSubview:[[NLRow alloc] initWithTitle:@"Log Max" y:py control:sELMax swatch:nil]];
            py += 30;
            
            NLSlider *sELDur = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"ms"];
            sELDur.min = 1000.0f;
            sELDur.max = 15000.0f;
            sELDur.value = gEventLogDuration;
            sELDur.onChange = ^(float v) { gEventLogDuration = v; };
            sELDur.onRelease = ^(float v) { [ConfigManager save]; };
            [gPanels addSubview:[[NLRow alloc] initWithTitle:@"Log Duration" y:py control:sELDur swatch:nil]];
            py += 30;
            
            NLCheckbox *cbStats = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbStats.isOn = gStatsPanelEnabled;
            cbStats.onToggle = ^(BOOL v) { gStatsPanelEnabled = v; [ConfigManager save]; };
            [gPanels addSubview:[[NLRow alloc] initWithTitle:@"Stats Panel" y:py control:cbStats swatch:nil]];
            py += 30;
            
            NLCheckbox *cbAimInfo = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbAimInfo.isOn = gAimInfoEnabled;
            cbAimInfo.onToggle = ^(BOOL v) { gAimInfoEnabled = v; [ConfigManager save]; };
            [gPanels addSubview:[[NLRow alloc] initWithTitle:@"Aim Info" y:py control:cbAimInfo swatch:nil]];
            py += 30;
            
            NLCheckbox *cbKB = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbKB.isOn = gKeybindListEnabled;
            cbKB.onToggle = ^(BOOL v) { gKeybindListEnabled = v; [ConfigManager save]; };
            [gPanels addSubview:[[NLRow alloc] initWithTitle:@"Keybind List" y:py control:cbKB swatch:nil]];
            py += 30;
            
            NLCheckbox *cbPanelBg = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbPanelBg.isOn = gPanelBackground;
            cbPanelBg.onToggle = ^(BOOL v) { gPanelBackground = v; [ConfigManager save]; };
            [gPanels addSubview:[[NLRow alloc] initWithTitle:@"Panel Background" y:py control:cbPanelBg swatch:nil]];
            py += 30;
            
            NLSlider *sPLX = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"px"];
            sPLX.min = 0.0f;
            sPLX.max = 1000.0f;
            sPLX.value = gPlayerListX;
            sPLX.onChange = ^(float v) { gPlayerListX = v; };
            sPLX.onRelease = ^(float v) { [ConfigManager save]; };
            [gPanels addSubview:[[NLRow alloc] initWithTitle:@"List X" y:py control:sPLX swatch:nil]];
            py += 30;
            
            NLSlider *sPLY = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"px"];
            sPLY.min = 0.0f;
            sPLY.max = 1000.0f;
            sPLY.value = gPlayerListY;
            sPLY.onChange = ^(float v) { gPlayerListY = v; };
            sPLY.onRelease = ^(float v) { [ConfigManager save]; };
            [gPanels addSubview:[[NLRow alloc] initWithTitle:@"List Y" y:py control:sPLY swatch:nil]];
            py += 30;
            
            NLSlider *sIPX = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"px"];
            sIPX.min = 0.0f;
            sIPX.max = 1000.0f;
            sIPX.value = gInfoPanelX;
            sIPX.onChange = ^(float v) { gInfoPanelX = v; };
            sIPX.onRelease = ^(float v) { [ConfigManager save]; };
            [gPanels addSubview:[[NLRow alloc] initWithTitle:@"Info X" y:py control:sIPX swatch:nil]];
            py += 30;
            
            NLSlider *sIPY = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"px"];
            sIPY.min = 0.0f;
            sIPY.max = 1000.0f;
            sIPY.value = gInfoPanelY;
            sIPY.onChange = ^(float v) { gInfoPanelY = v; };
            sIPY.onRelease = ^(float v) { [ConfigManager save]; };
            [gPanels addSubview:[[NLRow alloc] initWithTitle:@"Info Y" y:py control:sIPY swatch:nil]];
            py += 30;
            
            NLSlider *sELX = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"px"];
            sELX.min = 0.0f;
            sELX.max = 1000.0f;
            sELX.value = gEventLogX;
            sELX.onChange = ^(float v) { gEventLogX = v; };
            sELX.onRelease = ^(float v) { [ConfigManager save]; };
            [gPanels addSubview:[[NLRow alloc] initWithTitle:@"Log X" y:py control:sELX swatch:nil]];
            py += 30;
            
            NLSlider *sELY = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"px"];
            sELY.min = 0.0f;
            sELY.max = 1000.0f;
            sELY.value = gEventLogY;
            sELY.onChange = ^(float v) { gEventLogY = v; };
            sELY.onRelease = ^(float v) { [ConfigManager save]; };
            [gPanels addSubview:[[NLRow alloc] initWithTitle:@"Log Y" y:py control:sELY swatch:nil]];
            py += 30;
            
            NLSlider *sSTX = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"px"];
            sSTX.min = 0.0f;
            sSTX.max = 1000.0f;
            sSTX.value = gStatsPanelX;
            sSTX.onChange = ^(float v) { gStatsPanelX = v; };
            sSTX.onRelease = ^(float v) { [ConfigManager save]; };
            [gPanels addSubview:[[NLRow alloc] initWithTitle:@"Stats X" y:py control:sSTX swatch:nil]];
            py += 30;
            
            NLSlider *sSTY = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"px"];
            sSTY.min = 0.0f;
            sSTY.max = 1000.0f;
            sSTY.value = gStatsPanelY;
            sSTY.onChange = ^(float v) { gStatsPanelY = v; };
            sSTY.onRelease = ^(float v) { [ConfigManager save]; };
            [gPanels addSubview:[[NLRow alloc] initWithTitle:@"Stats Y" y:py control:sSTY swatch:nil]];
            py += 30;
            
            NLGroupBox *gSound = [[NLGroupBox alloc] initWithTitle:@"Sound & Feed" frame:CGRectMake(0, 2300, colW, 340)];
            [c2 addSubview:gSound];
            CGFloat sy = 30;
            
            NLCheckbox *cbHSnd = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbHSnd.isOn = gHitSoundEnabled;
            cbHSnd.onToggle = ^(BOOL v) { gHitSoundEnabled = v; [ConfigManager save]; };
            [gSound addSubview:[[NLRow alloc] initWithTitle:@"Hit Sound" y:sy control:cbHSnd swatch:nil]];
            sy += 30;
            
            NLSlider *sHPitch = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"Hz"];
            sHPitch.min = 200.0f;
            sHPitch.max = 6000.0f;
            sHPitch.value = gHitSoundPitch;
            sHPitch.onChange = ^(float v) { gHitSoundPitch = v; };
            sHPitch.onRelease = ^(float v) { RebuildSoundPlayers(); [ConfigManager save]; };
            [gSound addSubview:[[NLRow alloc] initWithTitle:@"Hit Pitch" y:sy control:sHPitch swatch:nil]];
            sy += 30;
            
            NLSlider *sHVol = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@""];
            sHVol.min = 0.0f;
            sHVol.max = 1.0f;
            sHVol.value = gHitSoundVolume;
            sHVol.onChange = ^(float v) { gHitSoundVolume = v; };
            sHVol.onRelease = ^(float v) { RebuildSoundPlayers(); [ConfigManager save]; };
            [gSound addSubview:[[NLRow alloc] initWithTitle:@"Hit Volume" y:sy control:sHVol swatch:nil]];
            sy += 30;
            
            NLCheckbox *cbKSnd = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbKSnd.isOn = gKillSoundEnabled;
            cbKSnd.onToggle = ^(BOOL v) { gKillSoundEnabled = v; [ConfigManager save]; };
            [gSound addSubview:[[NLRow alloc] initWithTitle:@"Kill Sound" y:sy control:cbKSnd swatch:nil]];
            sy += 30;
            
            NLSlider *sKPitch = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"Hz"];
            sKPitch.min = 200.0f;
            sKPitch.max = 6000.0f;
            sKPitch.value = gKillSoundPitch;
            sKPitch.onChange = ^(float v) { gKillSoundPitch = v; };
            sKPitch.onRelease = ^(float v) { RebuildSoundPlayers(); [ConfigManager save]; };
            [gSound addSubview:[[NLRow alloc] initWithTitle:@"Kill Pitch" y:sy control:sKPitch swatch:nil]];
            sy += 30;
            
            NLSlider *sKVol = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@""];
            sKVol.min = 0.0f;
            sKVol.max = 1.0f;
            sKVol.value = gKillSoundVolume;
            sKVol.onChange = ^(float v) { gKillSoundVolume = v; };
            sKVol.onRelease = ^(float v) { RebuildSoundPlayers(); [ConfigManager save]; };
            [gSound addSubview:[[NLRow alloc] initWithTitle:@"Kill Volume" y:sy control:sKVol swatch:nil]];
            sy += 30;
            
            NLCheckbox *cbKFSnd = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbKFSnd.isOn = gKillFeedEnabled;
            cbKFSnd.onToggle = ^(BOOL v) { gKillFeedEnabled = v; [ConfigManager save]; };
            [gSound addSubview:[[NLRow alloc] initWithTitle:@"Kill Feed" y:sy control:cbKFSnd swatch:nil]];
            sy += 30;
            
            NLSlider *sKFMax = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@""];
            sKFMax.min = 1.0f;
            sKFMax.max = 16.0f;
            sKFMax.value = (float)gKillFeedMax.load();
            sKFMax.onChange = ^(float v) { gKillFeedMax = (int)v; };
            sKFMax.onRelease = ^(float v) { [ConfigManager save]; };
            [gSound addSubview:[[NLRow alloc] initWithTitle:@"Feed Max" y:sy control:sKFMax swatch:nil]];
            sy += 30;
            
            NLSlider *sKFDur = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"ms"];
            sKFDur.min = 1500.0f;
            sKFDur.max = 15000.0f;
            sKFDur.value = gKillFeedDuration;
            sKFDur.onChange = ^(float v) { gKillFeedDuration = v; };
            sKFDur.onRelease = ^(float v) { [ConfigManager save]; };
            [gSound addSubview:[[NLRow alloc] initWithTitle:@"Feed Duration" y:sy control:sKFDur swatch:nil]];
            sy += 30;
            
            NLColorSwatch *swKF = [[NLColorSwatch alloc] initWithFrame:CGRectMake(0,0,16,16)];
            swKF.color = gKillFeedColor;
            __weak NLColorSwatch *weakSwKF = swKF;
            swKF.onTap = ^{
                [weakSelf showColorPickerForSwatch:weakSwKF currentColor:weakSwKF.color saveKey:@"c_kf"];
            };
            [gSound addSubview:[[NLRow alloc] initWithTitle:@"Feed Color" y:sy control:nil swatch:swKF]];
            sy += 30;
            
            // ---- Third person (camera only) ----
            // Lives under VISUALS because it is a pure presentation feature: the camera is
            // pulled back, nothing about aim, hitboxes or movement changes.
            NLGroupBox *gTp = [[NLGroupBox alloc] initWithTitle:@"Third Person" frame:CGRectMake(0, 2660, colW, 240)];
            [c2 addSubview:gTp];
            CGFloat ty = 30;
            
            NLCheckbox *cbTpOn = RageMakeCheckbox(gTpEnabled, ^(BOOL v) {
                gTpEnabled = v;
                [ConfigManager save];
            });
            [gTp addSubview:[[NLRow alloc] initWithTitle:@"Enable" y:ty control:cbTpOn swatch:nil]];
            ty += 30;
            
            NLSlider *sTpD = RageMakeSlider(gTpDistance, 0.3f, 15.0f, @"m", ^(float v) {
                gTpDistance = v;
            }, ^(float v) {
                gTpDistance = v;
                [ConfigManager save];
            });
            [gTp addSubview:[[NLRow alloc] initWithTitle:@"Distance" y:ty control:sTpD swatch:nil]];
            ty += 30;
            
            NLSlider *sTpH = RageMakeSlider(gTpHeight, -2.0f, 4.0f, @"m", ^(float v) {
                gTpHeight = v;
            }, ^(float v) {
                gTpHeight = v;
                [ConfigManager save];
            });
            [gTp addSubview:[[NLRow alloc] initWithTitle:@"Height" y:ty control:sTpH swatch:nil]];
            ty += 30;
            
            NLSlider *sTpS = RageMakeSlider(gTpShoulder, -2.0f, 2.0f, @"m", ^(float v) {
                gTpShoulder = v;
            }, ^(float v) {
                gTpShoulder = v;
                [ConfigManager save];
            });
            [gTp addSubview:[[NLRow alloc] initWithTitle:@"Shoulder" y:ty control:sTpS swatch:nil]];
            ty += 30;
            
            NLCheckbox *cbTpB = RageMakeCheckbox(gTpShowBody, ^(BOOL v) {
                gTpShowBody = v;
                [ConfigManager save];
            });
            [gTp addSubview:[[NLRow alloc] initWithTitle:@"Show Own Body" y:ty control:cbTpB swatch:nil]];
            ty += 30;
            
            NLSlider *sTpF = RageMakeSlider(gTpFov, 0.0f, 140.0f, @"°", ^(float v) {
                gTpFov = v;
            }, ^(float v) {
                gTpFov = v;
                [ConfigManager save];
            });
            [gTp addSubview:[[NLRow alloc] initWithTitle:@"Third Person FOV" y:ty control:sTpF swatch:nil]];
            ty += 30;
            
            // ---- Post FX: motion blur + frame pacing ----
            NLGroupBox *gPost = [[NLGroupBox alloc] initWithTitle:@"Post FX" frame:CGRectMake(0, 2910, colW, 150)];
            [c2 addSubview:gPost];
            CGFloat pfy = 30;
            
            NLCheckbox *cbMB = RageMakeCheckbox(gMotionBlurEnabled, ^(BOOL v) {
                gMotionBlurEnabled = v;
                gGradingDirty = true;
                [ConfigManager save];
            });
            [gPost addSubview:[[NLRow alloc] initWithTitle:@"Motion Blur" y:pfy control:cbMB swatch:nil]];
            pfy += 30;
            
            NLSlider *sMB = RageMakeSlider(gMotionBlurAmount, 0.0f, 1.0f, @"", ^(float v) {
                gMotionBlurAmount = v;
                gGradingDirty = true;
            }, ^(float v) {
                gMotionBlurAmount = v;
                gGradingDirty = true;
                [ConfigManager save];
            });
            [gPost addSubview:[[NLRow alloc] initWithTitle:@"Blur Amount" y:pfy control:sMB swatch:nil]];
            pfy += 30;
            
            NLSlider *sFps = RageMakeSlider((float)gFpsLimit.load(), 30.0f, 144.0f, @"fps", ^(float v) {
                gFpsLimit = (int)v;
                ApplyFpsLimit();
            }, ^(float v) {
                gFpsLimit = (int)v;
                ApplyFpsLimit();
                [ConfigManager save];
            });
            [gPost addSubview:[[NLRow alloc] initWithTitle:@"FPS Limit" y:pfy control:sFps swatch:nil]];
            pfy += 30;
            
            NLGroupBox *gExtra = [[NLGroupBox alloc] initWithTitle:@"HUD Extras" frame:CGRectMake(0, 3070, colW, 210)];
            [c2 addSubview:gExtra];
            CGFloat exy = 30;
            
            NLCheckbox *cbSnap = RageMakeCheckbox(gSnapBottomEnabled, ^(BOOL v) {
                gSnapBottomEnabled = v;
                [ConfigManager save];
            });
            [gExtra addSubview:[[NLRow alloc] initWithTitle:@"Snap Bottom" y:exy control:cbSnap swatch:nil]];
            exy += 30;
            
            NLCheckbox *cbKF2 = RageMakeCheckbox(gKillFeedEnabled, ^(BOOL v) {
                gKillFeedEnabled = v;
                [ConfigManager save];
            });
            [gExtra addSubview:[[NLRow alloc] initWithTitle:@"Kill Feed" y:exy control:cbKF2 swatch:nil]];
            exy += 30;
            
            NLSlider *sBoxStyle = RageMakeSlider((float)gBoxStyle, 0.0f, 3.0f, @"", ^(float v) {
                gBoxStyle = (int)v;
            }, ^(float v) {
                gBoxStyle = (int)v;
                [ConfigManager save];
            });
            [gExtra addSubview:[[NLRow alloc] initWithTitle:@"Box Style" y:exy control:sBoxStyle swatch:nil]];
            exy += 30;
            
            NLSlider *sSkel2 = RageMakeSlider(gSkelThickness, 0.5f, 4.0f, @"px", ^(float v) {
                gSkelThickness = v;
            }, ^(float v) {
                gSkelThickness = v;
                [ConfigManager save];
            });
            [gExtra addSubview:[[NLRow alloc] initWithTitle:@"Skeleton Width" y:exy control:sSkel2 swatch:nil]];
            exy += 30;
            
            NLSlider *sRR = RageMakeSlider((float)gRadarRange, 20.0f, 200.0f, @"m", ^(float v) {
                gRadarRange = (int)v;
            }, ^(float v) {
                gRadarRange = (int)v;
                [ConfigManager save];
            });
            [gExtra addSubview:[[NLRow alloc] initWithTitle:@"Radar Range" y:exy control:sRR swatch:nil]];
            exy += 30;
            
            NLSlider *sRS = RageMakeSlider(gRadarSize, 70.0f, 220.0f, @"px", ^(float v) {
                gRadarSize = v;
            }, ^(float v) {
                gRadarSize = v;
                [ConfigManager save];
            });
            [gExtra addSubview:[[NLRow alloc] initWithTitle:@"Radar Size" y:exy control:sRS swatch:nil]];
            exy += 30;
            
        } else if (_currentTab == 3) {
            NLGroupBox *gWV = [[NLGroupBox alloc] initWithTitle:@"World View" frame:CGRectMake(0, 0, colW, 240)];
            [c1 addSubview:gWV];
            CGFloat y = 30;
            
            NLCheckbox *cbFB = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbFB.isOn = gFullbrightEnabled;
            cbFB.onToggle = ^(BOOL v) {
                gFullbrightEnabled = v;
                [ConfigManager save];
            };
            [gWV addSubview:[[NLRow alloc] initWithTitle:@"Fullbright" y:y control:cbFB swatch:nil]];
            y += 30;
            
            NLSlider *sFB = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"x"];
            sFB.min = 1.0f;
            sFB.max = 5.0f;
            sFB.value = gFullbrightMul;
            sFB.onChange = ^(float v) {
                gFullbrightMul = v;
            };
            sFB.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gWV addSubview:[[NLRow alloc] initWithTitle:@"Brightness" y:y control:sFB swatch:nil]];
            y += 30;
            
            NLCheckbox *cbNF = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbNF.isOn = gNoFogEnabled;
            cbNF.onToggle = ^(BOOL v) {
                gNoFogEnabled = v;
                [ConfigManager save];
            };
            [gWV addSubview:[[NLRow alloc] initWithTitle:@"No Fog" y:y control:cbNF swatch:nil]];
            y += 30;
            
            NLCheckbox *cbAmb = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbAmb.isOn = gAmbientTintEnabled;
            cbAmb.onToggle = ^(BOOL v) {
                gAmbientTintEnabled = v;
                [ConfigManager save];
            };
            
            NLColorSwatch *swAmb = [[NLColorSwatch alloc] initWithFrame:CGRectMake(0,0,16,16)];
            uint32_t hAmb = gAmbientColorHex.load();
            swAmb.color = [UIColor colorWithRed:((hAmb >> 24) & 0xFF)/255.0 green:((hAmb >> 16) & 0xFF)/255.0 blue:((hAmb >> 8) & 0xFF)/255.0 alpha:((hAmb & 0xFF) & 0xFF)/255.0];
            __weak NLColorSwatch *weakSwAmb = swAmb;
            swAmb.onTap = ^{
                [weakSelf showColorPickerForSwatch:weakSwAmb currentColor:weakSwAmb.color saveKey:@"wv_amb_c"];
            };
            
            [gWV addSubview:[[NLRow alloc] initWithTitle:@"Ambient Tint" y:y control:cbAmb swatch:swAmb]];
            y += 30;
            
            NLSlider *sSharp = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@""];
            sSharp.min = 0.0f;
            sSharp.max = 1.0f;
            sSharp.value = gSharpenVal;
            sSharp.onChange = ^(float v) {
                gSharpenVal = v;
            };
            sSharp.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gWV addSubview:[[NLRow alloc] initWithTitle:@"Sharpen" y:y control:sSharp swatch:nil]];
            y += 30;
            
            NLSlider *sBloom = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@""];
            sBloom.min = 0.0f;
            sBloom.max = 10.0f;
            sBloom.value = gBloomVal;
            sBloom.onChange = ^(float v) {
                gBloomVal = v;
                gGradingDirty = true;
            };
            sBloom.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gWV addSubview:[[NLRow alloc] initWithTitle:@"Bloom" y:y control:sBloom swatch:nil]];
            y += 30;
            
            NLCheckbox *cbSnow = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbSnow.isOn = gSnowEnabled;
            cbSnow.onToggle = ^(BOOL v) {
                gSnowEnabled = v;
                SnowOverlaySetEnabled(v);
                [ConfigManager save];
            };
            [gWV addSubview:[[NLRow alloc] initWithTitle:@"Snow" y:y control:cbSnow swatch:nil]];
            y += 30;
            
            NLGroupBox *gSky = [[NLGroupBox alloc] initWithTitle:@"Skybox Presets" frame:CGRectMake(0, 250, colW, 120)];
            [c1 addSubview:gSky];
            y = 30;
            
            NLColorSwatch *swSky = [[NLColorSwatch alloc] initWithFrame:CGRectMake(0,0,16,16)];
            swSky.color = [UIColor colorWithRed:((gSkyboxColorHex >> 24) & 0xFF)/255.0 green:((gSkyboxColorHex >> 16) & 0xFF)/255.0 blue:((gSkyboxColorHex >> 8) & 0xFF)/255.0 alpha:(gSkyboxColorHex & 0xFF)/255.0];
            __weak NLColorSwatch *weakSwSky = swSky;
            swSky.onTap = ^{
                [weakSelf showColorPickerForSwatch:weakSwSky currentColor:weakSwSky.color saveKey:@"v_sky_c"];
            };
            
            NLCheckbox *cbSky = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbSky.isOn = gSkyboxEnabled;
            cbSky.onToggle = ^(BOOL v) {
                gSkyboxEnabled = v;
                gSkyboxDirty = true;
                [ConfigManager save];
            };
            [gSky addSubview:[[NLRow alloc] initWithTitle:@"Sky Color" y:y control:cbSky swatch:swSky]];
            y += 30;
            
            NSArray *presetNames = @[@"Sunset", @"Night", @"Neon", @"Haze", @"Blue"];
            CGFloat pw = (colW - 30 - 12) / 5.0;
            for (int i = 0; i < 5; i++) {
                UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
                b.frame = CGRectMake(15 + i * (pw + 3), y, pw, 20);
                b.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
                [b setTitle:presetNames[i] forState:UIControlStateNormal];
                [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
                b.titleLabel.font = [UIFont systemFontOfSize:9];
                b.layer.cornerRadius = 3;
                b.tag = 2000 + i;
                [b addTarget:weakSelf action:@selector(skyPresetTap:) forControlEvents:UIControlEventTouchUpInside];
                [gSky addSubview:b];
            }
            
            NLGroupBox *gCG = [[NLGroupBox alloc] initWithTitle:@"Color Grading" frame:CGRectMake(0, 0, colW, 150)];
            [c2 addSubview:gCG];
            y = 30;
            
            NLSlider *sSat = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@""];
            sSat.min = -100.0f;
            sSat.max = 100.0f;
            sSat.value = gSaturationVal;
            sSat.onChange = ^(float v) {
                gSaturationVal = v;
                gGradingDirty = true;
            };
            sSat.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gCG addSubview:[[NLRow alloc] initWithTitle:@"Saturation" y:y control:sSat swatch:nil]];
            y += 30;
            
            NLSlider *sCon = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@""];
            sCon.min = -100.0f;
            sCon.max = 100.0f;
            sCon.value = gContrastVal;
            sCon.onChange = ^(float v) {
                gContrastVal = v;
                gGradingDirty = true;
            };
            sCon.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gCG addSubview:[[NLRow alloc] initWithTitle:@"Contrast" y:y control:sCon swatch:nil]];
            y += 30;
            
            NLSlider *sGam = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"EV"];
            sGam.min = -3.0f;
            sGam.max = 3.0f;
            sGam.value = gGammaVal;
            sGam.onChange = ^(float v) {
                gGammaVal = v;
                gGradingDirty = true;
            };
            sGam.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gCG addSubview:[[NLRow alloc] initWithTitle:@"Gamma" y:y control:sGam swatch:nil]];
            y += 30;
            
        } else if (_currentTab == 4) {
            NLGroupBox *gMove = [[NLGroupBox alloc] initWithTitle:@"Movement" frame:CGRectMake(0, 0, colW, 280)];
            [c1 addSubview:gMove];
            CGFloat y = 30;
            
            NLCheckbox *cbSH = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbSH.isOn = gSpeedHackEnabled;
            cbSH.onToggle = ^(BOOL v) {
                gSpeedHackEnabled = v;
                [ConfigManager save];
            };
            [gMove addSubview:[[NLRow alloc] initWithTitle:@"Speed Hack" y:y control:cbSH swatch:nil]];
            y += 30;
            
            NLSlider *sSpd = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"x"];
            sSpd.min = 1.0f;
            sSpd.max = 5.0f;
            sSpd.value = gSpeedHackVal;
            sSpd.onChange = ^(float v) {
                gSpeedHackVal = v;
            };
            sSpd.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gMove addSubview:[[NLRow alloc] initWithTitle:@"Speed Multi" y:y control:sSpd swatch:nil]];
            y += 30;
            
            NLCheckbox *cbJH = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbJH.isOn = gJumpHackEnabled;
            cbJH.onToggle = ^(BOOL v) {
                gJumpHackEnabled = v;
                [ConfigManager save];
            };
            [gMove addSubview:[[NLRow alloc] initWithTitle:@"Jump Height" y:y control:cbJH swatch:nil]];
            y += 30;
            
            NLSlider *sJmp = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"x"];
            sJmp.min = 1.0f;
            sJmp.max = 5.0f;
            sJmp.value = gJumpHackVal;
            sJmp.onChange = ^(float v) {
                gJumpHackVal = v;
            };
            sJmp.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gMove addSubview:[[NLRow alloc] initWithTitle:@"Jump Multi" y:y control:sJmp swatch:nil]];
            y += 30;
            
            NLGroupBox *gWeapon = [[NLGroupBox alloc] initWithTitle:@"Weapon" frame:CGRectMake(0, 0, colW, 480)];
            [c2 addSubview:gWeapon];
            y = 30;
            
            NLCheckbox *cbRF = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbRF.isOn = gRapidFireEnabled;
            cbRF.onToggle = ^(BOOL v) {
                gRapidFireEnabled = v;
                [ConfigManager save];
            };
            [gWeapon addSubview:[[NLRow alloc] initWithTitle:@"Rapid Fire" y:y control:cbRF swatch:nil]];
            y += 30;
            
            NLCheckbox *cbIR = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbIR.isOn = gInstantReloadEnabled;
            cbIR.onToggle = ^(BOOL v) {
                gInstantReloadEnabled = v;
                [ConfigManager save];
            };
            [gWeapon addSubview:[[NLRow alloc] initWithTitle:@"Instant Reload" y:y control:cbIR swatch:nil]];
            y += 30;
            
            NLCheckbox *cbUA = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbUA.isOn = gUnlimAmmoEnabled;
            cbUA.onToggle = ^(BOOL v) {
                gUnlimAmmoEnabled = v;
                [ConfigManager save];
            };
            [gWeapon addSubview:[[NLRow alloc] initWithTitle:@"Unlim Ammo" y:y control:cbUA swatch:nil]];
            y += 30;
            
            NLCheckbox *cbSFE = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbSFE.isOn = gSpreadFloorEnabled;
            cbSFE.onToggle = ^(BOOL v) {
                gSpreadFloorEnabled = v;
                [ConfigManager save];
            };
            [gWeapon addSubview:[[NLRow alloc] initWithTitle:@"Spread Floor" y:y control:cbSFE swatch:nil]];
            y += 30;
            
            NLSlider *sFloor = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@""];
            sFloor.min = 0.0f;
            sFloor.max = 0.02f;
            sFloor.value = gSpreadFloor;
            sFloor.onChange = ^(float v) {
                gSpreadFloor = v;
            };
            sFloor.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gWeapon addSubview:[[NLRow alloc] initWithTitle:@"Floor Value" y:y control:sFloor swatch:nil]];
            y += 30;
            
            NLCheckbox *cbBD = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbBD.isOn = gBallisticsDebug;
            cbBD.onToggle = ^(BOOL v) {
                gBallisticsDebug = v;
                [ConfigManager save];
            };
            [gWeapon addSubview:[[NLRow alloc] initWithTitle:@"Ballistics Debug" y:y control:cbBD swatch:nil]];
            y += 30;
            
        } else if (_currentTab == 5) {
            NLGroupBox *gVis = [[NLGroupBox alloc] initWithTitle:@"World & View" frame:CGRectMake(0, 0, colW, 450)];
            [c1 addSubview:gVis];
            CGFloat y = 30;
            
            NLCheckbox *cbFOV = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbFOV.isOn = gCamFovEnabled;
            cbFOV.onToggle = ^(BOOL v) {
                gCamFovEnabled = v;
                [ConfigManager save];
            };
            [gVis addSubview:[[NLRow alloc] initWithTitle:@"Custom FOV" y:y control:cbFOV swatch:nil]];
            y += 30;
            
            NLSlider *sFov = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"°"];
            sFov.min = 60;
            sFov.max = 140;
            sFov.value = gCamFovVal;
            sFov.onChange = ^(float v) {
                gCamFovVal = v;
            };
            sFov.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gVis addSubview:[[NLRow alloc] initWithTitle:@"FOV Size" y:y control:sFov swatch:nil]];
            y += 30;
            
            NLCheckbox *cbVMFOV = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbVMFOV.isOn = gViewmodelFovEnabled;
            cbVMFOV.onToggle = ^(BOOL v) {
                gViewmodelFovEnabled = v;
                [ConfigManager save];
            };
            [gVis addSubview:[[NLRow alloc] initWithTitle:@"Hands FOV" y:y control:cbVMFOV swatch:nil]];
            y += 30;
            
            NLSlider *sVMFov = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"°"];
            sVMFov.min = 30;
            sVMFov.max = 140;
            sVMFov.value = gViewmodelFovVal;
            sVMFov.onChange = ^(float v) {
                gViewmodelFovVal = v;
            };
            sVMFov.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gVis addSubview:[[NLRow alloc] initWithTitle:@"Hands FOV Size" y:y control:sVMFov swatch:nil]];
            y += 30;
            
            NLCheckbox *cbAsp = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbAsp.isOn = gAspectEnabled;
            cbAsp.onToggle = ^(BOOL v) {
                gAspectEnabled = v;
                [ConfigManager save];
            };
            [gVis addSubview:[[NLRow alloc] initWithTitle:@"Aspect Ratio" y:y control:cbAsp swatch:nil]];
            y += 30;
            
            NLSlider *sAsp = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@""];
            sAsp.min = 0.5f;
            sAsp.max = 2.5f;
            sAsp.value = gAspectVal;
            sAsp.onChange = ^(float v) {
                gAspectVal = v;
            };
            sAsp.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gVis addSubview:[[NLRow alloc] initWithTitle:@"Aspect Size" y:y control:sAsp swatch:nil]];
            y += 30;
            
            NLCheckbox *cbNM = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbNM.isOn = gNightModeEnabled;
            cbNM.onToggle = ^(BOOL v) {
                gNightModeEnabled = v;
                [ConfigManager save];
            };
            [gVis addSubview:[[NLRow alloc] initWithTitle:@"Nightmode" y:y control:cbNM swatch:nil]];
            y += 30;
            
            NLGroupBox *gQuick = [[NLGroupBox alloc] initWithTitle:@"Quick Toggles" frame:CGRectMake(0, 0, colW, 240)];
            [c2 addSubview:gQuick];
            CGFloat qy = 30;
            
            NLCheckbox *cbQA = RageMakeCheckbox(gHotAimbotEnabled, ^(BOOL v) {
                gHotAimbotEnabled = v;
                [ConfigManager save];
            });
            [gQuick addSubview:[[NLRow alloc] initWithTitle:@"Hotkey Aimbot" y:qy control:cbQA swatch:nil]];
            qy += 30;
            
            NLCheckbox *cbQAF = RageMakeCheckbox(gHotAimOnFireEnabled, ^(BOOL v) {
                gHotAimOnFireEnabled = v;
                [ConfigManager save];
            });
            [gQuick addSubview:[[NLRow alloc] initWithTitle:@"Hotkey Aim Fire" y:qy control:cbQAF swatch:nil]];
            qy += 30;
            
            NLCheckbox *cbQE = RageMakeCheckbox(gHotEspEnabled, ^(BOOL v) {
                gHotEspEnabled = v;
                [ConfigManager save];
            });
            [gQuick addSubview:[[NLRow alloc] initWithTitle:@"Hotkey ESP" y:qy control:cbQE swatch:nil]];
            qy += 30;
            
            NLCheckbox *cbQS = RageMakeCheckbox(gSnowEnabled, ^(BOOL v) {
                gSnowEnabled = v;
                SnowOverlaySetEnabled(v);
                [ConfigManager save];
            });
            [gQuick addSubview:[[NLRow alloc] initWithTitle:@"Snow" y:qy control:cbQS swatch:nil]];
            qy += 30;
            
            NLCheckbox *cbQM = RageMakeCheckbox(gMotionBlurEnabled, ^(BOOL v) {
                gMotionBlurEnabled = v;
                gGradingDirty = true;
                [ConfigManager save];
            });
            [gQuick addSubview:[[NLRow alloc] initWithTitle:@"Motion Blur" y:qy control:cbQM swatch:nil]];
            qy += 30;
            
            NLCheckbox *cbQF = RageMakeCheckbox(gFpsEnabled, ^(BOOL v) {
                gFpsEnabled = v;
                [ConfigManager save];
            });
            [gQuick addSubview:[[NLRow alloc] initWithTitle:@"Show FPS" y:qy control:cbQF swatch:nil]];
            qy += 30;
            
            NLGroupBox *gReset = [[NLGroupBox alloc] initWithTitle:@"Reset" frame:CGRectMake(0, 250, colW, 90)];
            [c2 addSubview:gReset];
            CGFloat ry = 30;
            
            NLButton *bResetCfg = [[NLButton alloc] initWithTitle:@"Reset"];
            bResetCfg.onTap = ^{
                NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
                NSDictionary *all = [d dictionaryRepresentation];
                for (NSString *k in all) {
                    if ([k hasPrefix:@"cfg_slot_"]) {
                        continue;
                    }
                    [d removeObjectForKey:k];
                }
                [d synchronize];
                [ConfigManager load];
                [weakSelf buildContent];
            };
            [gReset addSubview:[[NLRow alloc] initWithTitle:@"Defaults" y:ry control:bResetCfg swatch:nil]];
            ry += 30;
            
        } else if (_currentTab == 6) {
            NLGroupBox *gSet = [[NLGroupBox alloc] initWithTitle:@"Settings" frame:CGRectMake(0, 0, colW, 270)];
            [c1 addSubview:gSet];
            CGFloat y = 30;
            
            NLCheckbox *cbSM = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbSM.isOn = gStreamMode;
            cbSM.onToggle = ^(BOOL v) {
                gStreamMode = v;
                UpdateStreamMode();
            };
            [gSet addSubview:[[NLRow alloc] initWithTitle:@"Stream Mode" y:y control:cbSM swatch:nil]];
            y += 30;
            
            NLCheckbox *cbHS = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbHS.isOn = gHitSoundEnabled;
            cbHS.onToggle = ^(BOOL v) {
                gHitSoundEnabled = v;
                [ConfigManager save];
            };
            [gSet addSubview:[[NLRow alloc] initWithTitle:@"Hit Sound" y:y control:cbHS swatch:nil]];
            y += 30;
            
            NLButton *bSaveCfg = [[NLButton alloc] initWithTitle:@"Save Config"];
            bSaveCfg.onTap = ^{
                [ConfigManager save];
            };
            [gSet addSubview:[[NLRow alloc] initWithTitle:@"Config" y:y control:bSaveCfg swatch:nil]];
            y += 30;
            
            NLButton *bLoadCfg = [[NLButton alloc] initWithTitle:@"Load Config"];
            bLoadCfg.onTap = ^{
                [ConfigManager load];
                [weakSelf buildContent];
            };
            [gSet addSubview:[[NLRow alloc] initWithTitle:@"" y:y control:bLoadCfg swatch:nil]];
            y += 30;
            
            NLCheckbox *cbHA = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbHA.isOn = gHotAimbotEnabled;
            cbHA.onToggle = ^(BOOL v) {
                gHotAimbotEnabled = v;
                [ConfigManager save];
            };
            [gSet addSubview:[[NLRow alloc] initWithTitle:@"Hotkey: Aimbot" y:y control:cbHA swatch:nil]];
            y += 30;
            
            NLCheckbox *cbHAF = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbHAF.isOn = gHotAimOnFireEnabled;
            cbHAF.onToggle = ^(BOOL v) {
                gHotAimOnFireEnabled = v;
                [ConfigManager save];
            };
            [gSet addSubview:[[NLRow alloc] initWithTitle:@"Hotkey: Aim On Fire" y:y control:cbHAF swatch:nil]];
            y += 30;
            
            NLCheckbox *cbHES = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbHES.isOn = gHotEspEnabled;
            cbHES.onToggle = ^(BOOL v) {
                gHotEspEnabled = v;
                [ConfigManager save];
            };
            [gSet addSubview:[[NLRow alloc] initWithTitle:@"Hotkey: ESP" y:y control:cbHES swatch:nil]];
            y += 30;
            
            NLGroupBox *gColors = [[NLGroupBox alloc] initWithTitle:@"Panel Colors" frame:CGRectMake(0, 0, colW, 240)];
            [c2 addSubview:gColors];
            CGFloat ccy = 30;
            
            NLColorSwatch *swStats = [[NLColorSwatch alloc] initWithFrame:CGRectMake(0,0,16,16)];
            swStats.color = gStatsColor;
            __weak NLColorSwatch *weakSwStats = swStats;
            swStats.onTap = ^{
                [weakSelf showColorPickerForSwatch:weakSwStats currentColor:weakSwStats.color saveKey:@"c_stats"];
            };
            [gColors addSubview:[[NLRow alloc] initWithTitle:@"Stats" y:ccy control:nil swatch:swStats]];
            ccy += 30;
            
            NLColorSwatch *swAimInfo = [[NLColorSwatch alloc] initWithFrame:CGRectMake(0,0,16,16)];
            swAimInfo.color = gAimInfoColor;
            __weak NLColorSwatch *weakSwAimInfo = swAimInfo;
            swAimInfo.onTap = ^{
                [weakSelf showColorPickerForSwatch:weakSwAimInfo currentColor:weakSwAimInfo.color saveKey:@"c_ai"];
            };
            [gColors addSubview:[[NLRow alloc] initWithTitle:@"Aim Info" y:ccy control:nil swatch:swAimInfo]];
            ccy += 30;
            
            NLColorSwatch *swDmgLog = [[NLColorSwatch alloc] initWithFrame:CGRectMake(0,0,16,16)];
            swDmgLog.color = gDamageLogColor;
            __weak NLColorSwatch *weakSwDmgLog = swDmgLog;
            swDmgLog.onTap = ^{
                [weakSelf showColorPickerForSwatch:weakSwDmgLog currentColor:weakSwDmgLog.color saveKey:@"c_dl"];
            };
            [gColors addSubview:[[NLRow alloc] initWithTitle:@"Damage Log" y:ccy control:nil swatch:swDmgLog]];
            ccy += 30;
            
            NLColorSwatch *swELog = [[NLColorSwatch alloc] initWithFrame:CGRectMake(0,0,16,16)];
            swELog.color = gEventLogColor;
            __weak NLColorSwatch *weakSwELog = swELog;
            swELog.onTap = ^{
                [weakSelf showColorPickerForSwatch:weakSwELog currentColor:weakSwELog.color saveKey:@"c_elog"];
            };
            [gColors addSubview:[[NLRow alloc] initWithTitle:@"Event Log" y:ccy control:nil swatch:swELog]];
            ccy += 30;
            
            NLColorSwatch *swPList = [[NLColorSwatch alloc] initWithFrame:CGRectMake(0,0,16,16)];
            swPList.color = gPlayerListColor;
            __weak NLColorSwatch *weakSwPList = swPList;
            swPList.onTap = ^{
                [weakSelf showColorPickerForSwatch:weakSwPList currentColor:weakSwPList.color saveKey:@"c_plist"];
            };
            [gColors addSubview:[[NLRow alloc] initWithTitle:@"Player List" y:ccy control:nil swatch:swPList]];
            ccy += 30;
            
            NLColorSwatch *swIPanel = [[NLColorSwatch alloc] initWithFrame:CGRectMake(0,0,16,16)];
            swIPanel.color = gInfoPanelColor;
            __weak NLColorSwatch *weakSwIPanel = swIPanel;
            swIPanel.onTap = ^{
                [weakSelf showColorPickerForSwatch:weakSwIPanel currentColor:weakSwIPanel.color saveKey:@"c_ip"];
            };
            [gColors addSubview:[[NLRow alloc] initWithTitle:@"Info Panel" y:ccy control:nil swatch:swIPanel]];
            ccy += 30;
            
            NLGroupBox *gMenu = [[NLGroupBox alloc] initWithTitle:@"Menu" frame:CGRectMake(0, 250, colW, 180)];
            [c2 addSubview:gMenu];
            CGFloat my = 30;
            
            NLColorSwatch *swAccent = [[NLColorSwatch alloc] initWithFrame:CGRectMake(0,0,16,16)];
            swAccent.color = NLAccent();
            __weak NLColorSwatch *weakSwAccent = swAccent;
            swAccent.onTap = ^{
                [weakSelf showColorPickerForSwatch:weakSwAccent currentColor:weakSwAccent.color saveKey:@"m_accent"];
            };
            [gMenu addSubview:[[NLRow alloc] initWithTitle:@"Accent" y:my control:nil swatch:swAccent]];
            my += 30;
            
            NLSlider *sOpacity = RageMakeSlider(gMenuOpacity, 0.5f, 1.0f, @"", ^(float v) {
                gMenuOpacity = v;
                [weakSelf applyMenuStyle];
            }, ^(float v) {
                gMenuOpacity = v;
                [weakSelf applyMenuStyle];
                [ConfigManager save];
            });
            [gMenu addSubview:[[NLRow alloc] initWithTitle:@"Opacity" y:my control:sOpacity swatch:nil]];
            my += 30;
            
            NLSlider *sScale = RageMakeSlider(gMenuScale, 0.8f, 1.2f, @"x", ^(float v) {
                gMenuScale = v;
                [weakSelf applyMenuStyle];
            }, ^(float v) {
                gMenuScale = v;
                [weakSelf applyMenuStyle];
                [ConfigManager save];
            });
            [gMenu addSubview:[[NLRow alloc] initWithTitle:@"Scale" y:my control:sScale swatch:nil]];
            my += 30;
            
            NLCheckbox *cbBlur = RageMakeCheckbox(gMenuBlurEnabled, ^(BOOL v) {
                gMenuBlurEnabled = v;
                [weakSelf applyMenuStyle];
                [ConfigManager save];
            });
            [gMenu addSubview:[[NLRow alloc] initWithTitle:@"Blur" y:my control:cbBlur swatch:nil]];
            my += 30;
            
            NLGroupBox *gDiag = [[NLGroupBox alloc] initWithTitle:@"Diagnostics" frame:CGRectMake(0, 440, colW, 210)];
            [c2 addSubview:gDiag];
            CGFloat dy = 30;
            
            NLCheckbox *cbFps = RageMakeCheckbox(gFpsEnabled, ^(BOOL v) {
                gFpsEnabled = v;
                [ConfigManager save];
            });
            [gDiag addSubview:[[NLRow alloc] initWithTitle:@"Show FPS" y:dy control:cbFps swatch:nil]];
            dy += 30;
            
            NLCheckbox *cbKb = RageMakeCheckbox(gKeybindListEnabled, ^(BOOL v) {
                gKeybindListEnabled = v;
                [ConfigManager save];
            });
            [gDiag addSubview:[[NLRow alloc] initWithTitle:@"Keybind List" y:dy control:cbKb swatch:nil]];
            dy += 30;
            
            NLCheckbox *cbWmF = RageMakeCheckbox(gWatermarkShowFps, ^(BOOL v) {
                gWatermarkShowFps = v;
                [ConfigManager save];
            });
            [gDiag addSubview:[[NLRow alloc] initWithTitle:@"Watermark FPS" y:dy control:cbWmF swatch:nil]];
            dy += 30;
            
            NLCheckbox *cbWmT = RageMakeCheckbox(gWatermarkShowTime, ^(BOOL v) {
                gWatermarkShowTime = v;
                [ConfigManager save];
            });
            [gDiag addSubview:[[NLRow alloc] initWithTitle:@"Watermark Time" y:dy control:cbWmT swatch:nil]];
            dy += 30;
            
            NLCheckbox *cbWmP = RageMakeCheckbox(gWatermarkShowPlayers, ^(BOOL v) {
                gWatermarkShowPlayers = v;
                [ConfigManager save];
            });
            [gDiag addSubview:[[NLRow alloc] initWithTitle:@"Watermark Players" y:dy control:cbWmP swatch:nil]];
            dy += 30;
            
            NLCheckbox *cbRR = RageMakeCheckbox(gRadarRotate, ^(BOOL v) {
                gRadarRotate = v;
                [ConfigManager save];
            });
            [gDiag addSubview:[[NLRow alloc] initWithTitle:@"Radar Rotate" y:dy control:cbRR swatch:nil]];
            dy += 30;
        } else if (_currentTab == 7) {
            SkinCatalogLoad();

            // ---- left: master switch + full weapon list ----
            NLGroupBox *gSkinTop = [[NLGroupBox alloc] initWithTitle:@"Skin Changer" frame:CGRectMake(0, 0, colW, 126)];
            [c1 addSubview:gSkinTop];
            CGFloat ty = 30;

            NLCheckbox *cbSkin = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbSkin.isOn = gSkinChangerEnabled;
            cbSkin.onToggle = ^(BOOL v) {
                gSkinChangerEnabled = v;
                if (v) {
                    SkinCatalogLoad();
                    SkinApply();
                }
                [ConfigManager save];
                [weakSelf buildContent];
            };
            [gSkinTop addSubview:[[NLRow alloc] initWithTitle:@"Enable" y:ty control:cbSkin swatch:nil]];
            ty += 30;

            NLButton *bReset = [[NLButton alloc] initWithTitle:@"Reset"];
            bReset.onTap = ^{
                gSkinSelectedObj = nullptr;
                gSkinSelectedId.clear();
                gSkinSelectedTarget.clear();
                gSkinLastAppliedWeapon = nullptr;
                [weakSelf buildContent];
            };
            [gSkinTop addSubview:[[NLRow alloc] initWithTitle:@"Clear" y:ty control:bReset swatch:nil]];
            ty += 30;

            NLButton *bRefresh = [[NLButton alloc] initWithTitle:@"Refresh"];
            bRefresh.onTap = ^{
                gSkinCatalogLoaded = false;
                SkinCatalogLoad();
                [weakSelf buildContent];
            };
            [gSkinTop addSubview:[[NLRow alloc] initWithTitle:@"Catalog" y:ty control:bRefresh swatch:nil]];

            CGFloat weaponsH = 30 + (CGFloat)gWeaponList.size() * 28 + 10;
            if (weaponsH < 80) {
                weaponsH = 80;
            }
            if (weaponsH > columnHeight - 136) {
                weaponsH = columnHeight - 136;
            }
            NLGroupBox *gWeapons = [[NLGroupBox alloc] initWithTitle:@"Weapons" frame:CGRectMake(0, 136, colW, weaponsH)];
            [c1 addSubview:gWeapons];
            CGFloat wy = 30;
            for (int i = 0; i < (int)gWeaponList.size(); i++) {
                const WeaponEntry& w = gWeaponList[i];
                NSString *title = [NSString stringWithFormat:@"%s", w.label.c_str()];
                NSString *detail = w.skinCount > 0 ? [NSString stringWithFormat:@"%d", w.skinCount] : @"—";
                NLSkinRow *row = [[NLSkinRow alloc] initWithTitle:title
                                                           detail:detail
                                                           rarity:-1
                                                         selected:(i == gSkinTargetIndex)];
                row.frame = CGRectMake(10, wy, colW - 20, 26);
                int idx = i;
                row.onTap = ^{
                    gSkinTargetIndex = idx;
                    gSkinIndex = 0;
                    SkinRebuildFilter();
                    SkinSelectCurrent();
                    [weakSelf buildContent];
                };
                [gWeapons addSubview:row];
                wy += 28;
            }

            // ---- right: skins for the selected weapon ----
            NSString *weaponLabel = gWeaponList.empty()
                ? @"—"
                : [NSString stringWithFormat:@"%s", gWeaponList[gSkinTargetIndex].label.c_str()];
            CGFloat skinsH = 30 + (CGFloat)gSkinFiltered.size() * 28 + 10;
            if (skinsH < 80) {
                skinsH = 80;
            }
            if (skinsH > columnHeight) {
                skinsH = columnHeight;
            }
            NLGroupBox *gSkins = [[NLGroupBox alloc] initWithTitle:[NSString stringWithFormat:@"Skins · %@", weaponLabel]
                                                             frame:CGRectMake(0, 0, colW, skinsH)];
            [c2 addSubview:gSkins];
            CGFloat sy = 30;

            if (gSkinFiltered.empty()) {
                UILabel *empty = [[UILabel alloc] initWithFrame:CGRectMake(12, sy, colW - 24, 44)];
                empty.text = @"No skins for this weapon";
                empty.textColor = [UIColor grayColor];
                empty.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
                empty.numberOfLines = 0;
                [gSkins addSubview:empty];
            } else {
                for (int k = 0; k < (int)gSkinFiltered.size(); k++) {
                    const SkinEntry& s = gSkinCatalog[gSkinFiltered[k]];
                    bool applied = (gSkinSelectedObj == s.obj);
                    NLSkinRow *row = [[NLSkinRow alloc] initWithTitle:[NSString stringWithFormat:@"%s", s.id.c_str()]
                                                               detail:[NSString stringWithFormat:@"%s", SkinRarityName(s.rarity)]
                                                               rarity:s.rarity
                                                             selected:applied];
                    row.frame = CGRectMake(10, sy, colW - 20, 26);
                    int idx = k;
                    row.onTap = ^{
                        gSkinIndex = idx;
                        SkinSelectCurrent();
                        if (!gSkinChangerEnabled.load()) {
                            gSkinChangerEnabled = true;
                            [ConfigManager save];
                        }
                        SkinApply();
                        [weakSelf buildContent];
                    };
                    [gSkins addSubview:row];
                    sy += 28;
                }
            }
        } else if (_currentTab == 8) {
            NLGroupBox *gCfg = [[NLGroupBox alloc] initWithTitle:@"Config Slots" frame:CGRectMake(0, 0, colW, 240)];
            [c1 addSubview:gCfg];
            CGFloat cy = 30;
            for (int i = 0; i < 5; i++) {
                int slot = i;
                NLConfigRow *row = [[NLConfigRow alloc] initWithTitle:[NSString stringWithFormat:@"Slot %d", i + 1]
                                                                    y:cy
                                                               onSave:^{
                    ConfigSaveSlot(slot);
                    [weakSelf buildContent];
                }
                                                               onLoad:^{
                    ConfigLoadSlot(slot);
                    [weakSelf buildContent];
                }
                                                             onDelete:^{
                    ConfigDeleteSlot(slot);
                    [weakSelf buildContent];
                }];
                [gCfg addSubview:row];
                cy += 30;
            }
            
            NLGroupBox *gCfgInfo = [[NLGroupBox alloc] initWithTitle:@"Info" frame:CGRectMake(0, 0, colW, 120)];
            [c2 addSubview:gCfgInfo];
            CGFloat iy = 30;
            UILabel *info = [[UILabel alloc] initWithFrame:CGRectMake(15, iy, colW - 30, 60)];
            info.text = @"Slots snapshot every setting, including menu style and colors. Load restores the whole config.";
            info.textColor = NLTextDim();
            info.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
            info.numberOfLines = 0;
            [gCfgInfo addSubview:info];
            iy += 70;
            
            NLButton *bResetAll = [[NLButton alloc] initWithTitle:@"Reset All"];
            bResetAll.onTap = ^{
                NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
                NSDictionary *all = [d dictionaryRepresentation];
                for (NSString *k in all) {
                    if ([k hasPrefix:@"cfg_slot_"]) {
                        continue;
                    }
                    [d removeObjectForKey:k];
                }
                [d synchronize];
                [ConfigManager load];
                [weakSelf buildContent];
            };
            [gCfgInfo addSubview:[[NLRow alloc] initWithTitle:@"Defaults" y:iy control:bResetAll swatch:nil]];
            iy += 30;
            
            NLGroupBox *gAbout = [[NLGroupBox alloc] initWithTitle:@"About" frame:CGRectMake(0, 130, colW, 150)];
            [c2 addSubview:gAbout];
            CGFloat ay = 30;
            
            UILabel *about = [[UILabel alloc] initWithFrame:CGRectMake(15, ay, colW - 30, 50)];
            about.text = @"FlopDLC v136.3\nNeverlose-inspired UI, no affiliation.";
            about.textColor = NLTextDim();
            about.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
            about.numberOfLines = 0;
            [gAbout addSubview:about];
            ay += 60;
            
            UILabel *credits = [[UILabel alloc] initWithFrame:CGRectMake(15, ay, colW - 30, 30)];
            credits.text = @"UI: sidebar, cards, pill toggles, snow.";
            credits.textColor = NLTextDim();
            credits.font = [UIFont systemFontOfSize:9 weight:UIFontWeightMedium];
            credits.numberOfLines = 0;
            [gAbout addSubview:credits];
            ay += 40;
            
            NLButton *bCopy = [[NLButton alloc] initWithTitle:@"Copy"];
            bCopy.onTap = ^{
                UIPasteboard *pb = [UIPasteboard generalPasteboard];
                pb.string = @"FlopDLC v136.3";
            };
            [gAbout addSubview:[[NLRow alloc] initWithTitle:@"Version" y:ay control:bCopy swatch:nil]];
            ay += 30;
        } else if (_currentTab == 1) {
            // ======================= RAGE =======================
            // Column 1: target selection, aim, trigger.
            // Column 2: anti-aim, per-target bookkeeping, diagnostics.
            NLGroupBox *gCore = [[NLGroupBox alloc] initWithTitle:@"Rage Core" frame:CGRectMake(0, 0, colW, 470)];
            [c1 addSubview:gCore];
            CGFloat y = 30;

            NLCheckbox *cbRE = RageMakeCheckbox(gRageEnabled, ^(BOOL v) {
                gRageEnabled = v;
                [ConfigManager save];
            });
            [gCore addSubview:[[NLRow alloc] initWithTitle:@"Enable Rage" y:y control:cbRE swatch:nil]];
            y += 30;

            NLCheckbox *cbAA = RageMakeCheckbox(gRageAutoAim, ^(BOOL v) {
                gRageAutoAim = v;
                [ConfigManager save];
            });
            [gCore addSubview:[[NLRow alloc] initWithTitle:@"Auto Aim" y:y control:cbAA swatch:nil]];
            y += 30;

            NLCheckbox *cbAF = RageMakeCheckbox(gRageAutoFire, ^(BOOL v) {
                gRageAutoFire = v;
                [ConfigManager save];
            });
            [gCore addSubview:[[NLRow alloc] initWithTitle:@"Auto Fire" y:y control:cbAF swatch:nil]];
            y += 30;

            NLCheckbox *cbOK = RageMakeCheckbox(gRageOnKey, ^(BOOL v) {
                gRageOnKey = v;
                [ConfigManager save];
            });
            [gCore addSubview:[[NLRow alloc] initWithTitle:@"Only On Hotkey" y:y control:cbOK swatch:nil]];
            y += 30;

            NLCheckbox *cbVO = RageMakeCheckbox(gRageVisibleOnly, ^(BOOL v) {
                gRageVisibleOnly = v;
                [ConfigManager save];
            });
            [gCore addSubview:[[NLRow alloc] initWithTitle:@"Visible Only" y:y control:cbVO swatch:nil]];
            y += 30;

            NLCheckbox *cbTC = RageMakeCheckbox(gRageTeamCheck, ^(BOOL v) {
                gRageTeamCheck = v;
                [ConfigManager save];
            });
            [gCore addSubview:[[NLRow alloc] initWithTitle:@"Skip Team" y:y control:cbTC swatch:nil]];
            y += 30;

            NLButton *bPri = RageMakeCycle(@"Distance", (@[@"Distance", @"Lowest HP", @"Crosshair", @"Threat"]),
                                           gRagePriority, ^(NSInteger idx) {
                gRagePriority = (int)idx;
                [ConfigManager save];
            });
            [gCore addSubview:[[NLRow alloc] initWithTitle:@"Priority" y:y control:bPri swatch:nil]];
            y += 30;

            NLButton *bPt = RageMakeCycle(@"Head", (@[@"Head", @"Chest", @"Pelvis", @"Nearest"]),
                                          gRagePoint, ^(NSInteger idx) {
                gRagePoint = (int)idx;
                [ConfigManager save];
            });
            [gCore addSubview:[[NLRow alloc] initWithTitle:@"Aim Point" y:y control:bPt swatch:nil]];
            y += 30;

            NLCheckbox *cbFB = RageMakeCheckbox(gRageForceBaim, ^(BOOL v) {
                gRageForceBaim = v;
                [ConfigManager save];
            });
            [gCore addSubview:[[NLRow alloc] initWithTitle:@"Force Chest" y:y control:cbFB swatch:nil]];
            y += 30;

            NLSlider *sFov = RageMakeSlider(gRageFovPx, 50.0f, 1200.0f, @"px", ^(float v) {
                gRageFovPx = v;
            }, ^(float v) {
                gRageFovPx = v;
                [ConfigManager save];
            });
            [gCore addSubview:[[NLRow alloc] initWithTitle:@"Aim Cone" y:y control:sFov swatch:nil]];
            y += 30;

            NLSlider *sSm = RageMakeSlider(gRageSmooth, 0.0f, 0.98f, @"", ^(float v) {
                gRageSmooth = v;
            }, ^(float v) {
                gRageSmooth = v;
                [ConfigManager save];
            });
            [gCore addSubview:[[NLRow alloc] initWithTitle:@"Smoothing" y:y control:sSm swatch:nil]];
            y += 30;

            NLSlider *sStp = RageMakeSlider(gRageAimStep, 0.0f, 32.0f, @"", ^(float v) {
                gRageAimStep = v;
            }, ^(float v) {
                gRageAimStep = v;
                [ConfigManager save];
            });
            [gCore addSubview:[[NLRow alloc] initWithTitle:@"Aim Step" y:y control:sStp swatch:nil]];
            y += 30;

            NLSlider *sSwd = RageMakeSlider(gRageSwitchDelay, 0.0f, 1000.0f, @"ms", ^(float v) {
                gRageSwitchDelay = v;
            }, ^(float v) {
                gRageSwitchDelay = v;
                [ConfigManager save];
            });
            [gCore addSubview:[[NLRow alloc] initWithTitle:@"Switch Delay" y:y control:sSwd swatch:nil]];
            y += 30;

            NLSlider *sMr = RageMakeSlider(gRageMaxRange, 10.0f, 600.0f, @"m", ^(float v) {
                gRageMaxRange = v;
            }, ^(float v) {
                gRageMaxRange = v;
                [ConfigManager save];
            });
            [gCore addSubview:[[NLRow alloc] initWithTitle:@"Max Range" y:y control:sMr swatch:nil]];
            y += 30;

            NLGroupBox *gTrig = [[NLGroupBox alloc] initWithTitle:@"Trigger" frame:CGRectMake(0, 0, colW, 290)];
            [c2 addSubview:gTrig];
            CGFloat ty = 30;

            NLSlider *sFd = RageMakeSlider(gRageFireDelay, 0.0f, 500.0f, @"ms", ^(float v) {
                gRageFireDelay = v;
            }, ^(float v) {
                gRageFireDelay = v;
                [ConfigManager save];
            });
            [gTrig addSubview:[[NLRow alloc] initWithTitle:@"Fire Delay" y:ty control:sFd swatch:nil]];
            ty += 30;

            NLSlider *sSla = RageMakeSlider(gRageSlowAim, 0.0f, 400.0f, @"ms", ^(float v) {
                gRageSlowAim = v;
            }, ^(float v) {
                gRageSlowAim = v;
                [ConfigManager save];
            });
            [gTrig addSubview:[[NLRow alloc] initWithTitle:@"Slow Aim" y:ty control:sSla swatch:nil]];
            ty += 30;

            NLSlider *sHc = RageMakeSlider(gRageHitchance, 0.0f, 100.0f, @"%", ^(float v) {
                gRageHitchance = (int)v;
            }, ^(float v) {
                gRageHitchance = (int)v;
                [ConfigManager save];
            });
            [gTrig addSubview:[[NLRow alloc] initWithTitle:@"Min Hitchance" y:ty control:sHc swatch:nil]];
            ty += 30;

            NLSlider *sDmg = RageMakeSlider(gRageMinDamage, 1.0f, 200.0f, @"", ^(float v) {
                gRageMinDamage = (int)v;
            }, ^(float v) {
                gRageMinDamage = (int)v;
                [ConfigManager save];
            });
            [gTrig addSubview:[[NLRow alloc] initWithTitle:@"Min Damage" y:ty control:sDmg swatch:nil]];
            ty += 30;

            NLCheckbox *cbBst = RageMakeCheckbox(gRageBurst, ^(BOOL v) {
                gRageBurst = v;
                [ConfigManager save];
            });
            [gTrig addSubview:[[NLRow alloc] initWithTitle:@"Burst Fire" y:ty control:cbBst swatch:nil]];
            ty += 30;

            NLSlider *sBc = RageMakeSlider(gRageBurstCount, 1.0f, 10.0f, @"", ^(float v) {
                gRageBurstCount = (int)v;
            }, ^(float v) {
                gRageBurstCount = (int)v;
                [ConfigManager save];
            });
            [gTrig addSubview:[[NLRow alloc] initWithTitle:@"Burst Rounds" y:ty control:sBc swatch:nil]];
            ty += 30;

            NLSlider *sBp = RageMakeSlider(gRageBurstPause, 0.0f, 2000.0f, @"ms", ^(float v) {
                gRageBurstPause = (int)v;
            }, ^(float v) {
                gRageBurstPause = (int)v;
                [ConfigManager save];
            });
            [gTrig addSubview:[[NLRow alloc] initWithTitle:@"Burst Pause" y:ty control:sBp swatch:nil]];
            ty += 30;

            NLCheckbox *cbAst = RageMakeCheckbox(gRageAutoStop, ^(BOOL v) {
                gRageAutoStop = v;
                [ConfigManager save];
            });
            [gTrig addSubview:[[NLRow alloc] initWithTitle:@"Stop When Dry" y:ty control:cbAst swatch:nil]];
            ty += 30;

            NLCheckbox *cbAir = RageMakeCheckbox(gRageAirStuck, ^(BOOL v) {
                gRageAirStuck = v;
                [ConfigManager save];
            });
            [gTrig addSubview:[[NLRow alloc] initWithTitle:@"Only While Grounded" y:ty control:cbAir swatch:nil]];
            ty += 30;

            NLGroupBox *gWeap = [[NLGroupBox alloc] initWithTitle:@"Weapon" frame:CGRectMake(0, 300, colW, 240)];
            [c2 addSubview:gWeap];
            CGFloat wy = 30;

            NLCheckbox *cbSc = RageMakeCheckbox(gRageAutoScope, ^(BOOL v) {
                gRageAutoScope = v;
                [ConfigManager save];
            });
            [gWeap addSubview:[[NLRow alloc] initWithTitle:@"Auto Scope" y:wy control:cbSc swatch:nil]];
            wy += 30;

            NLCheckbox *cbRl = RageMakeCheckbox(gRageAutoReload, ^(BOOL v) {
                gRageAutoReload = v;
                [ConfigManager save];
            });
            [gWeap addSubview:[[NLRow alloc] initWithTitle:@"Auto Reload" y:wy control:cbRl swatch:nil]];
            wy += 30;

            NLCheckbox *cbAp = RageMakeCheckbox(gRageAutoPistol, ^(BOOL v) {
                gRageAutoPistol = v;
                [ConfigManager save];
            });
            [gWeap addSubview:[[NLRow alloc] initWithTitle:@"Auto Sidearm" y:wy control:cbAp swatch:nil]];
            wy += 30;

            NLCheckbox *cbZ = RageMakeCheckbox(gRageAutoZeus, ^(BOOL v) {
                gRageAutoZeus = v;
                [ConfigManager save];
            });
            [gWeap addSubview:[[NLRow alloc] initWithTitle:@"Melee Reach Guard" y:wy control:cbZ swatch:nil]];
            wy += 30;

            NLButton *bReload = [[NLButton alloc] initWithTitle:@"Reload Now"];
            bReload.onTap = ^{
                TriggerRageReload();
            };
            [gWeap addSubview:[[NLRow alloc] initWithTitle:@"Manual" y:wy control:bReload swatch:nil]];
            wy += 30;

            NLButton *bSwap = [[NLButton alloc] initWithTitle:@"Swap To Slot 2"];
            bSwap.onTap = ^{
                TriggerRageSwitchWeapon(1);
            };
            [gWeap addSubview:[[NLRow alloc] initWithTitle:@"" y:wy control:bSwap swatch:nil]];
            wy += 30;

            NLGroupBox *gAA = [[NLGroupBox alloc] initWithTitle:@"Anti-Aim" frame:CGRectMake(0, 560, colW, 260)];
            [c2 addSubview:gAA];
            CGFloat ay = 30;

            NLCheckbox *cbAAn = RageMakeCheckbox(gRageAntiAim, ^(BOOL v) {
                gRageAntiAim = v;
                [ConfigManager save];
            });
            [gAA addSubview:[[NLRow alloc] initWithTitle:@"Enable" y:ay control:cbAAn swatch:nil]];
            ay += 30;

            NLButton *bAam = RageMakeCycle(@"Static", (@[@"Static", @"Spin", @"Jitter", @"Sway"]),
                                           gRageAntiAimMode, ^(NSInteger idx) {
                gRageAntiAimMode = (int)idx;
                [ConfigManager save];
            });
            [gAA addSubview:[[NLRow alloc] initWithTitle:@"Mode" y:ay control:bAam swatch:nil]];
            ay += 30;

            NLSlider *sAay = RageMakeSlider(gRageAntiAimYaw, -180.0f, 180.0f, @"", ^(float v) {
                gRageAntiAimYaw = v;
            }, ^(float v) {
                gRageAntiAimYaw = v;
                [ConfigManager save];
            });
            [gAA addSubview:[[NLRow alloc] initWithTitle:@"Yaw Offset" y:ay control:sAay swatch:nil]];
            ay += 30;

            NLSlider *sAap = RageMakeSlider(gRageAntiAimPitch, -89.0f, 89.0f, @"", ^(float v) {
                gRageAntiAimPitch = v;
            }, ^(float v) {
                gRageAntiAimPitch = v;
                [ConfigManager save];
            });
            [gAA addSubview:[[NLRow alloc] initWithTitle:@"Pitch Offset" y:ay control:sAap swatch:nil]];
            ay += 30;

            NLSlider *sAas = RageMakeSlider(gRageAntiAimSpin, 0.0f, 2000.0f, @"", ^(float v) {
                gRageAntiAimSpin = v;
            }, ^(float v) {
                gRageAntiAimSpin = v;
                [ConfigManager save];
            });
            [gAA addSubview:[[NLRow alloc] initWithTitle:@"Spin Speed" y:ay control:sAas swatch:nil]];
            ay += 30;

            NLCheckbox *cbAaj = RageMakeCheckbox(gRageAntiAimJitter, ^(BOOL v) {
                gRageAntiAimJitter = v;
                [ConfigManager save];
            });
            [gAA addSubview:[[NLRow alloc] initWithTitle:@"Jitter" y:ay control:cbAaj swatch:nil]];
            ay += 30;

            NLGroupBox *gMisc = [[NLGroupBox alloc] initWithTitle:@"Utility" frame:CGRectMake(0, 830, colW, 150)];
            [c2 addSubview:gMisc];
            CGFloat my = 30;

            NLCheckbox *cbSmoke = RageMakeCheckbox(gRageBypassSmoke, ^(BOOL v) {
                gRageBypassSmoke = v;
                [ConfigManager save];
            });
            [gMisc addSubview:[[NLRow alloc] initWithTitle:@"Bypass Smoke (25m)" y:my control:cbSmoke swatch:nil]];
            my += 30;

            NLCheckbox *cbHbx = RageMakeCheckbox(gRageHitboxExpand, ^(BOOL v) {
                gRageHitboxExpand = v;
                [ConfigManager save];
            });
            [gMisc addSubview:[[NLRow alloc] initWithTitle:@"Hitbox Expand" y:my control:cbHbx swatch:nil]];
            my += 30;

            NLSlider *sHbx = RageMakeSlider(gRageHitboxExpandPx, 0.0f, 40.0f, @"px", ^(float v) {
                gRageHitboxExpandPx = v;
            }, ^(float v) {
                gRageHitboxExpandPx = v;
                [ConfigManager save];
            });
            [gMisc addSubview:[[NLRow alloc] initWithTitle:@"Expand Amount" y:my control:sHbx swatch:nil]];
            my += 30;

            // Teleport is deliberately not exposed: SceneLevelCharacter.Teleport is a [Server]
            // method, and the client-authority path (NetworkTransform.RpcTeleport) only moves the
            // local transform, so the server would rubber-band the player back. Shipping the
            // toggle would ship a control that cannot work, so the flag stays persisted but hidden.

            NLGroupBox *gDiag = [[NLGroupBox alloc] initWithTitle:@"Diagnostics" frame:CGRectMake(0, 490, colW, 220)];
            [c1 addSubview:gDiag];
            CGFloat dy = 30;

            NLCheckbox *cbPts = RageMakeCheckbox(gRagePerTargetStats, ^(BOOL v) {
                gRagePerTargetStats = v;
                [ConfigManager save];
            });
            [gDiag addSubview:[[NLRow alloc] initWithTitle:@"Per-Target Stats" y:dy control:cbPts swatch:nil]];
            dy += 30;

            NLCheckbox *cbLog = RageMakeCheckbox(gRageLogShots, ^(BOOL v) {
                gRageLogShots = v;
                [ConfigManager save];
            });
            [gDiag addSubview:[[NLRow alloc] initWithTitle:@"Shot Log" y:dy control:cbLog swatch:nil]];
            dy += 30;

            NLSlider *sLogn = RageMakeSlider(gRageLogMax, 4.0f, 64.0f, @"", ^(float v) {
                gRageLogMax = (int)v;
            }, ^(float v) {
                gRageLogMax = (int)v;
                [ConfigManager save];
            });
            [gDiag addSubview:[[NLRow alloc] initWithTitle:@"Log Size" y:dy control:sLogn swatch:nil]];
            dy += 30;

            NLCheckbox *cbItf = RageMakeCheckbox(gRageIgnoreTeammatesInFov, ^(BOOL v) {
                gRageIgnoreTeammatesInFov = v;
                [ConfigManager save];
            });
            [gDiag addSubview:[[NLRow alloc] initWithTitle:@"Ignore Mates In Cone" y:dy control:cbItf swatch:nil]];
            dy += 30;

            NLCheckbox *cbDbg = RageMakeCheckbox(gRageDebug, ^(BOOL v) {
                gRageDebug = v;
                [ConfigManager save];
            });
            [gDiag addSubview:[[NLRow alloc] initWithTitle:@"Verbose Log" y:dy control:cbDbg swatch:nil]];
            dy += 30;

            NLButton *bClear = [[NLButton alloc] initWithTitle:@"Clear Target Stats"];
            bClear.onTap = ^{
                gRageStats.clear();
                gRageLog.clear();
                gRageShotSerial = 0;
                gRageHitSerial = 0;
                gRageLastHitSerial = 0;
                gRageLastFireMs = 0;
            };
            [gDiag addSubview:[[NLRow alloc] initWithTitle:@"Reset" y:dy control:bClear swatch:nil]];
            dy += 30;
        }
    } @catch (NSException* e) {
    }
}

- (void)togglePlayerChamsMenu:(UIButton*)sender {
    UIView *parent = sender.superview;
    UIView *sub = [parent viewWithTag:200];
    if (!sub) {
        return;
    }
    
    sub.hidden = !sub.hidden;
    [sender setTitle:(sub.hidden ? @"^" : @"v") forState:UIControlStateNormal];
}

- (void)toggleWeaponChamsMenu:(UIButton*)sender {
    UIView *parent = sender.superview;
    UIView *sub = [parent viewWithTag:201];
    if (!sub) {
        return;
    }
    
    sub.hidden = !sub.hidden;
    [sender setTitle:(sub.hidden ? @"^" : @"v") forState:UIControlStateNormal];
}

- (void)selectPlayerChamsMat:(UIButton*)sender {
    int idx = (int)sender.tag - 1000;
    if (idx < 0 || idx > 2) {
        return;
    }
    
    gChamsPlayerMatType = idx;
    [ConfigManager save];
    
    UIView *sub = sender.superview;
    for (UIView *v in sub.subviews) {
        if ([v isKindOfClass:[UIButton class]]) {
            UIButton *b = (UIButton*)v;
            int bidx = (int)b.tag - 1000;
            b.backgroundColor = (bidx == idx) ? [UIColor colorWithWhite:0.4 alpha:1.0] : [UIColor colorWithWhite:0.15 alpha:1.0];
        }
    }
    
    UIView *par = sub.superview;
    UIButton *chev = (UIButton*)[par viewWithTag:100];
    if (chev) {
        [chev setTitle:@"^" forState:UIControlStateNormal];
    }
    sub.hidden = YES;
}

- (void)selectWeaponChamsMat:(UIButton*)sender {
    int idx = (int)sender.tag - 1010;
    if (idx < 0 || idx > 2) {
        return;
    }
    
    gChamsWeaponMatType = idx;
    [ConfigManager save];
    
    UIView *sub = sender.superview;
    for (UIView *v in sub.subviews) {
        if ([v isKindOfClass:[UIButton class]]) {
            UIButton *b = (UIButton*)v;
            int bidx = (int)b.tag - 1010;
            b.backgroundColor = (bidx == idx) ? [UIColor colorWithWhite:0.4 alpha:1.0] : [UIColor colorWithWhite:0.15 alpha:1.0];
        }
    }
    
    UIView *par = sub.superview;
    UIButton *chev = (UIButton*)[par viewWithTag:101];
    if (chev) {
        [chev setTitle:@"^" forState:UIControlStateNormal];
    }
    sub.hidden = YES;
}

- (void)skyPresetTap:(UIButton*)sender {
    static const uint32_t kPresets[] = {0xFF8C42FF, 0x101828FF, 0xE040FBFF, 0x7B2FBEFF, 0x4A90D9FF};
    int idx = (int)sender.tag - 2000;
    if (idx < 0 || idx > 4) {
        return;
    }
    
    gSkyboxColorHex = kPresets[idx];
    gSkyboxEnabled = true;
    gSkyboxDirty = true;
    [ConfigManager save];
}

- (void)panAction:(UIPanGestureRecognizer*)p {
    CGPoint translation = [p translationInView:self.superview];
    self.center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
    [p setTranslation:CGPointZero inView:self.superview];
}

- (void)minimizeAction {
    _isMinimized = !_isMinimized;
    
    [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.5 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        if (self->_isMinimized) {
            self.frame = CGRectMake(self.frame.origin.x, self.frame.origin.y, self->_origFrame.size.width, 35);
            self->_content.hidden = YES;
        } else {
            self.frame = self->_origFrame;
            self->_content.hidden = NO;
        }
    } completion:nil];
}

- (void)closeAction {
    gMenuOpen = false;
    
    [UIView animateWithDuration:0.25 animations:^{
        self.transform = CGAffineTransformMakeScale(0.95, 0.95);
        self.alpha = 0.0;
    } completion:^(BOOL finished) {
        self.hidden = YES;
        self.transform = CGAffineTransformIdentity;
        self.alpha = 1.0;
        gHotZone.hidden = NO;
        gEspView.hidden = NO;
        RefreshHotkeyView();
        gHotkeyView.hidden = gStreamMode;
        if (!gStreamMode) {
            gWatermark.hidden = NO;
        }
    }];
}

@end

// WORLD VIEW
static void SetVolParam(void* param, float v) {
    if (!SANE_PTR(param) || !alive(param) || !p_runtime_invoke) {
        return;
    }
    
    void* k = *(void**)param;
    void* mi = (k == gClampedFCls) ? p_cfaValMI : (k == gMinFCls) ? p_mfaValMI : (k == gFloatPCls) ? p_fpaValMI : nullptr;
    if (!mi) {
        return;
    }
    
    float val = v;
    void* args[1] = { &val };
    void* exc = nullptr;
    p_runtime_invoke(mi, param, args, &exc);
    
    if (!exc) {
        *(bool*)((uintptr_t)param + 0x10) = true; // m_OverrideState
    }
}

static void ForEachVolumeComponent(void* wantCls, void (*fn)(void*, void*), void* ctx) {
    if (!wantCls || !fn || !gVolumeTypeHandle || !p_runtime_invoke || !p_gchandle_get_target) {
        return;
    }
    
    void* to = p_gchandle_get_target(gVolumeTypeHandle);
    if (!SANE_PTR(to)) {
        return;
    }
    
    void* a[1] = {to};
    void* exc = nullptr;
    void* arr = p_runtime_invoke(p_findPlayerMI, nullptr, a, &exc);
    if (exc || !SANE_PTR(arr)) {
        return;
    }
    
    int len = *(int*)((uintptr_t)arr + 0x18);
    for (int i = 0; i < len && i < 64; i++) {
        void* v = *(void**)((uintptr_t)arr + 0x20 + i*8);
        if (!alive(v)) {
            continue;
        }
        
        void* profile = *(void**)((uintptr_t)v + 0x30); // sharedProfile
        if (!alive(profile)) {
            profile = *(void**)((uintptr_t)v + 0x48); // m_InternalProfile
        }
        if (!alive(profile)) {
            continue;
        }
        
        void* list = *(void**)((uintptr_t)profile + 0x18); // components
        if (!SANE_PTR(list)) {
            continue;
        }
        
        void* items = *(void**)((uintptr_t)list + 0x10); // _items
        if (!SANE_PTR(items)) {
            continue;
        }
        
        int n = *(int*)((uintptr_t)items + 0x18); // _size
        for (int j = 0; j < n && j < 32; j++) {
            void* comp = *(void**)((uintptr_t)items + 0x20 + j*8);
            if (alive(comp) && *(void**)comp == wantCls) {
                fn(comp, ctx);
            }
        }
    }
}

static void ApplyGradingToComponent(void* comp, void* ctx) {
    SetVolParam(*(void**)((uintptr_t)comp + 0x58), gSaturationVal.load()); // saturation
    SetVolParam(*(void**)((uintptr_t)comp + 0x40), gContrastVal.load());   // contrast
    SetVolParam(*(void**)((uintptr_t)comp + 0x38), gGammaVal.load());      // postExposure (EV100)
}

static void ApplyBloomToComponent(void* comp, void* ctx) {
    SetVolParam(*(void**)((uintptr_t)comp + 0x48), gBloomVal.load()); // intensity
}

static void ApplyMotionBlurToComponent(void* comp, void* ctx) {
    bool on = gMotionBlurEnabled.load();
    float amount = on ? gMotionBlurAmount.load() : 0.0f;
    SetVolParam(*(void**)((uintptr_t)comp + 0x48), amount); // intensity
    SetVolParam(*(void**)((uintptr_t)comp + 0x50), 0.05f);  // clamp
}

static void ApplyFpsLimit(void) {
    if (!gSetTargetFrameRateMI || !p_runtime_invoke) {
        return;
    }
    int v = gFpsLimit.load();
    // Application.set_targetFrameRate is a Unity API and must run on the main thread;
    // bootstrap() runs on a background queue, so hop over before invoking.
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            void* args[1] = { (void*)&v };
            void* exc = nullptr;
            p_runtime_invoke(gSetTargetFrameRateMI, nullptr, args, &exc);
        } @catch (NSException* e) {
        }
    });
}

static void ApplyWorldView(void) {
    @try {
        bool fb = gFullbrightEnabled.load();
        bool amb = gAmbientTintEnabled.load();
        bool needLights = fb || amb || s_fbWas || s_ambWas;
        
        if (needLights && gLightTypeHandle && p_lightGetIntensity && p_lightSetIntensity && p_lightGetColor && p_lightSetColor) {
            void* to = p_gchandle_get_target(gLightTypeHandle);
            if (SANE_PTR(to)) {
                void* a[1] = {to};
                void* exc = nullptr;
                void* arr = p_runtime_invoke(p_findPlayerMI, nullptr, a, &exc);
                if (!exc && SANE_PTR(arr)) {
                    int len = *(int*)((uintptr_t)arr + 0x18);
                    float mul = gFullbrightMul.load();
                    uint32_t hex = gAmbientColorHex.load();
                    UnityColor tc(((hex >> 24) & 0xFF) / 255.0f, ((hex >> 16) & 0xFF) / 255.0f, ((hex >> 8) & 0xFF) / 255.0f, 1.0f);
                    
                    for (int i = 0; i < len && i < 128; i++) {
                        void* l = *(void**)((uintptr_t)arr + 0x20 + i*8);
                        if (!alive(l)) {
                            continue;
                        }
                        
                        auto it = gLightOrig.find(l);
                        if (it == gLightOrig.end()) {
                            SavedLight sl;
                            sl.i = p_lightGetIntensity(l, p_lightGetIntensityMI);
                            sl.c = p_lightGetColor(l, p_lightGetColorMI);
                            gLightOrig[l] = sl;
                            it = gLightOrig.find(l);
                        }
                        
                        float wantI = it->second.i;
                        UnityColor wantC = it->second.c;
                        if (fb) {
                            wantI = it->second.i * mul;
                        }
                        if (amb) {
                            wantC = tc;
                        }
                        
                        float curI = p_lightGetIntensity(l, p_lightGetIntensityMI);
                        if (std::isfinite(wantI) && std::isfinite(curI) && fabsf(curI - wantI) > 0.05f) {
                            p_lightSetIntensity(l, wantI, p_lightSetIntensityMI);
                        }
                        
                        UnityColor curC = p_lightGetColor(l, p_lightGetColorMI);
                        if (fabsf(curC.r - wantC.r) > 0.02f || fabsf(curC.g - wantC.g) > 0.02f || fabsf(curC.b - wantC.b) > 0.02f) {
                            p_lightSetColor(l, wantC, p_lightSetColorMI);
                        }
                    }
                }
            }
        }
        s_fbWas = fb;
        s_ambWas = amb;
        
        if (!fb && !amb && !s_fbWas && !s_ambWas && p_renderSetAmbientLight && s_origAmbientInit) {
            p_renderSetAmbientLight(gSkyboxCls, s_origAmbient, p_renderGetAmbientLightMI);
        }
        
        bool nf = gNoFogEnabled.load();
        if (nf != s_nfWas && p_setFogMI && p_getFogMI) {
            if (!s_fogOrigInit) {
                s_fogOrig = p_getFog(p_getFogMI);
                s_fogOrigInit = true;
            }
            p_setFog(nf ? false : s_fogOrig, p_setFogMI);
            s_nfWas = nf;
        }
        
        if (amb && p_renderSetAmbientLight) {
            if (!s_origAmbientInit && p_renderGetAmbientLight) {
                s_origAmbient = p_renderGetAmbientLight(gSkyboxCls);
                s_origAmbientInit = true;
            }
            uint32_t hex = gAmbientColorHex.load();
            UnityColor tc(((hex >> 24) & 0xFF) / 255.0f, ((hex >> 16) & 0xFF) / 255.0f, ((hex >> 8) & 0xFF) / 255.0f, 1.0f);
            p_renderSetAmbientLight(gSkyboxCls, tc, p_renderGetAmbientLightMI);
        } else if (fb && p_renderSetAmbientLight) {
            if (!s_origAmbientInit && p_renderGetAmbientLight) {
                s_origAmbient = p_renderGetAmbientLight(gSkyboxCls);
                s_origAmbientInit = true;
            }
            UnityColor tc(1.0f, 1.0f, 1.0f, 1.0f);
            p_renderSetAmbientLight(gSkyboxCls, tc, p_renderGetAmbientLightMI);
        } else if (!amb && !fb && s_origAmbientInit && p_renderSetAmbientLight) {
            p_renderSetAmbientLight(gSkyboxCls, s_origAmbient, p_renderGetAmbientLightMI);
        }
        
        if (gGradingDirty.load()) {
            gGradingDirty = false;
            ForEachVolumeComponent(gColorAdjCls, ApplyGradingToComponent, nullptr);
            ForEachVolumeComponent(gBloomCls, ApplyBloomToComponent, nullptr);
            ForEachVolumeComponent(gMotionBlurCls, ApplyMotionBlurToComponent, nullptr);
        }
        
        float sharp = gSharpenVal.load();
        if (sharp > 0.01f && SANE_PTR(g_localCamera) && alive(g_localCamera) && gCamDataCls && gCamDataTypeHandle && p_getCompsInChildrenMI) {
            void* go = p_getGameObject ? p_getGameObject(g_localCamera, p_getGameObjectMI) : nullptr;
            if (alive(go)) {
                void* to = p_gchandle_get_target(gCamDataTypeHandle);
                if (SANE_PTR(to)) {
                    bool incInactive = false;
                    void* args[2] = { to, &incInactive };
                    void* exc = nullptr;
                    void* rArr = p_runtime_invoke(p_getCompsInChildrenMI, go, args, &exc);
                    if (!exc && SANE_PTR(rArr)) {
                        int n = *(int*)((uintptr_t)rArr + 0x18);
                        if (n > 0) {
                            void* cd = *(void**)((uintptr_t)rArr + 0x20);
                            if (alive(cd)) {
                                if (*(int*)((uintptr_t)cd + 0x50) == 0) { // m_Antialiasing: None -> TAA
                                    *(int*)((uintptr_t)cd + 0x50) = 3;
                                }
                                *(float*)((uintptr_t)cd + 0xB4) = sharp; // m_TaaSettings.m_ContrastAdaptiveSharpening
                            }
                        }
                    }
                }
            }
        }
    } @catch (NSException* e) {
    }
}

static void ApplyNightMode(void) {
    @try {
        if (!p_findVolumeMI || !gVolumeTypeHandle) {
            return;
        }
        
        void* to = p_gchandle_get_target(gVolumeTypeHandle);
        if (!to) {
            return;
        }
        
        void* a[1] = {to};
        void* exc = nullptr;
        void* arr = p_runtime_invoke(p_findVolumeMI, nullptr, a, &exc);
        
        if (exc || !arr) {
            return;
        }
        
        int len = *(int*)((uintptr_t)arr + 0x18);
        if (len <= 0) {
            return;
        }
        
        float targetWeight = gNightModeEnabled ? 0.0f : 1.0f;
        
        for (int i = 0; i < len && i < 64; i++) {
            void* v = *(void**)((uintptr_t)arr + 0x20 + i*8);
            if (!alive(v)) {
                continue;
            }
            
            float* w = (float*)((uintptr_t)v + off::kVolumeWeight);
            *w = targetWeight;
        }
    } @catch (NSException* e) {
    }
}

static void espTick(void) {
    @autoreleasepool {
        if (gStreamMode) {
            return;
        }
        uint64_t curTime = MachTicksToNanoseconds(mach_absolute_time());
        if (gLastFrameTime > 0) {
            uint64_t delta = curTime - gLastFrameTime;
            float dt = (float)delta / 1000000000.0f;
            if (std::isfinite(dt) && dt > 0.0f && dt < 1.0f) {
                float instantFps = 1.0f / dt;
                if (std::isfinite(instantFps) && instantFps > 0.0f && instantFps < 1000.0f) {
                    gCurrentFps = gCurrentFps * 0.9f + instantFps * 0.1f;
                }
            }
        }
        gLastFrameTime = curTime;
        
        if (!std::isfinite(gCurrentFps) || gCurrentFps <= 0.0f || gCurrentFps > 1000.0f) {
            gCurrentFps = 60.0f;
        }
        
        if (gWatermark) {
            [gWatermark updateFps:gCurrentFps];
        }
        
        if (!gAttached || !p_runtime_invoke || !p_findPlayerMI) {
            return;
        }
        
        uint64_t tMs = curTime / 1000000ULL;
        if (tMs - gLastNight > 500) {
            gLastNight = tMs;
            ApplyNightMode();
        }
        
        if (tMs - gLastWorld > 500) {
            gLastWorld = tMs;
            ApplyWorldView();
        }
        
        if (tMs - gLastP > 500) {
            gLastP = tMs;
            void* to = p_gchandle_get_target(gPlayerTypeHandle);
            if (to) {
                void* a[1] = {to};
                void* exc = nullptr;
                void* arr = p_runtime_invoke(p_findPlayerMI, nullptr, a, &exc);
                if (!exc && arr) {
                    int len = *(int*)((uintptr_t)arr + 0x18);
                    if (len > 0) {
                        gCached.clear();
                        gLocal = nullptr;
                        gTeam = 0;
                        for (int i = 0; i < len && i < 500; i++) {
                            void* p = *(void**)((uintptr_t)arr + 0x20 + i*8);
                            if (!alive(p)) {
                                continue;
                            }
                            gCached.push_back(p);
                            void* ni = *(void**)((uintptr_t)p + 0x38);
                            if (alive(ni) && *(bool*)((uintptr_t)ni + 0x22)) {
                                gLocal = p;
                                gTeam = *(int*)((uintptr_t)p + off::kPlayerTeam);
                            }
                        }
                        
                        for (auto it = gLastEnemyHealth.begin(); it != gLastEnemyHealth.end(); ) {
                            bool found = false;
                            for (void* q : gCached) {
                                if (q == it->first) {
                                    found = true;
                                    break;
                                }
                            }
                            if (!found) {
                                it = gLastEnemyHealth.erase(it);
                            } else {
                                ++it;
                            }
                        }
                    }
                }
            }
        }
        
        if (!alive(gLocal)) {
            return;
        }
        
        void* cam = nullptr;
        void* slc = nullptr;
        void* lcLocal = nullptr;
        void* lch = *(void**)((uintptr_t)gLocal + off::kPlayerCharacter);
        g_localChar = lch;
        
        if (alive(lch)) {
            lcLocal = *(void**)((uintptr_t)lch + off::kCharController);
            if (alive(lcLocal)) {
                slc = *(void**)((uintptr_t)lcLocal + off::kLocalCamera);
                if (alive(slc)) {
                    cam = *(void**)((uintptr_t)slc + off::kCamComponent);
                }
            }
        }
        
        if (!alive(cam)) {
            return;
        }
        
        g_localSceneChar = slc;
        g_localCamera = cam;
        
        if (alive(lch)) {
            void* ctrl = *(void**)((uintptr_t)lch + off::kCharController);
            if (alive(ctrl)) {
                g_localCC = *(void**)((uintptr_t)ctrl + off::kCtrlCC);
                g_localWeapon = *(void**)((uintptr_t)ctrl + off::kCtrlEquip);
            }
            void* mc = *(void**)((uintptr_t)lch + off::kCharModelContainer);
            if (alive(mc) && p_getTransform) {
                g_localTransform = p_getTransform(mc, p_getTransformMI);
            }
        }
        
        g_localEye = Vec3{0,0,0};
        if (alive(cam) && p_getTransform) {
            g_localCamTransform = p_getTransform(cam, p_getTransformMI);
            if (alive(g_localCamTransform)) {
                getPosFast(g_localCamTransform, g_localEye);
            }
        }
        
        if (gSkyboxDirty && gSkyboxEnabled && p_getSkybox && p_matSetColor && p_string_new) {
            void* skyMat = p_getSkybox(p_getSkyboxMI);
            if (alive(skyMat)) {
                uint32_t hex = gSkyboxColorHex.load();
                float r = ((hex >> 24) & 0xFF) / 255.0f;
                float g = ((hex >> 16) & 0xFF) / 255.0f;
                float b = ((hex >> 8) & 0xFF) / 255.0f;
                float a = (hex & 0xFF) / 255.0f;
                
                UnityColor col(r, g, b, a);
                void* strTint = p_string_new("_Tint");
                void* strColor = p_string_new("_Color");
                void* strBaseColor = p_string_new("_BaseColor");
                void* strSkyColor = p_string_new("_SkyColor");
                
                if (strTint) p_matSetColor(skyMat, strTint, col, p_matSetColorMI);
                if (strColor) p_matSetColor(skyMat, strColor, col, p_matSetColorMI);
                if (strBaseColor) p_matSetColor(skyMat, strBaseColor, col, p_matSetColorMI);
                if (strSkyColor) p_matSetColor(skyMat, strSkyColor, col, p_matSetColorMI);
            }
            gSkyboxDirty = false;
        }
        
        float cw = 0, ch = 0;
        if (p_camGetPixelWidth) cw = (float)p_camGetPixelWidth(cam, p_camGetPixelWidthMI);
        if (p_camGetPixelHeight) ch = (float)p_camGetPixelHeight(cam, p_camGetPixelHeightMI);
        
        float sX = 1.0f, sY = 1.0f;
        if (cw > 0 && ch > 0) {
            sX = (gScreenPts.width * gScreenScale) / cw;
            sY = (gScreenPts.height * gScreenScale) / ch;
        }
        
        [gEspView.boxes removeAllObjects];
        [gEspView.labels removeAllObjects];
        [gEspView.hps removeAllObjects];
        [gEspView.armors removeAllObjects];
        [gEspView.skeletonLines removeAllObjects];
        [gEspView.nameTexts removeAllObjects];
        [gEspView.names removeAllObjects];
        [gEspView.tracers removeAllObjects];
        [gEspView.oofDirs removeAllObjects];
        [gEspView.weaponBoxes removeAllObjects];
        [gEspView.weaponLabels removeAllObjects];
        [gEspView.headDots removeAllObjects];
        [gEspView.snapLines removeAllObjects];
        [gEspView.boxColors removeAllObjects];
        [gEspView.healthTexts removeAllObjects];
        [gEspView.dists removeAllObjects];
        
        HudBeginFrame();
        
        float localYaw = 0.0f;
        if (alive(g_localCamTransform) && p_tfGetEuler) {
            Vec3 le = p_tfGetEuler(g_localCamTransform, p_tfGetEulerMI);
            if (Math::Finite(le)) {
                localYaw = le.y;
            }
        }
        
        void* best = nullptr;
        float bestScore = 99999.0f;
        Vec3 bestAimPos = {0,0,0};
        
        CGFloat screenCx = gScreenPts.width / 2.0f;
        CGFloat screenCy = gScreenPts.height / 2.0f;
        
        uint64_t nowMs = NowMs();
        
        if (alive(g_localWeapon)) {
            int ammo = *(int*)((uintptr_t)g_localWeapon + off::kWepAmmo);
            if (gLastLocalAmmo != -1 && ammo < gLastLocalAmmo) {
                g_lastLocalShotMs = nowMs;
            }
            gLastLocalAmmo = ammo;
            gLocalAmmoVal = ammo;
            gLocalAmmoTotalVal = *(int*)((uintptr_t)g_localWeapon + off::kWepAmmoTotal);
        } else {
            gLastLocalAmmo = -1;
        }

        uint64_t sinceShot = nowMs - g_lastLocalShotMs.load();
        bool recentShot = sinceShot < 500;
        
        for (void* p : gCached) {
            if (!alive(p) || p == gLocal) {
                continue;
            }
            if (*(bool*)((uintptr_t)p + off::kPlayerIsDead)) {
                continue;
            }
            
            int tm = *(int*)((uintptr_t)p + off::kPlayerTeam);
            bool enemyTeam = !(gAimbotNoTeam && tm == gTeam && gTeam >= 0);
            
            void* c = *(void**)((uintptr_t)p + off::kPlayerCharacter);
            if (!alive(c)) {
                continue;
            }
            
            if (gRadarEnabled) {
                void* rmc = *(void**)((uintptr_t)c + off::kCharModelContainer);
                if (alive(rmc)) {
                    Vec3 rfp;
                    if (getPosFast(rmc, rfp)) {
                        float rdx = rfp.x - g_localEye.x;
                        float rdz = rfp.z - g_localEye.z;
                        float yawRad = gRadarRotate ? (-localYaw * Math::DEG2RAD) : 0.0f;
                        float rx = rdx * cosf(yawRad) - rdz * sinf(yawRad);
                        float rz = rdx * sinf(yawRad) + rdz * cosf(yawRad);
                        HudAddRadar(rx, rz, tm, *(bool*)((uintptr_t)p + off::kPlayerIsDead));
                    }
                }
            }
            
            int damageDelta = 0;
            if (enemyTeam) {
                int curH = *(int*)((uintptr_t)c + off::kCharHealth);
                auto it = gLastEnemyHealth.find(p);
                if (it != gLastEnemyHealth.end()) {
                    int prevH = it->second;
                    
                    if (prevH > 0 && curH < prevH && recentShot) {
                        damageDelta = prevH - curH;
                        gHudHitMarkerUntil = nowMs + (uint64_t)gHitMarkerDuration.load();
                        gHudHitMarkerDamage = damageDelta;
                        gStatHits = gStatHits.load() + 1;
                        gStatDamage = gStatDamage.load() + damageDelta;

                        // The rage pipeline reads its hit rate from the same delta the HUD
                        // does, but only when the shot came from the rage trigger: a
                        // teammate's damage on the same player must not inflate it.
                        if (gRageEnabled.load() && alive(p) && p == gRageTarget.load()) {
                            uint64_t sinceRageShot = nowMs - gRageLastFireMs.load();
                            if (sinceRageShot < 2000) {
                                RageNoteHit();
                            }
                        }

                        if (gDamageLogEnabled.load()) {
                            HudAddEvent(SafeFmt(@"HIT %d", damageDelta).UTF8String, 1, nowMs + (uint64_t)gEventLogDuration.load());
                        }
                        
                        if (curH == 0) {
                            if (gKillSoundEnabled) {
                                PlayKillSound();
                            }
                            
                            void* nickObj = *(void**)((uintptr_t)p + off::kPlayerNickName);
                            NSString* nick = getIL2CPPString(nickObj);
                            if (nick && nick.length > 0 && gKillFeedEnabled) {
                                HudAddKill([nick UTF8String], nowMs + 6000);
                            }
                            gStatKills = gStatKills.load() + 1;
                            if (gAimBone.load() == 10) {
                                gStatHeadshots = gStatHeadshots.load() + 1;
                            }
                            if (gEventLogEnabled.load()) {
                                HudAddEvent(SafeFmt(@"KILL %@", nick ?: @"?").UTF8String, 2, nowMs + (uint64_t)gEventLogDuration.load());
                            }
                        } else if (gHitSoundEnabled) {
                            if (nowMs - g_lastHitSoundTime > 100) {
                                g_lastHitSoundTime = nowMs;
                                PlayHitSound();
                            }
                        }
                    }
                }
                gLastEnemyHealth[p] = curH;
            }
            
            if (*(bool*)((uintptr_t)c + off::kCharIsDead)) {
                continue;
            }
            int health = *(int*)((uintptr_t)c + off::kCharHealth);
            if (health <= 0) {
                continue;
            }
            
            if (gAimbotNoTeam && tm == gTeam && gTeam >= 0) {
                continue;
            }
            
            void* mc = *(void**)((uintptr_t)c + off::kCharModelContainer);
            if (!alive(mc)) {
                continue;
            }
            
            Vec3 fp;
            if (!getPosFast(mc, fp)) {
                continue;
            }
            
            Vec3 hpv = fp;
            void* model = nullptr;
            void* ct = *(void**)((uintptr_t)c + off::kCharController);
            
            if (alive(ct)) {
                void* rv = *(void**)((uintptr_t)ct + off::kOtherRemoteVis);
                if (alive(rv)) {
                    model = *(void**)((uintptr_t)rv + off::kRvModel);
                    if (alive(model)) {
                        void* ht = *(void**)((uintptr_t)model + off::kModelHead);
                        if (alive(ht)) {
                            Vec3 h;
                            if (getPosFast(ht, h)) {
                                hpv = h;
                            }
                        }
                    }
                }
            }
            
            if (hpv.y <= fp.y) {
                hpv.y = fp.y + 1.6f;
            }
            
            Vec3 aimPos = hpv;
            if (alive(model) && p_getBoneTransform) {
                void* animator = *(void**)((uintptr_t)model + off::kModelAnimator);
                if (alive(animator)) {
                    int aimBone = gAimBone.load();
                    void* aimTransform = p_getBoneTransform(animator, aimBone, p_getBoneTransformMI);
                    if (alive(aimTransform)) {
                        Vec3 selectedBonePos;
                        if (getPosFast(aimTransform, selectedBonePos) && Math::Finite(selectedBonePos)) {
                            aimPos = selectedBonePos;
                        }
                    }
                }
            }

            float dx = fp.x - g_localEye.x;
            float dy = fp.y - g_localEye.y;
            float dz = fp.z - g_localEye.z;
            float realDist = sqrtf(dx*dx + dy*dy + dz*dz);
            
            if (!std::isfinite(realDist) || realDist > kEspMaxDistanceMeters) {
                continue;
            }
            
            // Velocity prediction: track the last world position per player and lead the
            // aim point by a fraction of the travel distance. Purely local math, no writes.
            if (gPredictionEnabled.load() && gPredictionAmount.load() > 0.0f) {
                auto pit = gLastTargetPos.find(p);
                auto tit = gLastTargetMs.find(p);
                uint64_t pnow = NowMs();
                if (pit != gLastTargetPos.end() && tit != gLastTargetMs.end() && pnow > tit->second) {
                    float dt = (float)(pnow - tit->second) / 1000.0f;
                    if (dt > 0.001f && dt < 0.5f) {
                        Vec3 vel = (aimPos - pit->second) * (1.0f / dt);
                        float lead = gPredictionAmount.load() * (realDist / 100.0f);
                        Vec3 predicted = aimPos + vel * lead;
                        if (Math::Finite(predicted)) {
                            aimPos = predicted;
                        }
                    }
                }
                gLastTargetPos[p] = aimPos;
                gLastTargetMs[p] = pnow;
            }
            
            bool isVisible = true;
            bool needVisCheck = gAimbotVisibleOnly ||
                                gTriggerbotVisibleOnly.load() ||
                                (gVisibleColorEnabled && (gEspEnabled || gHotEspEnabled));
            if (needVisCheck && p_CheckSeen && g_localSceneChar) {
                if (!p_CheckSeen(g_localSceneChar, aimPos, p_checkSeenMI)) {
                    isVisible = false;
                }
            }
            
            bool espOn = (gEspEnabled || gHotEspEnabled);
            bool needScreen = espOn || gTriggerbotEnabled.load() || gPlayerListEnabled.load() ||
                              gInfoPanelEnabled.load() || gStatsPanelEnabled.load();
            bool espVisible = false;
            if (needScreen) {
                Vec3 sf, sh;
                if (w2sFast(cam, fp, sf) && w2sFast(cam, hpv, sh) && sf.z > 0.05f && sh.z > 0.05f) {
                    float xh = (sh.x * sX) / gScreenScale;
                    float yh = gScreenPts.height - ((sh.y * sY) / gScreenScale);
                    float yf = gScreenPts.height - ((sf.y * sY) / gScreenScale);
                    
                    float tp = fminf(yh, yf);
                    float bt2 = fmaxf(yh, yf);
                    float bh = bt2 - tp;
                    float bw = bh * 0.55f;
                    float xx = xh - bw/2;
                    float yy = tp;
                    
                    if (bh > 10 && xx >= -100 && xx <= gScreenPts.width + 100 && yy >= -100 && yy <= gScreenPts.height + 100) {
                        espVisible = true;
                        int hh = *(int*)((uintptr_t)c + off::kCharHealth);
                        int aa = *(int*)((uintptr_t)c + off::kCharArmor);
                        
                        UIColor* boxColor = gBoxColor;
                        if (gTeamColorEnabled) {
                            boxColor = gTeamColor;
                        }
                        if (gVisibleColorEnabled) {
                            boxColor = isVisible ? gVisibleColor : gHiddenColor;
                        }
                        
                        HudPlayerInfo hpi;
                        hpi.box = CGRectMake(xx, yy, bw, bh);
                        hpi.head = CGPointMake(xh, yh);
                        hpi.feet = CGPointMake(xh, yf);
                        hpi.health = hh > 0 ? hh : 0;
                        hpi.armor = aa > 0 ? aa : 0;
                        hpi.team = tm;
                        hpi.visible = isVisible;
                        hpi.distance = realDist;
                        HudAddPlayer(hpi);
                        
                        if (espOn) {
                            [gEspView.boxes addObject:[NSValue valueWithCGRect:CGRectMake(xx, yy, bw, bh)]];
                            [gEspView.labels addObject:SafeFmt(@"%.0fm", realDist)];
                            [gEspView.dists addObject:@(realDist)];
                            [gEspView.hps addObject:@(hh > 0 ? hh : 0)];
                            [gEspView.armors addObject:@(aa > 0 ? aa : 0)];
                            [gEspView.boxColors addObject:(boxColor ?: [UIColor redColor])];
                            [gEspView.headDots addObject:[NSValue valueWithCGPoint:CGPointMake(xh, yh)]];
                            
                            if (gSnapBottomEnabled) {
                                [gEspView.snapLines addObject:[NSValue valueWithCGPoint:CGPointMake(xh, yh)]];
                            }
                            
                            if (gHealthTextEnabled) {
                                [gEspView.healthTexts addObject:SafeFmt(@"%d", hh > 0 ? hh : 0)];
                            }
                            
                            if (gNameEnabled) {
                                void* nickObj = *(void**)((uintptr_t)p + off::kPlayerNickName);
                                NSString* nick = getIL2CPPString(nickObj);
                                if (nick && nick.length > 0) {
                                    int maxLen = gNameMaxLen.load();
                                    if (maxLen > 0 && (int)nick.length > maxLen) {
                                        nick = [nick substringToIndex:(NSUInteger)maxLen];
                                    }
                                    [gEspView.names addObject:nick];
                                    [gEspView.nameTexts addObject:[NSValue valueWithCGPoint:CGPointMake(xx + bw/2, yy - 14)]];
                                }
                            }
                            
                            if (gTracersEnabled) {
                                [gEspView.tracers addObject:[NSValue valueWithCGPoint:CGPointMake(xh, yh)]];
                            }
                            
                            if (gWeaponEspEnabled.load() && alive(model)) {
                                void* wtf = *(void**)((uintptr_t)model + off::kModelWeaponTf);
                                if (alive(wtf)) {
                                    Vec3 wp;
                                    if (getPosFast(wtf, wp)) {
                                        Vec3 sw;
                                        if (w2sFast(cam, wp, sw) && sw.z > 0.05f) {
                                            float wx = (sw.x * sX) / gScreenScale;
                                            float wy = gScreenPts.height - ((sw.y * sY) / gScreenScale);
                                            [gEspView.weaponBoxes addObject:[NSValue valueWithCGRect:CGRectMake(wx - 8.0f, wy - 8.0f, 16.0f, 16.0f)]];
                                            [gEspView.weaponLabels addObject:@"WEP"];
                                        }
                                    }
                                }
                            }
                        }
                        
                        if (damageDelta > 0 && gDamageNumbersEnabled) {
                            HudAddDamage(CGPointMake(xh, yh - 12.0f), damageDelta, nowMs + (uint64_t)gDamageNumberDuration.load());
                        }
                    }
                }
            }
            
            if (gOofEnabled && !espVisible) {
                Vec3 sf;
                if (w2sFast(cam, fp, sf)) {
                    CGFloat sx = (sf.x * sX) / gScreenScale;
                    CGFloat sy = gScreenPts.height - ((sf.y * sY) / gScreenScale);
                    CGFloat ddx = sx - screenCx;
                    CGFloat ddy = sy - screenCy;
                    float len = sqrtf(ddx*ddx + ddy*ddy);
                    if (len > 1) {
                        [gEspView.oofDirs addObject:[NSValue valueWithCGPoint:CGPointMake(ddx/len, ddy/len)]];
                    }
                }
            }
            
            if (gSkeletonEnabled && alive(model)) {
                void* an = *(void**)((uintptr_t)model + off::kModelAnimator);
                if (alive(an) && p_getBoneTransform) {
                    int bn[] = {0,7,8,9,10,11,12,13,14,15,16,17,18,1,2,3,4,5,6};
                    CGPoint sb[19];
                    bool vb[19];
                    
                    for (int i = 0; i < 19; i++) {
                        vb[i] = false;
                        void* bt = p_getBoneTransform(an, bn[i], p_getBoneTransformMI);
                        if (alive(bt)) {
                            Vec3 wp;
                            if (getPosFast(bt, wp)) {
                                Vec3 sp;
                                if (w2sFast(cam, wp, sp) && sp.z > 0.05f) {
                                    sb[i] = CGPointMake((sp.x * sX) / gScreenScale, gScreenPts.height - ((sp.y * sY) / gScreenScale));
                                    vb[i] = true;
                                }
                            }
                        }
                    }
                    
                    int cn[][2] = {{4,3},{3,2},{2,1},{1,0},{1,5},{5,7},{7,9},{9,11},{1,6},{6,8},{8,10},{10,12},{0,13},{13,15},{15,17},{0,14},{14,16},{16,18}};
                    for (int i = 0; i < 18; i++) {
                        int a = cn[i][0];
                        int b = cn[i][1];
                        if (gSkeletonUpperOnly.load() && (a >= 13 || b >= 13)) {
                            continue;
                        }
                        if (vb[a] && vb[b]) {
                            [gEspView.skeletonLines addObject:[NSValue valueWithCGRect:CGRectMake(sb[a].x, sb[a].y, sb[b].x, sb[b].y)]];
                        }
                    }
                }
            }
            
            
            if (gAimbotEnabled || gAimOnFireEnabled || gSilentAimEnabled || gHotAimbotEnabled || gHotAimOnFireEnabled) {
                // Silent aim does not need line of sight; only the visual aimbot does.
                if (gAimbotVisibleOnly && !gSilentAimEnabled && !isVisible) {
                    continue;
                }
                
                Vec3 sa;
                if (w2sFast(cam, aimPos, sa) && sa.z > 0.05f) {
                    float sx = (sa.x * sX) / gScreenScale;
                    float sy = gScreenPts.height - ((sa.y * sY) / gScreenScale);
                    float screenDist = sqrtf((sx - screenCx) * (sx - screenCx) + (sy - screenCy) * (sy - screenCy));
                    
                    float score = screenDist;
                    int prio = gTargetPriority.load();
                    if (prio == 1) {
                        int hp = *(int*)((uintptr_t)c + off::kCharHealth);
                        score = (float)(hp > 0 ? hp : 0);
                    }
                    if (screenDist < (float)gAimbotFovPx && score < bestScore) {
                        bestScore = score;
                        best = c;
                        bestAimPos = aimPos;
                    }
                }
            }
        }
        
        if ((gAimbotEnabled || gAimOnFireEnabled || gSilentAimEnabled || gHotAimbotEnabled || gHotAimOnFireEnabled) && best && alive(slc) && alive(lcLocal)) {
            g_silentAimSeq.fetch_add(1, std::memory_order_release);
            g_silentAimTarget = bestAimPos;
            g_silentAimSeq.fetch_add(1, std::memory_order_release);
            g_silentAimActive = true;
            g_targetHead = bestAimPos;
            g_haveTarget = true;
            g_aimTargetObj = best;
        } else {
            g_silentAimActive = false;
            g_haveTarget = false;
            g_aimTargetObj = nullptr;
        }
        
        if (gAimLineEnabled && g_haveTarget) {
            Vec3 sa;
            if (w2sFast(cam, bestAimPos, sa) && sa.z > 0.05f) {
                CGFloat ax = (sa.x * sX) / gScreenScale;
                CGFloat ay = gScreenPts.height - ((sa.y * sY) / gScreenScale);
                HudSetAimLine(true, CGPointMake(ax, ay));
            } else {
                HudSetAimLine(false, CGPointMake(0, 0));
            }
        } else {
            HudSetAimLine(false, CGPointMake(0, 0));
        }
        
        bool localAiming = false;
        float localSpread = 0.0f;
        if (alive(g_localWeapon) && IsRangeWeapon(g_localWeapon)) {
            // Redundant safety net: keep spread/recoil neutralised even if the camera
            // LateUpdate hook is not installed or runs on a different object.
            BallisticsTick();
            localAiming = *(bool*)((uintptr_t)g_localWeapon + off::kWepIsAiming);
            Vec2 sp = *(Vec2*)((uintptr_t)g_localWeapon + off::kWepSpread);
            if (Math::Finite(sp.x) && Math::Finite(sp.y)) {
                localSpread = sqrtf(sp.x * sp.x + sp.y * sp.y);
            }
        }
        HudSetCrosshair(6.0f + localSpread * 160.0f, gCrosshairEnabled);
        HudSetScope(localAiming && gScopeOverlayEnabled);
        gLocalScoped = localAiming;
        
        if (alive(lch)) {
            gLocalHealthVal = *(int*)((uintptr_t)lch + off::kCharHealth);
            gLocalArmorVal = *(int*)((uintptr_t)lch + off::kCharArmor);
        }
        if (alive(g_localCC)) {
            Vec3 vel = *(Vec3*)((uintptr_t)g_localCC + off::kMoveVelocity);
            if (Math::Finite(vel)) {
                gLocalSpeedVal = sqrtf(vel.x * vel.x + vel.z * vel.z);
            }
        }
        if (gSpeedHistory.size() >= 120) {
            gSpeedHistory.erase(gSpeedHistory.begin());
        }
        gSpeedHistory.push_back(gLocalSpeedVal.load());
        
        TriggerbotTick();
        SkinChangerTick();
        HudTick();

        // Rage runs last: it reads the same gCached / g_localCamera snapshot the legacy
        // features just refreshed, and its synthetic trigger must not be overwritten by the
        // legacy triggerbot's own release path.
        RageTick();
        RageAutoScopeTick();

        [gEspView setNeedsDisplay];
    }
}

@interface ESPDriver : NSObject
@end

@implementation ESPDriver

- (void)tick:(CADisplayLink*)link {
    @try {
        espTick();
    } @catch (NSException* e) {
        LOG(@"espTick: %@", SafeStr([e reason]));
    }
}

@end

static ESPDriver* gDriver = nil;
static CADisplayLink* gLink = nil;

@implementation HotkeyView {
    CGPoint _panStartOrigin;
}

- (instancetype)initWithFrame:(CGRect)f {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:@"hk_x"] && [defaults objectForKey:@"hk_y"]) {
        f.origin = CGPointMake([defaults doubleForKey:@"hk_x"], [defaults doubleForKey:@"hk_y"]);
    }

    self = [super initWithFrame:f];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;
        
        CGFloat btnW = 54, btnH = 20, gap = 5;
        CGFloat startX = 8, startY = 14;
        self.dragHandle = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, self.bounds.size.width, 12)];
        self.dragHandle.text = @"MOVE";
        self.dragHandle.textAlignment = NSTextAlignmentCenter;
        self.dragHandle.textColor = [UIColor colorWithWhite:1.0 alpha:0.75];
        self.dragHandle.font = [UIFont boldSystemFontOfSize:7];
        self.dragHandle.userInteractionEnabled = YES;
        [self addSubview:self.dragHandle];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panAction:)];
        [self.dragHandle addGestureRecognizer:pan];
        
        self.hkbAimbot = [UIButton buttonWithType:UIButtonTypeSystem];
        self.hkbAimbot.frame = CGRectMake(startX, startY, btnW, btnH);
        self.hkbAimbot.titleLabel.font = [UIFont boldSystemFontOfSize:8];
        self.hkbAimbot.layer.cornerRadius = 3;
        [self.hkbAimbot setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [self.hkbAimbot addTarget:self action:@selector(tapAimbot) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:self.hkbAimbot];
        
        self.hkbAimFire = [UIButton buttonWithType:UIButtonTypeSystem];
        self.hkbAimFire.frame = CGRectMake(startX, startY + btnH + gap, btnW, btnH);
        self.hkbAimFire.titleLabel.font = [UIFont boldSystemFontOfSize:8];
        self.hkbAimFire.layer.cornerRadius = 3;
        [self.hkbAimFire setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [self.hkbAimFire addTarget:self action:@selector(tapAimFire) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:self.hkbAimFire];
        
        self.hkbEsp = [UIButton buttonWithType:UIButtonTypeSystem];
        self.hkbEsp.frame = CGRectMake(startX, startY + (btnH + gap) * 2, btnW, btnH);
        self.hkbEsp.titleLabel.font = [UIFont boldSystemFontOfSize:8];
        self.hkbEsp.layer.cornerRadius = 3;
        [self.hkbEsp setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [self.hkbEsp addTarget:self action:@selector(tapEsp) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:self.hkbEsp];
        
        [self updateTitles];
    }
    return self;
}

- (CGPoint)clampedOrigin:(CGPoint)origin {
    if (!self.superview) {
        return origin;
    }

    CGRect bounds = self.superview.bounds;
    CGFloat maxX = MAX(CGRectGetMinX(bounds), CGRectGetMaxX(bounds) - self.bounds.size.width);
    CGFloat maxY = MAX(CGRectGetMinY(bounds), CGRectGetMaxY(bounds) - self.bounds.size.height);
    origin.x = MIN(MAX(origin.x, CGRectGetMinX(bounds)), maxX);
    origin.y = MIN(MAX(origin.y, CGRectGetMinY(bounds)), maxY);
    return origin;
}

- (void)didMoveToSuperview {
    [super didMoveToSuperview];
    if (self.superview) {
        CGPoint origin = [self clampedOrigin:self.frame.origin];
        self.frame = CGRectMake(origin.x, origin.y, self.bounds.size.width, self.bounds.size.height);
    }
}

- (void)panAction:(UIPanGestureRecognizer*)pan {
    if (pan.state == UIGestureRecognizerStateBegan) {
        _panStartOrigin = self.frame.origin;
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        CGPoint translation = [pan translationInView:self.superview];
        CGPoint origin = CGPointMake(_panStartOrigin.x + translation.x, _panStartOrigin.y + translation.y);
        origin = [self clampedOrigin:origin];
        self.frame = CGRectMake(origin.x, origin.y, self.bounds.size.width, self.bounds.size.height);
    } else if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setDouble:self.frame.origin.x forKey:@"hk_x"];
        [defaults setDouble:self.frame.origin.y forKey:@"hk_y"];
    }
}

- (void)updateTitles {
    [self.hkbAimbot setTitle:gHotAimbotEnabled ? @"AIM:ON" : @"AIM:OFF" forState:UIControlStateNormal];
    [self.hkbAimFire setTitle:gHotAimOnFireEnabled ? @"FIRE:ON" : @"FIRE:OFF" forState:UIControlStateNormal];
    [self.hkbEsp setTitle:gHotEspEnabled ? @"ESP:ON" : @"ESP:OFF" forState:UIControlStateNormal];
    
    self.hkbAimbot.backgroundColor = gHotAimbotEnabled ? [UIColor greenColor] : [UIColor redColor];
    self.hkbAimFire.backgroundColor = gHotAimOnFireEnabled ? [UIColor greenColor] : [UIColor redColor];
    self.hkbEsp.backgroundColor = gHotEspEnabled ? [UIColor greenColor] : [UIColor redColor];
}

- (void)tapAimbot {
    gHotAimbotEnabled = !gHotAimbotEnabled;
    [ConfigManager save];
    [self updateTitles];
}

- (void)tapAimFire {
    gHotAimOnFireEnabled = !gHotAimOnFireEnabled;
    [ConfigManager save];
    [self updateTitles];
}

- (void)tapEsp {
    gHotEspEnabled = !gHotEspEnabled;
    [ConfigManager save];
    [self updateTitles];
}

@end

static void RefreshHotkeyView(void) {
    [gHotkeyView updateTitles];
}

static void startMainUI(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            gWatermark = [[WatermarkView alloc] initWithFrame:CGRectMake(20, 60, 620, 34)];
            [gOverlayContainer addSubview:gWatermark];
            
            gEspView = [[ESPView alloc] initWithFrame:gMainWin.bounds];
            gEspView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [gOverlayContainer addSubview:gEspView];
            
            SetupHudView();
            
            gHotZone = [[HotZoneView alloc] initWithFrame:CGRectMake((gMainWin.bounds.size.width - 60)/2, (gMainWin.bounds.size.height - 60)/2, 60, 60)];
            [gOverlayContainer addSubview:gHotZone];
            
            gMenuView = [[MenuView alloc] initWithFrame:CGRectMake((gMainWin.bounds.size.width - 620)/2, (gMainWin.bounds.size.height - 440)/2, 620, 440)];
            gMenuView.hidden = YES;
            [gOverlayContainer addSubview:gMenuView];
            
            if (gSnowEnabled.load()) {
                SnowOverlaySetEnabled(true);
            }
            
            gHotkeyView = [[HotkeyView alloc] initWithFrame:CGRectMake(8, MAX(0, gOverlayContainer.bounds.size.height - 92), 70, 84)];
            gHotkeyView.hidden = YES;
            [gOverlayContainer addSubview:gHotkeyView];
            
            gAttached = true;
            LOG(@"Attached v%s", kEspVersion);
            
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                @try {
                    gHotZone.hidden = YES;
                    gEspView.hidden = YES;
                    gWatermark.hidden = YES;
                    gMenuOpen = true;
                    gMenuView.hidden = NO;
                    gMenuView.alpha = 0;
                    gMenuView.transform = CGAffineTransformMakeScale(0.95, 0.95);
                    
                    [gOverlayContainer bringSubviewToFront:gMenuView];
                    [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.5 options:UIViewAnimationOptionAllowUserInteraction animations:^{
                        gMenuView.alpha = 1.0;
                        gMenuView.transform = CGAffineTransformIdentity;
                    } completion:nil];
                } @catch (NSException* e) {
                }
            });
        } @catch (NSException* e) {
            LOG(@"startMainUI: %@", SafeStr([e reason]));
        }
    });
}

static void startOverlay(void) {
    @try {
        UIWindow *mw = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
                if (![s isKindOfClass:[UIWindowScene class]]) {
                    continue;
                }
                
                UIWindowScene *ws = (UIWindowScene*)s;
                if (ws.activationState != UISceneActivationStateForegroundActive) {
                    continue;
                }
                
                for (UIWindow *w in ws.windows) {
                    if (w.isKeyWindow) {
                        mw = w;
                        break;
                    }
                }
                if (mw) {
                    break;
                }
            }
        }
        
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if (!mw) {
            mw = UIApplication.sharedApplication.keyWindow;
        }
#pragma clang diagnostic pop
        
        if (!mw) {
            return;
        }
        
        gMainWin = mw;
        gScreenPts = mw.bounds.size;
        gScreenScale = [UIScreen mainScreen].scale;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                gOverlayContainer = [[PassthroughView alloc] initWithFrame:gMainWin.bounds];
                gOverlayContainer.backgroundColor = [UIColor clearColor];
                gOverlayContainer.userInteractionEnabled = YES;
                [gMainWin addSubview:gOverlayContainer];
                
                BOOL isAuthed = [[NSUserDefaults standardUserDefaults] boolForKey:@"flop_authed"];
                
                if (isAuthed) {
                    startMainUI();
                } else {
                    KeySystemView *keyView = [[KeySystemView alloc] initWithFrame:gMainWin.bounds];
                    keyView.onSuccess = ^{
                        startMainUI();
                    };
                    [gOverlayContainer addSubview:keyView];
                }
            } @catch (NSException* e) {
                LOG(@"startOverlay: %@", SafeStr([e reason]));
            }
        });
    } @catch (NSException* e) {
    }
}

static void bootstrap(void) {
    @autoreleasepool {
        InstallCrashHandler();
        
        RebuildSoundPlayers();
        gStatSessionStart = NowMs();
        
        void *dget = nullptr;
        for (int i = 0; i < 300; i++) {
            dget = dlsym(RTLD_DEFAULT, "il2cpp_domain_get");
            if (dget) {
                break;
            }
            usleep(100000);
        }
        
        if (!dget) {
            return;
        }
        sleep(8);
        
        gDomain = ((void*(*)())dget)();
        p_thread_attach = (fn_thread_attach)dlsym(RTLD_DEFAULT, "il2cpp_thread_attach");
        if (p_thread_attach && gDomain) {
            p_thread_attach(gDomain);
        }
        
        #define RES(f, n) do { f = (decltype(f))dlsym(RTLD_DEFAULT, n); if (!f) { LOG(@"Missing %s", n); return; } } while (0)
        RES(p_domain_get, "il2cpp_domain_get");
        RES(p_domain_get_assemblies, "il2cpp_domain_get_assemblies");
        RES(p_assembly_get_image, "il2cpp_assembly_get_image");
        RES(p_class_from_name, "il2cpp_class_from_name");
        RES(p_class_get_method_from_name, "il2cpp_class_get_method_from_name");
        RES(p_class_get_type, "il2cpp_class_get_type");
        RES(p_type_get_object, "il2cpp_type_get_object");
        p_class_get_name = (fn_class_get_name)dlsym(RTLD_DEFAULT, "il2cpp_class_get_name");
        p_class_get_namespace = (fn_class_get_namespace)dlsym(RTLD_DEFAULT, "il2cpp_class_get_namespace");
        p_class_get_parent = (fn_class_get_parent)dlsym(RTLD_DEFAULT, "il2cpp_class_get_parent");
        p_image_get_class_count = (fn_image_get_class_count)dlsym(RTLD_DEFAULT, "il2cpp_image_get_class_count");
        p_image_get_class = (fn_image_get_class)dlsym(RTLD_DEFAULT, "il2cpp_image_get_class");
        RES(p_runtime_invoke, "il2cpp_runtime_invoke");
        RES(p_gchandle_new, "il2cpp_gchandle_new");
        RES(p_gchandle_get_target, "il2cpp_gchandle_get_target");
        RES(p_string_new, "il2cpp_string_new");
        #undef RES
        
        p_object_new = (fn_object_new)dlsym(RTLD_DEFAULT, "il2cpp_object_new");
        p_array_new = (fn_array_new)dlsym(RTLD_DEFAULT, "il2cpp_array_new");
        p_gchandle_free = (fn_gchandle_free)dlsym(RTLD_DEFAULT, "il2cpp_gchandle_free");
        p_class_get_methods = (fn_class_get_methods)dlsym(RTLD_DEFAULT, "il2cpp_class_get_methods");
        p_method_get_name = (fn_method_get_name)dlsym(RTLD_DEFAULT, "il2cpp_method_get_name");
        p_method_get_param_count = (fn_method_get_param_count)dlsym(RTLD_DEFAULT, "il2cpp_method_get_param_count");
        p_method_get_param = (fn_method_get_param)dlsym(RTLD_DEFAULT, "il2cpp_method_get_param");
        p_type_get_name = (fn_type_get_name)dlsym(RTLD_DEFAULT, "il2cpp_type_get_name");
        
        gObjCls = findClass("UnityEngine", "Object");
        gGOCls = findClass("UnityEngine", "GameObject");
        void *camCls = findClass("UnityEngine", "Camera");
        gTransformCls = findClass("UnityEngine", "Transform");
        gAnimatorCls = findClass("UnityEngine", "Animator");
        gCharCls = findClass("", "SceneLevelCharacter");
        gVolumeCls = findClass("UnityEngine.Rendering", "Volume");
        if (!gVolumeCls) {
            gVolumeCls = findClass("", "Volume");
        }
        gMatCls = findClass("UnityEngine", "Material");
        gSkyboxCls = findClass("UnityEngine", "RenderSettings");
        gRendererCls = findClass("UnityEngine", "Renderer");
        gLightCls = findClass("UnityEngine", "Light");
        gColorAdjCls = findClass("UnityEngine.Rendering.Universal", "ColorAdjustments");
        if (!gColorAdjCls) {
            gColorAdjCls = findClass("", "ColorAdjustments");
        }
        gBloomCls = findClass("UnityEngine.Rendering.Universal", "Bloom");
        if (!gBloomCls) {
            gBloomCls = findClass("", "Bloom");
        }
        gMotionBlurCls = findClass("UnityEngine.Rendering.Universal", "MotionBlur");
        if (!gMotionBlurCls) {
            gMotionBlurCls = findClass("", "MotionBlur");
        }
        gApplicationCls = findClass("UnityEngine", "Application");
        if (gApplicationCls) {
            gSetTargetFrameRateMI = p_class_get_method_from_name(gApplicationCls, "set_targetFrameRate", 1);
        }
        gClampedFCls = findClass("UnityEngine.Rendering", "ClampedFloatParameter");
        if (!gClampedFCls) {
            gClampedFCls = findClass("", "ClampedFloatParameter");
        }
        gMinFCls = findClass("UnityEngine.Rendering", "MinFloatParameter");
        if (!gMinFCls) {
            gMinFCls = findClass("", "MinFloatParameter");
        }
        gFloatPCls = findClass("UnityEngine.Rendering", "FloatParameter");
        if (!gFloatPCls) {
            gFloatPCls = findClass("", "FloatParameter");
        }
        gCamDataCls = findClass("UnityEngine.Rendering.Universal", "UniversalAdditionalCameraData");
        if (!gCamDataCls) {
            gCamDataCls = findClass("", "UniversalAdditionalCameraData");
        }
        
        void* playerCls = findClass("", "SceneLevelPlayer");
        
        if (!gObjCls || !camCls || !gTransformCls || !playerCls) {
            LOG(@"Failed core");
            return;
        }
        
        gPlayerTypeHandle = p_gchandle_new(p_type_get_object(p_class_get_type(playerCls)), true);
        if (gVolumeCls) {
            gVolumeTypeHandle = p_gchandle_new(p_type_get_object(p_class_get_type(gVolumeCls)), true);
        }
        if (gLightCls) {
            gLightTypeHandle = p_gchandle_new(p_type_get_object(p_class_get_type(gLightCls)), true);
        }
        if (gCamDataCls) {
            gCamDataTypeHandle = p_gchandle_new(p_type_get_object(p_class_get_type(gCamDataCls)), true);
        }
        
        if (gMatCls) {
            EnsureMaterialCtorMI();
            p_matSetTextureMI = p_class_get_method_from_name(gMatCls, "SetTexture", 2);
            if (p_matSetTextureMI) {
                p_matSetTexture = (fn_matSetTexture)methodPtr(p_matSetTextureMI);
            }
        }
        
        if (gGOCls) {
            p_getCompsInChildrenMI = p_class_get_method_from_name(gGOCls, "GetComponentsInChildren", 1);
            void* mi2 = p_class_get_method_from_name(gGOCls, "GetComponentsInChildren", 2);
            if (mi2) {
                p_getCompsInChildrenMI = mi2;
            }
        }
        
        p_findPlayerMI = p_class_get_method_from_name(gObjCls, "FindObjectsOfType", 1);
        if (gVolumeCls) {
            p_findVolumeMI = p_class_get_method_from_name(gObjCls, "FindObjectsOfType", 1);
        }
        
        if (gLightCls) {
            p_lightGetIntensityMI = p_class_get_method_from_name(gLightCls, "get_intensity", 0);
            p_lightSetIntensityMI = p_class_get_method_from_name(gLightCls, "set_intensity", 1);
            p_lightGetColorMI = p_class_get_method_from_name(gLightCls, "get_color", 0);
            p_lightSetColorMI = p_class_get_method_from_name(gLightCls, "set_color", 1);
            if (p_lightGetIntensityMI) {
                p_lightGetIntensity = (fn_lightGetIntensity)methodPtr(p_lightGetIntensityMI);
            }
            if (p_lightSetIntensityMI) {
                p_lightSetIntensity = (fn_lightSetIntensity)methodPtr(p_lightSetIntensityMI);
            }
            if (p_lightGetColorMI) {
                p_lightGetColor = (fn_lightGetColor)methodPtr(p_lightGetColorMI);
            }
            if (p_lightSetColorMI) {
                p_lightSetColor = (fn_lightSetColor)methodPtr(p_lightSetColorMI);
            }
        }
        
        if (gSkyboxCls) {
            p_setFogMI = p_class_get_method_from_name(gSkyboxCls, "set_fog", 1);
            p_getFogMI = p_class_get_method_from_name(gSkyboxCls, "get_fog", 0);
            p_renderSetAmbientLightMI = p_class_get_method_from_name(gSkyboxCls, "set_ambientLight", 1);
            p_renderGetAmbientLightMI = p_class_get_method_from_name(gSkyboxCls, "get_ambientLight", 0);
            if (p_setFogMI) {
                p_setFog = (fn_setFog)methodPtr(p_setFogMI);
            }
            if (p_getFogMI) {
                p_getFog = (fn_getFog)methodPtr(p_getFogMI);
            }
            if (p_renderSetAmbientLightMI) {
                p_renderSetAmbientLight = (fn_renderSetAmbientLight)methodPtr(p_renderSetAmbientLightMI);
            }
            if (p_renderGetAmbientLightMI) {
                p_renderGetAmbientLight = (fn_renderGetAmbientLight)methodPtr(p_renderGetAmbientLightMI);
            }
        }
        
        if (gClampedFCls) {
            p_cfaValMI = p_class_get_method_from_name(gClampedFCls, "set_value", 1);
        }
        if (gMinFCls) {
            p_mfaValMI = p_class_get_method_from_name(gMinFCls, "set_value", 1);
        }
        if (gFloatPCls) {
            p_fpaValMI = p_class_get_method_from_name(gFloatPCls, "set_value", 1);
        }
        p_camW2SMI = p_class_get_method_from_name(camCls, "WorldToScreenPoint", 1);
        p_tfGetPosMI = p_class_get_method_from_name(gTransformCls, "get_position", 0);
        p_tfSetPosMI = p_class_get_method_from_name(gTransformCls, "set_position", 1);
        p_tfGetLocalScaleMI = p_class_get_method_from_name(gTransformCls, "get_localScale", 0);
        p_tfSetLocalScaleMI = p_class_get_method_from_name(gTransformCls, "set_localScale", 1);
        p_tfGetEulerMI = p_class_get_method_from_name(gTransformCls, "get_eulerAngles", 0);
        
        if (p_tfGetLocalScaleMI) {
            p_tfGetLocalScale = (fn_tfGetLocalScale)methodPtr(p_tfGetLocalScaleMI);
        }
        if (p_tfSetLocalScaleMI) {
            p_tfSetLocalScale = (fn_tfSetLocalScale)methodPtr(p_tfSetLocalScaleMI);
        }
        if (p_tfGetEulerMI) {
            p_tfGetEuler = (fn_tfGetEuler)methodPtr(p_tfGetEulerMI);
        }
        
        if (gAnimatorCls) {
            p_getBoneTransformMI = p_class_get_method_from_name(gAnimatorCls, "GetBoneTransform", 1);
            if (p_getBoneTransformMI) {
                p_getBoneTransform = (fn_getBoneTransform)methodPtr(p_getBoneTransformMI);
            }
        }
        
        p_camGetPixelWidthMI = p_class_get_method_from_name(camCls, "get_pixelWidth", 0);
        p_camGetPixelHeightMI = p_class_get_method_from_name(camCls, "get_pixelHeight", 0);
        p_camGetFovMI = p_class_get_method_from_name(camCls, "get_fieldOfView", 0);
        if (p_camGetFovMI) {
            p_camGetFov = (fn_camGetFov)methodPtr(p_camGetFovMI);
        }
        p_camSetAspectMI = p_class_get_method_from_name(camCls, "set_aspect", 1);
        if (p_camSetAspectMI) {
            p_camSetAspect = (fn_camSetAspect)methodPtr(p_camSetAspectMI);
        }
        p_camSetFovMI = p_class_get_method_from_name(camCls, "set_fieldOfView", 1);
        if (p_camSetFovMI) {
            p_camSetFov = (fn_camSetFov)methodPtr(p_camSetFovMI);
        }
        
        if (gSkyboxCls) {
            p_getSkyboxMI = p_class_get_method_from_name(gSkyboxCls, "get_skybox", 0);
            if (p_getSkyboxMI) {
                p_getSkybox = (fn_getSkybox)methodPtr(p_getSkyboxMI);
            }
        }
        
        if (gMatCls) {
            p_matSetColorMI = p_class_get_method_from_name(gMatCls, "SetColor", 2);
            if (p_matSetColorMI) {
                p_matSetColor = (fn_matSetColor)methodPtr(p_matSetColorMI);
            }
            p_matSetFloatMI = p_class_get_method_from_name(gMatCls, "SetFloat", 2);
            if (p_matSetFloatMI) {
                p_matSetFloat = (fn_matSetFloat)methodPtr(p_matSetFloatMI);
            }
            p_matSetIntMI = p_class_get_method_from_name(gMatCls, "SetInt", 2);
            if (p_matSetIntMI) {
                p_matSetInt = (fn_matSetInt)methodPtr(p_matSetIntMI);
            }
            p_matEnableKeywordMI = p_class_get_method_from_name(gMatCls, "EnableKeyword", 1);
            if (p_matEnableKeywordMI) {
                p_matEnableKeyword = (fn_matEnableKeyword)methodPtr(p_matEnableKeywordMI);
            }
            p_matSetRQMI = p_class_get_method_from_name(gMatCls, "set_renderQueue", 1);
            if (p_matSetRQMI) {
                p_matSetRQ = (fn_matSetRenderQueue)methodPtr(p_matSetRQMI);
            }
        }
        
        if (gRendererCls) {
            p_rendGetSharedMatsMI = p_class_get_method_from_name(gRendererCls, "get_sharedMaterials", 0);
            if (p_rendGetSharedMatsMI) {
                p_rendGetSharedMats = (fn_rendGetSharedMats)methodPtr(p_rendGetSharedMatsMI);
            }
            p_rendSetSharedMatsMI = p_class_get_method_from_name(gRendererCls, "set_sharedMaterials", 1);
            if (p_rendSetSharedMatsMI) {
                p_rendSetSharedMats = (fn_rendSetSharedMats)methodPtr(p_rendSetSharedMatsMI);
            }
            p_rendSetEnabledMI = p_class_get_method_from_name(gRendererCls, "set_enabled", 1);
            if (p_rendSetEnabledMI) {
                p_rendSetEnabled = (fn_rendSetEnabled)methodPtr(p_rendSetEnabledMI);
            }
            p_rendGetEnabledMI = p_class_get_method_from_name(gRendererCls, "get_enabled", 0);
            if (p_rendGetEnabledMI) {
                p_rendGetEnabled = (fn_rendGetEnabled)methodPtr(p_rendGetEnabledMI);
            }
        }
        
        void* componentCls = findClass("UnityEngine", "Component");
        if (componentCls) {
            p_getTransformMI = p_class_get_method_from_name(componentCls, "get_transform", 0);
            if (p_getTransformMI) {
                p_getTransform = (fn_getTransform)methodPtr(p_getTransformMI);
            }
            p_getGameObjectMI = p_class_get_method_from_name(componentCls, "get_gameObject", 0);
            if (p_getGameObjectMI) {
                p_getGameObject = (fn_getGameObject)methodPtr(p_getGameObjectMI);
            }
        }
        
        if (p_camW2SMI) {
            p_camW2S = (fn_camW2S)methodPtr(p_camW2SMI);
        }
        if (p_camGetPixelWidthMI) {
            p_camGetPixelWidth = (fn_camGetPixelWidth)methodPtr(p_camGetPixelWidthMI);
        }
        if (p_camGetPixelHeightMI) {
            p_camGetPixelHeight = (fn_camGetPixelHeight)methodPtr(p_camGetPixelHeightMI);
        }
        if (p_tfGetPosMI) {
            p_tfGetPos = (fn_tfGetPos)methodPtr(p_tfGetPosMI);
        }
        if (p_tfSetPosMI) {
            p_tfSetPos = (fn_tfSetPos)methodPtr(p_tfSetPosMI);
        }
        
        void* sceneCamCls = findClass("", "SceneLevelCamera");
        if (sceneCamCls) {
            p_sceneSetFovMI = p_class_get_method_from_name(sceneCamCls, "SetFieldOfView", 1);
            if (p_sceneSetFovMI) {
                p_sceneSetFov = (fn_sceneSetFov)methodPtr(p_sceneSetFovMI);
            }

            p_lookAtTargetMI = p_class_get_method_from_name(sceneCamCls, "LookAtTarget", 1);
            if (p_lookAtTargetMI) {
                p_lookAtTarget = (fn_LookAtTarget)methodPtr(p_lookAtTargetMI);
            }
        }
        
        if (gCharCls) {
            p_checkSeenMI = p_class_get_method_from_name(gCharCls, "CheckSeen", 1);
            if (p_checkSeenMI) {
                p_CheckSeen = (fn_CheckSeen)methodPtr(p_checkSeenMI);
            }
        }
        
        @try {
            InstallAllHooks();
            [ConfigManager load];
            ApplyFpsLimit();
        } @catch (NSException* e) {
            LOG(@"bootstrap hooks: %@", SafeStr([e reason]));
        }
        
        dispatch_queue_t q = dispatch_get_main_queue();
        gChamsTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_timer(gChamsTimer, DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC, 100 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(gChamsTimer, ^{
            @try {
                ChamsTick();
            } @catch (NSException* e) {
            }
        });
        dispatch_resume(gChamsTimer);
        
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                if (p_thread_attach && gDomain) {
                    p_thread_attach(gDomain);
                }
                
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    NSURL *tgUrl = [NSURL URLWithString:@"tg://resolve?domain=FlopDLC"];
                    if ([[UIApplication sharedApplication] canOpenURL:tgUrl]) {
                        [[UIApplication sharedApplication] openURL:tgUrl options:@{} completionHandler:nil];
                    } else {
                        NSURL *webUrl = [NSURL URLWithString:@"https://t.me/FlopDLC"];
                        [[UIApplication sharedApplication] openURL:webUrl options:@{} completionHandler:nil];
                    }
                });
                
                startOverlay();
                
                gDriver = [ESPDriver new];
                gLink = [CADisplayLink displayLinkWithTarget:gDriver selector:@selector(tick:)];
                gLink.preferredFramesPerSecond = 30;
                [gLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
                
                LOG(@"Bootstrap complete");
            } @catch (NSException* e) {
            }
        });
    }
}

__attribute__((constructor, used))
static void ctor(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        bootstrap();
    });
}

// =========================================================================================
// BALLISTICS CORE — WORKING NO SPREAD / NO RECOIL
// =========================================================================================
// Layers, in order of strength:
//   1. WeaponDataRange asset neutralization (ShootOffset / SpreadMove / RecoilPatternScale /
//      StandingBallisticMul / UnscopedRecoilMul / _fireBackOffset). This is the data the
//      weapon reads when it builds the shot direction, so zeroing it removes the source.
//   2. Runtime state neutralization (<Spread>, <Recoil>, Offset, jyw, jzc) every tick and
//      immediately around UseProcess / Update / camera LateUpdate.
//   3. Method-slot hooks for GetSpreadMultiplier and UseProcess. They cover reflection and
//      runtime-invoke paths and return an exact zero multiplier when the feature is active.
//   4. UnityEngine.Random.insideUnitCircle / insideUnitSphere hooks. If the shot code uses
//      the standard Unity random circle for pellet/cone jitter, this kills that jitter too.
//   5. Camera snapshot around the fire button. Recoil that is applied to the view inside the
//      shot call is rolled back immediately, so the crosshair does not climb.
// =========================================================================================

struct RangeSnapshot {
    void* klass;
    Vec2 shootOffset;
    Vec2 spreadMove;
    float offsetCool;
    float standingMul;
    float patternScale;
    float unscopedMul;
    Vec3 fireBackOffset;
    float fireBackTime;
    Vec3 shootMultiOffset;
};

static std::unordered_map<void*, RangeSnapshot> gRangeSnapshots;
static std::atomic<bool> gRangeApplied{false};
static void* gRangeClassPtr = nullptr;
static void* gShotgunClassPtr = nullptr;
static std::atomic<uint64_t> gLastBallisticsLog{0};
static std::atomic<uint64_t> gSpreadWindowUntil{0};

static inline float SpreadFloorValue(void) {
    if (!gSpreadFloorEnabled.load()) {
        return 0.0f;
    }
    float v = gSpreadFloor.load();
    if (!std::isfinite(v) || v < 0.0f) {
        return 0.0f;
    }
    return Math::Clamp(v, 0.0f, 0.02f);
}

// Aimbot, Aim On Fire, Silent Aim and Triggerbot all imply "weapon is being
// used through the aim pipeline", so ballistics stay neutralised for the whole
// time any of them is enabled. Turning every aim mode off restores vanilla
// spread/recoil unless the PLAYER-tab manual toggle is on.
static inline bool AnyAimModeActive(void) {
    return gAimbotEnabled.load() || gHotAimbotEnabled.load() ||
           gAimOnFireEnabled.load() || gHotAimOnFireEnabled.load() ||
           gSilentAimEnabled.load() || gTriggerbotEnabled.load();
}

// LEGIT: arming an aim mode also arms the ballistics neutralisers, so the very first shot is
// already clean instead of needing a second trip to the weapon tab. Only ever switches them on:
// turning an aim mode off leaves the manual toggles exactly where the user put them.
static void LegitAimModeChanged(bool on) {
    if (!on) {
        return;
    }
    if (!gNoSpreadEnabled.load()) {
        gNoSpreadEnabled = true;
    }
    if (!gNoRecoilEnabled.load()) {
        gNoRecoilEnabled = true;
    }
    [ConfigManager save];
}

static bool NoSpreadActive(void) {
    return gNoSpreadEnabled.load() || AnyAimModeActive();
}

static bool NoRecoilActive(void) {
    return gNoRecoilEnabled.load() || AnyAimModeActive();
}

// ItemEquipWeaponRange and ItemEquipWeaponRangeShotgun are the only classes that own the
// spread/recoil fields. Grenade and melee items share the ItemEquipWeapon base and are
// much smaller, so writing range offsets into them would corrupt the heap. Never touch a
// weapon unless its il2cpp class is (or derives from) one of the two range classes.
static bool ClassDerivesFrom(void* klass, void* base) {
    if (!SANE_PTR(klass) || !SANE_PTR(base)) {
        return false;
    }
    int guard = 0;
    while (klass && guard++ < 32) {
        if (klass == base) {
            return true;
        }
        if (!p_class_get_parent) {
            return false;
        }
        klass = p_class_get_parent(klass);
    }
    return false;
}

// Name based fallback for builds where findClass could not resolve the class pointer
// (for example if the namespace or the il2cpp image API changed).
static bool ClassNameIsRange(void* klass) {
    if (!SANE_PTR(klass) || !p_class_get_name) {
        return false;
    }
    int guard = 0;
    while (klass && guard++ < 32) {
        const char* name = p_class_get_name(klass);
        if (name) {
            if (strcmp(name, "ItemEquipWeaponRange") == 0 ||
                strcmp(name, "ItemEquipWeaponRangeShotgun") == 0) {
                return true;
            }
        }
        klass = p_class_get_parent ? p_class_get_parent(klass) : nullptr;
    }
    return false;
}

static bool IsRangeWeapon(void* weapon) {
    if (!SANE_PTR(weapon)) {
        return false;
    }
    void* klass = *(void**)weapon;
    if (!SANE_PTR(klass)) {
        return false;
    }
    if (ClassDerivesFrom(klass, gRangeClassPtr)) {
        return true;
    }
    if (gShotgunClassPtr && ClassDerivesFrom(klass, gShotgunClassPtr)) {
        return true;
    }
    if (ClassNameIsRange(klass)) {
        return true;
    }
    return false;
}

static void CaptureRangeData(void* data) {
    if (!SANE_PTR(data)) {
        return;
    }
    if (gRangeSnapshots.find(data) != gRangeSnapshots.end()) {
        return;
    }
    
    RangeSnapshot snap;
    snap.klass = *(void**)data;
    snap.shootOffset = *(Vec2*)((uintptr_t)data + off::kRangeShootOffset);
    snap.spreadMove = *(Vec2*)((uintptr_t)data + off::kRangeSpreadMove);
    snap.offsetCool = *(float*)((uintptr_t)data + off::kRangeOffsetCool);
    snap.standingMul = *(float*)((uintptr_t)data + off::kRangeStandingBallisticMul);
    snap.patternScale = *(float*)((uintptr_t)data + off::kRangeRecoilPatternScale);
    snap.unscopedMul = *(float*)((uintptr_t)data + off::kRangeUnscopedRecoilMul);
    snap.fireBackOffset = *(Vec3*)((uintptr_t)data + off::kDataFireBackOffset);
    snap.fireBackTime = *(float*)((uintptr_t)data + off::kDataFireBackTime);
    snap.shootMultiOffset = *(Vec3*)((uintptr_t)data + off::kDataShootMultiOffset);
    gRangeSnapshots[data] = snap;
}

static void ApplyRangeData(void* data) {
    if (!SANE_PTR(data)) {
        return;
    }
    CaptureRangeData(data);
    
    float floorValue = SpreadFloorValue();
    Vec2 offset(floorValue, floorValue);
    
    *(Vec2*)((uintptr_t)data + off::kRangeShootOffset) = offset;
    *(Vec2*)((uintptr_t)data + off::kRangeSpreadMove) = Vec2(0.0f, 0.0f);
    
    // Never zero fields the game may use as a divisor: 1/x with x == 0 produces inf/nan,
    // and that NaN propagates into the shot ray, the viewmodel and the game HUD.
    // OffsetCool and _fireBackOffsetTime are left at their authored values on purpose.
    // StandingBallisticMul uses 1.0 as its neutral "as is" value (see the tooltip).
    *(float*)((uintptr_t)data + off::kRangeStandingBallisticMul) = 1.0f;
    *(float*)((uintptr_t)data + off::kRangeRecoilPatternScale) = 0.0f;
    *(float*)((uintptr_t)data + off::kRangeUnscopedRecoilMul) = 0.0f;
    *(Vec3*)((uintptr_t)data + off::kDataFireBackOffset) = Vec3(0.0f, 0.0f, 0.0f);
    *(Vec3*)((uintptr_t)data + off::kDataShootMultiOffset) = Vec3(0.0f, 0.0f, 0.0f);
}

static void RestoreRangeData(void) {
    if (!gRangeApplied.load() && gRangeSnapshots.empty()) {
        return;
    }
    
    for (auto& kv : gRangeSnapshots) {
        void* data = kv.first;
        RangeSnapshot& snap = kv.second;
        if (!SANE_PTR(data)) {
            continue;
        }
        // Guard against a recycled address: only restore if the object still has the
        // same il2cpp class pointer that it had when the snapshot was taken.
        if (!SANE_PTR(snap.klass) || *(void**)data != snap.klass) {
            continue;
        }
        
        *(Vec2*)((uintptr_t)data + off::kRangeShootOffset) = snap.shootOffset;
        *(Vec2*)((uintptr_t)data + off::kRangeSpreadMove) = snap.spreadMove;
        *(float*)((uintptr_t)data + off::kRangeStandingBallisticMul) = snap.standingMul;
        *(float*)((uintptr_t)data + off::kRangeRecoilPatternScale) = snap.patternScale;
        *(float*)((uintptr_t)data + off::kRangeUnscopedRecoilMul) = snap.unscopedMul;
        *(Vec3*)((uintptr_t)data + off::kDataFireBackOffset) = snap.fireBackOffset;
        *(Vec3*)((uintptr_t)data + off::kDataShootMultiOffset) = snap.shootMultiOffset;
    }
    
    gRangeSnapshots.clear();
    gRangeApplied = false;
}

static void PatchWeaponRangeData(void* weapon) {
    if (!IsRangeWeapon(weapon)) {
        return;
    }
    void* data = *(void**)((uintptr_t)weapon + off::kWepRangeData);
    if (!SANE_PTR(data)) {
        return;
    }
    ApplyRangeData(data);
    gRangeApplied = true;
}

static void ZeroSpreadRuntime(void* weapon) {
    if (!IsRangeWeapon(weapon)) {
        return;
    }
    float floorValue = SpreadFloorValue();
    *(Vec2*)((uintptr_t)weapon + off::kWepSpread) = Vec2(floorValue, floorValue);
}

static void ZeroRecoilRuntime(void* weapon) {
    if (!IsRangeWeapon(weapon)) {
        return;
    }
    *(Vec3*)((uintptr_t)weapon + off::kWepRecoil) = Vec3(0.0f, 0.0f, 0.0f);
    *(Vec3*)((uintptr_t)weapon + off::kWepOffset) = Vec3(0.0f, 0.0f, 0.0f);
    *(Vec3*)((uintptr_t)weapon + off::kWepJyw) = Vec3(0.0f, 0.0f, 0.0f);
    *(Vec3*)((uintptr_t)weapon + off::kWepJzc) = Vec3(0.0f, 0.0f, 0.0f);
}

static void BallisticsWeaponTick(void* weapon) {
    if (!IsRangeWeapon(weapon)) {
        return;
    }
    
    bool noSpread = NoSpreadActive();
    bool noRecoil = NoRecoilActive();
    if (!noSpread && !noRecoil) {
        return;
    }
    
    if (noSpread) {
        PatchWeaponRangeData(weapon);
        ZeroSpreadRuntime(weapon);
    }
    if (noRecoil) {
        ZeroRecoilRuntime(weapon);
    }
}

static Vec2 gLastGoodCamRot{};
static Vec2 gLastGoodCamAddRot{};
static bool gHaveGoodCamRot = false;

static void BallisticsCameraPre(void* camera) {
    if (!SANE_PTR(camera)) {
        return;
    }
    
    // Cache the last finite orientation. If a NaN ever reaches the camera (bad velocity,
    // bad prediction, bad shot math) every later frame would stay NaN and the game HUD
    // starts printing NaN. Restoring the last good orientation breaks that feedback loop.
    Vec2 rot = *(Vec2*)((uintptr_t)camera + off::kCamRot);
    Vec2 add = *(Vec2*)((uintptr_t)camera + off::kCamAdditionalRot);
    if (std::isfinite(rot.x) && std::isfinite(rot.y) &&
        std::isfinite(add.x) && std::isfinite(add.y)) {
        gLastGoodCamRot = rot;
        gLastGoodCamAddRot = add;
        gHaveGoodCamRot = true;
    }
    
    if (NoRecoilActive()) {
        *(Vec2*)((uintptr_t)camera + off::kCamAdditionalRot) = Vec2(0.0f, 0.0f);
    }
    if (alive(g_localWeapon)) {
        BallisticsWeaponTick(g_localWeapon);
    }
}

static void BallisticsCameraPost(void* camera) {
    if (!SANE_PTR(camera)) {
        return;
    }
    
    Vec2 rot = *(Vec2*)((uintptr_t)camera + off::kCamRot);
    Vec2 add = *(Vec2*)((uintptr_t)camera + off::kCamAdditionalRot);
    if (!std::isfinite(rot.x) || !std::isfinite(rot.y)) {
        if (gHaveGoodCamRot) {
            *(Vec2*)((uintptr_t)camera + off::kCamRot) = gLastGoodCamRot;
        } else {
            *(Vec2*)((uintptr_t)camera + off::kCamRot) = Vec2(0.0f, 0.0f);
        }
    }
    if (!std::isfinite(add.x) || !std::isfinite(add.y)) {
        if (gHaveGoodCamRot) {
            *(Vec2*)((uintptr_t)camera + off::kCamAdditionalRot) = gLastGoodCamAddRot;
        } else {
            *(Vec2*)((uintptr_t)camera + off::kCamAdditionalRot) = Vec2(0.0f, 0.0f);
        }
    }
    
    if (NoRecoilActive()) {
        *(Vec2*)((uintptr_t)camera + off::kCamAdditionalRot) = Vec2(0.0f, 0.0f);
    }
}

static unsigned char gFireCamSnapshot[off::kCamStateSize];
static bool gFireCamSnapshotValid = false;

static void BallisticsFirePre(void) {
    gFireCamSnapshotValid = false;
    if (NoSpreadActive()) {
        gSpreadWindowUntil = NowMs() + 300;
    }
    
    if (!NoRecoilActive()) {
        return;
    }
    if (!SANE_PTR(g_localSceneChar)) {
        return;
    }
    
    memcpy(gFireCamSnapshot,
           (void*)((uintptr_t)g_localSceneChar + off::kCamStateBegin),
           off::kCamStateSize);
    gFireCamSnapshotValid = true;
    
    if (alive(g_localWeapon)) {
        BallisticsWeaponTick(g_localWeapon);
    }
}

static void BallisticsFirePost(void) {
    if (!gFireCamSnapshotValid) {
        return;
    }
    gFireCamSnapshotValid = false;
    
    if (!SANE_PTR(g_localSceneChar)) {
        return;
    }
    
    memcpy((void*)((uintptr_t)g_localSceneChar + off::kCamStateBegin),
           gFireCamSnapshot,
           off::kCamStateSize);
    
    if (alive(g_localWeapon)) {
        BallisticsWeaponTick(g_localWeapon);
    }
}

static void BallisticsTick(void) {
    bool noSpread = NoSpreadActive();
    bool noRecoil = NoRecoilActive();
    
    // Restore the source data as soon as No Spread is off, even if No Recoil is still on.
    if (!noSpread && gRangeApplied.load()) {
        RestoreRangeData();
    }
    
    if (!noSpread && !noRecoil) {
        return;
    }
    
    if (alive(g_localWeapon)) {
        if (noSpread) {
            PatchWeaponRangeData(g_localWeapon);
        }
        if (noSpread) {
            ZeroSpreadRuntime(g_localWeapon);
        }
        if (noRecoil) {
            ZeroRecoilRuntime(g_localWeapon);
        }
    }
    
    // SceneLevelCamera owns rot (0x30) and additionalRot (0x38); recoil kick lands in
    // additionalRot. The Unity Camera component is a separate object (0x48), so the
    // write has to target the SceneLevelCamera instance itself.
    if (noRecoil && SANE_PTR(g_localSceneChar)) {
        *(Vec2*)((uintptr_t)g_localSceneChar + off::kCamAdditionalRot) = Vec2(0.0f, 0.0f);
    }
    
    uint64_t now = NowMs();
    if (gBallisticsDebug.load() && now - gLastBallisticsLog.load() > 2000) {
        gLastBallisticsLog = now;
        if (IsRangeWeapon(g_localWeapon)) {
            void* data = *(void**)((uintptr_t)g_localWeapon + off::kWepRangeData);
            Vec2 sp = *(Vec2*)((uintptr_t)g_localWeapon + off::kWepSpread);
            Vec3 rc = *(Vec3*)((uintptr_t)g_localWeapon + off::kWepRecoil);
            LOG(@"[BALL] spread=(%.4f,%.4f) recoil=(%.4f,%.4f,%.4f) data=%p shoot=(%.4f,%.4f) scale=%.4f",
                sp.x, sp.y, rc.x, rc.y, rc.z, data,
                SANE_PTR(data) ? ((Vec2*)((uintptr_t)data + off::kRangeShootOffset))->x : 0.0f,
                SANE_PTR(data) ? ((Vec2*)((uintptr_t)data + off::kRangeShootOffset))->y : 0.0f,
                SANE_PTR(data) ? *(float*)((uintptr_t)data + off::kRangeRecoilPatternScale) : 0.0f);
        }
    }
}

// =========================================================================================
// BALLISTICS HOOKS
// =========================================================================================

typedef Vec2 (*fn_GetSpreadMultiplier)(void*, void*, void*);
static fn_GetSpreadMultiplier orig_GetSpreadMultiplier = nullptr;

static Vec2 hook_GetSpreadMultiplier(void* self, void* info, void* mi) {
    if (NoSpreadActive()) {
        return Vec2(SpreadFloorValue(), SpreadFloorValue());
    }
    if (orig_GetSpreadMultiplier) {
        return orig_GetSpreadMultiplier(self, info, mi);
    }
    return Vec2(0.0f, 0.0f);
}

typedef void (*fn_UseProcess)(void*, void*, void*);
static fn_UseProcess orig_UseProcess = nullptr;

static void hook_UseProcess(void* self, void* info, void* mi) {
    // UseProcess only runs on a real shot, so it doubles as a fire-held signal when the
    // OnClickFire hooks are missing on this build.
    gFireHeldUntil = NowMs() + 600;
    BallisticsFirePre();
    if (NoSpreadActive()) {
        BallisticsWeaponTick(self);
    }
    
    if (orig_UseProcess) {
        orig_UseProcess(self, info, mi);
    }
    
    if (NoSpreadActive() || NoRecoilActive()) {
        BallisticsWeaponTick(self);
    }
    BallisticsFirePost();
}

typedef bool (*fn_TryUse)(void*, void*, void*);
static fn_TryUse orig_TryUse = nullptr;

static bool hook_TryUse(void* self, void* info, void* mi) {
    // TryUse runs before the shot is built; open the fire window here so the visual
    // aim-on-fire can track the target for the shot that is about to happen.
    gFireHeldUntil = NowMs() + 400;
    if (NoSpreadActive()) {
        gSpreadWindowUntil = NowMs() + 500;
        BallisticsWeaponTick(self);
    } else if (NoRecoilActive()) {
        BallisticsWeaponTick(self);
    }
    
    bool result = false;
    if (orig_TryUse) {
        result = orig_TryUse(self, info, mi);
    }
    
    // The weapon may rebuild Spread/Offset inside TryUse before it builds the ray.
    // Put everything back to zero before the actual shot is processed.
    if (NoSpreadActive() || NoRecoilActive()) {
        BallisticsWeaponTick(self);
    }
    
    return result;
}

// ---------------------------------------------------------------------------------------
// SILENT AIM (best effort)
//
// ItemEquipWeaponRange.fke(from, to, hitsLocal, grounded) is the generated Command that
// ships the shot to the server. fka(from, to) is the local raycast that produces the hit
// list for a direction. When silent aim is on we rebuild the shot toward the selected
// target, recompute the hit list for that direction and only then call the original
// command, so the server receives a self-consistent (from, to, hits) triple instead of a
// direction that contradicts the hit list.
// ---------------------------------------------------------------------------------------

typedef void (*fn_FireBulletCommand)(void*, Vec3, Vec3, void*, bool, void*);
static fn_FireBulletCommand orig_FireBulletCommand = nullptr;
static std::atomic<bool> gFkePatched{false};

typedef void* (*fn_CalcShotHits)(void*, Vec3, Vec3, void*);
static fn_CalcShotHits p_CalcShotHits = nullptr;
static void* p_CalcShotHitsMI = nullptr;

static inline float Vec3Len(const Vec3& v) {
    return sqrtf(v.x * v.x + v.y * v.y + v.z * v.z);
}

static bool BuildSilentAimShot(Vec3 from, Vec3 originalTo, Vec3* outTo, void** outHits, void* weapon) {
    // Aim-on-fire rides the same forged-shot path: the visual LookAtTarget in LateUpdate
    // runs after the weapon already fired, so it can never bend the current bullet.
    // fke is the fire Command itself, so it only runs on a real shot — no need to gate on
    // the OnClickFire hooks (which are missing on some builds and left aim-on-fire dead).
    const bool aimOnFire = gAimOnFireEnabled.load() || gHotAimOnFireEnabled.load();
    if (!outTo || !(gSilentAimEnabled.load() || aimOnFire) || !g_silentAimActive.load() || !g_haveTarget.load()) {
        return false;
    }
    
    uint32_t seq1 = g_silentAimSeq.load(std::memory_order_acquire);
    Vec3 target = g_silentAimTarget;
    uint32_t seq2 = g_silentAimSeq.load(std::memory_order_acquire);
    if (seq1 != seq2 || (seq1 & 1)) {
        return false;
    }
    if (!Math::Finite(target) || !Math::Finite(from) || !Math::Finite(originalTo)) {
        return false;
    }
    
    Vec3 dir = target - from;
    float targetLen = Vec3Len(dir);
    float originalLen = Vec3Len(originalTo - from);
    if (targetLen < 0.05f || targetLen > 400.0f) {
        return false;
    }
    if (originalLen < 0.05f || originalLen > 400.0f) {
        originalLen = targetLen;
    }
    
    // Keep the original travel distance so range/falloff checks still see a plausible shot.
    Vec3 newTo = from + dir * (originalLen / targetLen);
    if (!Math::Finite(newTo)) {
        return false;
    }
    
    *outTo = newTo;
    
    if (outHits) {
        *outHits = nullptr;
        if (p_CalcShotHits && p_CalcShotHitsMI && SANE_PTR(weapon)) {
            void* forged = p_CalcShotHits(weapon, from, newTo, p_CalcShotHitsMI);
            if (forged) {
                *outHits = forged;
            }
        }
    }
    return true;
}

static void hook_FireBulletCommand(void* self, Vec3 from, Vec3 to, void* hits, bool grounded, void* mi) {
    static std::atomic<bool> seen{false};
    if (!seen.exchange(true)) {
        LOG(@"[SA] FireBullet hook reached");
    }
    Vec3 newTo;
    void* newHits = nullptr;
    if (BuildSilentAimShot(from, to, &newTo, &newHits, self)) {
        if (gBallisticsDebug.load()) {
            LOG(@"[SA] forged shot to=(%.2f,%.2f,%.2f) hits=%p", newTo.x, newTo.y, newTo.z, newHits);
        }
        if (orig_FireBulletCommand) {
            orig_FireBulletCommand(self, from, newTo, newHits ? newHits : hits, grounded, mi);
        }
        return;
    }
    
    if (orig_FireBulletCommand) {
        orig_FireBulletCommand(self, from, to, hits, grounded, mi);
    }
}

typedef Vec2 (*fn_GetInsideUnitCircle)(void*);
static fn_GetInsideUnitCircle orig_GetInsideUnitCircle = nullptr;

static Vec2 hook_GetInsideUnitCircle(void* mi) {
    // Only suppress during the fire window: Unity.Random is shared with VFX, grenade
    // physics and UI, so a permanent zero would visibly break unrelated systems.
    if (NoSpreadActive() && NowMs() < gSpreadWindowUntil.load()) {
        return Vec2(0.0f, 0.0f);
    }
    if (orig_GetInsideUnitCircle) {
        return orig_GetInsideUnitCircle(mi);
    }
    return Vec2(0.0f, 0.0f);
}

typedef Vec3 (*fn_GetInsideUnitSphere)(void*);
static fn_GetInsideUnitSphere orig_GetInsideUnitSphere = nullptr;

static Vec3 hook_GetInsideUnitSphere(void* mi) {
    if (NoSpreadActive() && NowMs() < gSpreadWindowUntil.load()) {
        return Vec3(0.0f, 0.0f, 0.0f);
    }
    if (orig_GetInsideUnitSphere) {
        return orig_GetInsideUnitSphere(mi);
    }
    return Vec3(0.0f, 0.0f, 0.0f);
}

static void InstallBallisticsHooks(void) {
    @try {
        void* rangeCls = findClass("", "ItemEquipWeaponRange");
        gRangeClassPtr = rangeCls;
        gShotgunClassPtr = findClass("", "ItemEquipWeaponRangeShotgun");
        LOG(@"[BALL] classes range=%p shotgun=%p", gRangeClassPtr, gShotgunClassPtr);
        if (rangeCls) {
            void* miSpread = p_class_get_method_from_name(rangeCls, "GetSpreadMultiplier", 1);
            if (miSpread) {
                hook_install(miSpread, (void*)hook_GetSpreadMultiplier, (void**)&orig_GetSpreadMultiplier);
                LOG(@"[BALL] GetSpreadMultiplier hook installed");
            }
            
            void* miUse = p_class_get_method_from_name(rangeCls, "UseProcess", 1);
            if (miUse) {
                hook_install(miUse, (void*)hook_UseProcess, (void**)&orig_UseProcess);
                LOG(@"[BALL] UseProcess hook installed");
            }
            
            void* miTry = p_class_get_method_from_name(rangeCls, "TryUse", 1);
            if (miTry) {
                hook_install(miTry, (void*)hook_TryUse, (void**)&orig_TryUse);
                LOG(@"[BALL] TryUse hook installed");
            }
            
            // Silent aim: the generated Command that ships (from, to, hits) to the server.
            void* miCmd = p_class_get_method_from_name(rangeCls, "fke", 4);
            if (miCmd) {
                if (hook_install(miCmd, (void*)hook_FireBulletCommand, (void**)&orig_FireBulletCommand)) {
                    LOG(@"[BALL] FireBullet command hook installed");
                }
            } else {
                LOG(@"[BALL] fke not found, silent aim disabled");
            }

            // fkb tail-calls fke with a plain `b`, so the MethodInfo patch above never sees
            // the real shot. Patch that branch too; the RVAs are for this UnityFramework build.
            uintptr_t ufBase = UnityFrameworkBase();
            if (ufBase) {
                uintptr_t fkeAddr = ufBase + 0x19D8624;
                uintptr_t callSite = ufBase + 0x19D710C;
                // Only trust the hardcoded RVAs when the call site still branches to the
                // expected fke address. A game update shifts these, and patching a random
                // instruction (or calling a wrong orig pointer) aborts the process.
                if (BranchTargets(callSite, fkeAddr)) {
                    int64_t delta = (int64_t)(uintptr_t)hook_FireBulletCommand - (int64_t)callSite;
                    if (PatchBranchFar(callSite, (uintptr_t)hook_FireBulletCommand)) {
                        // The MethodInfo hook above may already have captured the original
                        // pointer; only fill it in when that hook was not installed.
                        if (!orig_FireBulletCommand) {
                            orig_FireBulletCommand = (fn_FireBulletCommand)fkeAddr;
                        }
                        gFkePatched = true;
                        LOG(@"[BALL] fke call-site patched base=%p delta=%lld", (void*)ufBase, (long long)delta);
                    } else {
                        LOG(@"[BALL] fke call-site patch failed base=%p delta=%lld", (void*)ufBase, (long long)delta);
                    }
                } else {
                    LOG(@"[BALL] fke call-site mismatch, native patch skipped base=%p", (void*)ufBase);
                }
            } else {
                LOG(@"[BALL] UnityFramework base not found");
            }
            
            // Local raycast used to rebuild the hit list for the silent-aim direction.
            void* miCalc = p_class_get_method_from_name(rangeCls, "fka", 2);
            if (miCalc) {
                p_CalcShotHitsMI = miCalc;
                p_CalcShotHits = (fn_CalcShotHits)methodPtr(miCalc);
                LOG(@"[BALL] shot hit-calc resolved");
            }
        }
        
        void* randomCls = findClass("UnityEngine", "Random");
        if (randomCls) {
            void* miCircle = p_class_get_method_from_name(randomCls, "get_insideUnitCircle", 0);
            if (miCircle) {
                hook_install(miCircle, (void*)hook_GetInsideUnitCircle, (void**)&orig_GetInsideUnitCircle);
                LOG(@"[BALL] insideUnitCircle hook installed");
            }
            void* miSphere = p_class_get_method_from_name(randomCls, "get_insideUnitSphere", 0);
            if (miSphere) {
                hook_install(miSphere, (void*)hook_GetInsideUnitSphere, (void**)&orig_GetInsideUnitSphere);
                LOG(@"[BALL] insideUnitSphere hook installed");
            }
        }
    } @catch (NSException* e) {
        LOG(@"[BALL] hooks: %@", SafeStr([e reason]));
    }
}

// =========================================================================================
// RAGE CORE
//
// Everything in this block answers one question: "given the player list, who should the
// weapon be pointed at, and is this frame the right moment to fire?"
//
// Order matches runtime:
//   1. helpers          - distance, damage, spread, hitchance
//   2. target selection - RagePickTarget
//   3. aim              - RageAimAt
//   4. fire gate        - RageCanFire / RageFire / RageReleaseTrigger
//   5. anti-aim         - RageAntiAimTick
//   6. bookkeeping      - RageUpdateStats / RageNoteHit / RagePruneStats
//   7. entry point      - RageTick
//
// Rules kept from the rest of the file:
//   - no view angle is ever written: aiming goes through SceneLevelCamera.LookAtTarget
//   - every pointer goes through alive() before it is dereferenced
//   - every float from the game goes through Math::Finite
// =========================================================================================

// -----------------------------------------------------------------------------------------
// 1. helpers
// -----------------------------------------------------------------------------------------

static inline float RageDist(const Vec3& a, const Vec3& b) {
    float dx = b.x - a.x;
    float dy = b.y - a.y;
    float dz = b.z - a.z;
    float d = sqrtf(dx*dx + dy*dy + dz*dz);
    if (!std::isfinite(d)) {
        return 0.0f;
    }
    return d;
}

static inline float RageDistSq(const Vec3& a, const Vec3& b) {
    float dx = b.x - a.x;
    float dy = b.y - a.y;
    float dz = b.z - a.z;
    float d = dx*dx + dy*dy + dz*dz;
    if (!std::isfinite(d)) {
        return 0.0f;
    }
    return d;
}

// Advertised damage of the weapon, straight off WeaponDataRange.
static int RageWeaponDamage(void* weapon) {
    if (!alive(weapon)) {
        return 0;
    }
    void* data = *(void**)((uintptr_t)weapon + off::kWepRangeData);
    if (!alive(data)) {
        return 0;
    }
    int dmg = *(int*)((uintptr_t)data + off::kWdrDamage);
    if (dmg <= 0 || dmg > 1000) {
        return 0;
    }
    float mul = *(float*)((uintptr_t)data + off::kWdrHeadshotMul);
    if (!std::isfinite(mul) || mul < 1.0f || mul > 10.0f) {
        mul = 1.0f;
    }
    return (int)(dmg * mul);
}

// Pellets per trigger pull. A shotgun fires several projectiles, so effective damage is
// per-pellet times pellet count.
static int RagePelletCount(void* weapon) {
    if (!alive(weapon)) {
        return 1;
    }
    void* data = *(void**)((uintptr_t)weapon + off::kWepRangeData);
    if (!alive(data)) {
        return 1;
    }
    int pellets = *(int*)((uintptr_t)data + off::kWdrPelletCount);
    if (pellets <= 0 || pellets > 32) {
        return 1;
    }
    return pellets;
}

// Total damage a single trigger pull is worth right now.
static int RageShotDamage(void* weapon) {
    int base = RageWeaponDamage(weapon);
    if (base <= 0) {
        return 0;
    }
    return base * RagePelletCount(weapon);
}

// Current spread magnitude, from the live <Spread> backing field.
static float RageSpreadNow(void* weapon) {
    if (!alive(weapon)) {
        return 0.0f;
    }
    Vec2 sp = *(Vec2*)((uintptr_t)weapon + off::kWepSpread);
    if (!Math::Finite(sp.x) || !Math::Finite(sp.y)) {
        return 0.0f;
    }
    float m = sqrtf(sp.x * sp.x + sp.y * sp.y);
    if (!std::isfinite(m)) {
        return 0.0f;
    }
    return m;
}

// Hitchance model.
//
// The game rolls a random point inside a unit circle of radius = spread. The shot lands if
// the target's angular half-size at this distance is at least the spread radius, so:
//
//     chance = atan(targetRadius / distance) / spread
//
// Conservative by construction: never above 100 %, never 0 % for a target under the
// crosshair.
static int RageHitchance(void* weapon, float distance, bool headshot) {
    int cfg = gRageHitchance.load();
    if (cfg <= 0) {
        return 100;
    }
    float spread = RageSpreadNow(weapon);
    if (spread <= 0.00001f) {
        return 100;
    }
    if (!std::isfinite(distance) || distance <= 0.01f) {
        return 100;
    }

    // Standing player: ~0.45 m across the chest, ~0.22 m across the head.
    float targetRadius = headshot ? 0.22f : 0.45f;
    float angular = atanf((targetRadius * 0.5f) / distance);
    if (!std::isfinite(angular) || angular <= 0.0f) {
        return 0;
    }

    float chance = (angular / spread) * 100.0f;
    if (!std::isfinite(chance) || chance <= 0.0f) {
        return 0;
    }
    if (chance > 100.0f) {
        chance = 100.0f;
    }

    // Session accuracy nudges the estimate, gently. Ten shots minimum before it applies.
    int shots = gRageShotSerial.load();
    int hits = gRageHitSerial.load();
    if (shots >= 10 && shots < 500) {
        float observed = (float)hits / (float)shots * 100.0f;
        chance = chance * 0.75f + observed * 0.25f;
    }

    return (int)chance;
}

// -----------------------------------------------------------------------------------------
// 2. target selection
// -----------------------------------------------------------------------------------------

// Resolve the aim point for a player, honouring the point selector.
//
//   rg_pt 0 -> head
//   rg_pt 1 -> chest
//   rg_pt 2 -> pelvis
//   rg_pt 3 -> bone nearest the crosshair
//
// Falls back to the head transform whenever the requested bone is missing, so a
// half-loaded character never leaves the aim point at the origin.
static bool RageAimPoint(void* playerChar, Vec3& outAimPos, bool& outHeadshot) {
    outAimPos = Vec3{0.0f, 0.0f, 0.0f};
    outHeadshot = false;
    if (!alive(playerChar)) {
        return false;
    }

    void* modelContainer = *(void**)((uintptr_t)playerChar + off::kCharModelContainer);
    if (!alive(modelContainer)) {
        return false;
    }

    Vec3 feet;
    if (!getPosFast(modelContainer, feet) || !Math::Finite(feet)) {
        return false;
    }

    void* ctrl = *(void**)((uintptr_t)playerChar + off::kCharController);
    void* model = nullptr;
    Vec3 headPos = feet;

    if (alive(ctrl)) {
        void* rv = *(void**)((uintptr_t)ctrl + off::kOtherRemoteVis);
        if (alive(rv)) {
            model = *(void**)((uintptr_t)rv + off::kRvModel);
            if (alive(model)) {
                void* ht = *(void**)((uintptr_t)model + off::kModelHead);
                if (alive(ht)) {
                    Vec3 h;
                    if (getPosFast(ht, h) && Math::Finite(h)) {
                        headPos = h;
                    }
                }
            }
        }
    }

    // A head below the feet means a stale transform; fall back to standing height.
    if (headPos.y <= feet.y) {
        headPos.y = feet.y + 1.62f;
    }

    Vec3 chest = headPos;  chest.y  -= 0.28f;
    Vec3 pelvis = headPos; pelvis.y -= 0.72f;

    int point = gRagePoint.load();
    if (gRageForceBaim.load()) {
        point = 1;
    }

    Vec3 chosen = headPos;
    bool headshot = true;

    if (point == 1) {
        chosen = chest; headshot = false;
    } else if (point == 2) {
        chosen = pelvis; headshot = false;
    } else if (point == 3 && alive(model) && p_getBoneTransform) {
        // Nearest-to-crosshair, approximated with nearest-to-eye. The camera basis is not
        // needed for a choice this coarse, and it saves a transform per bone.
        void* animator = *(void**)((uintptr_t)model + off::kModelAnimator);
        if (alive(animator)) {
            int bones[] = {0,7,8,9,10,11,12,13,14,15,16,17,18,1,2,3,4,5,6};
            float bestD = 1e9f;
            for (int i = 0; i < 19; i++) {
                void* bt = p_getBoneTransform(animator, bones[i], p_getBoneTransformMI);
                if (!alive(bt)) {
                    continue;
                }
                Vec3 bp;
                if (!getPosFast(bt, bp) || !Math::Finite(bp)) {
                    continue;
                }
                float d = RageDistSq(bp, g_localEye);
                if (d > 0.0f && d < bestD) {
                    bestD = d;
                    chosen = bp;
                    headshot = (bones[i] == 10);
                }
            }
        }
    }

    outAimPos = chosen;
    outHeadshot = headshot;
    return Math::Finite(chosen);
}

// Score a player for the priority selector. Lower is better.
//
//   0 distance   - closest first
//   1 lowest hp  - closest to dying first
//   2 crosshair  - smallest screen distance to the crosshair
//   3 threat     - close, weighted by how much health they still have
static float RageScore(void* playerChar, float distance, const Vec3& aimPos, bool visible) {
    int prio = gRagePriority.load();

    if (prio == 1) {
        int hp = *(int*)((uintptr_t)playerChar + off::kCharHealth);
        int armor = *(int*)((uintptr_t)playerChar + off::kCharArmor);
        int effective = (hp > 0 ? hp : 0) + (armor > 0 ? armor : 0);
        if (!visible) {
            effective += 500;
        }
        return (float)effective;
    }

    if (prio == 2) {
        if (!alive(g_localCamera)) {
            return distance;
        }
        Vec3 sp;
        if (!w2sFast(g_localCamera, aimPos, sp) || sp.z <= 0.05f) {
            return 99999.0f;
        }
        float cx = gScreenPts.width * 0.5f;
        float cy = gScreenPts.height * 0.5f;
        float dx = sp.x - cx;
        float dy = sp.y - cy;
        return sqrtf(dx*dx + dy*dy);
    }

    if (prio == 3) {
        int hp = *(int*)((uintptr_t)playerChar + off::kCharHealth);
        if (hp <= 0) {
            hp = 1;
        }
        float threat = distance * (1.0f + (float)hp / 100.0f);
        if (!visible) {
            threat += 200.0f;
        }
        return threat;
    }

    return visible ? distance : (distance + 1000.0f);
}

// Pick the player to work on this frame. Returns the player pointer, or nullptr.
static void* RagePickTarget(void* cam, bool& outVisible, Vec3& outAimPos, bool& outHeadshot,
                            float& outDistance, int& outDamage) {
    outVisible = false;
    outAimPos = Vec3{0.0f, 0.0f, 0.0f};
    outHeadshot = false;
    outDistance = 0.0f;
    outDamage = 0;

    if (!alive(cam) || gCached.empty()) {
        return nullptr;
    }

    float maxRange = gRageMaxRange.load();
    if (!std::isfinite(maxRange) || maxRange < 10.0f) {
        maxRange = 300.0f;
    }

    float fov = gRageFovPx.load();
    if (!std::isfinite(fov) || fov < 20.0f) {
        fov = 600.0f;
    }

    void* best = nullptr;
    float bestScore = 1e9f;
    bool bestVisible = false;
    Vec3 bestAim = Vec3{0.0f, 0.0f, 0.0f};
    bool bestHead = false;
    float bestDist = 0.0f;
    int bestDamage = 0;

    uint64_t now = NowMs();

    // Snapshot the lock start before the loop: gRageTargetSince is only rewritten after the
    // winner is known, so reading it inside the loop would compare the held target against
    // last frame's value and let a fresh lock flip-flop for one frame.
    uint64_t lockSince = gRageTargetSince.load();
    if (lockSince == 0) {
        lockSince = now;
    }

    for (void* p : gCached) {
        if (!alive(p) || p == gLocal) {
            continue;
        }
        if (*(bool*)((uintptr_t)p + off::kPlayerIsDead)) {
            continue;
        }

        int team = *(int*)((uintptr_t)p + off::kPlayerTeam);
        if (gRageTeamCheck.load() && gTeam >= 0 && team == gTeam) {
            continue;
        }

        void* c = *(void**)((uintptr_t)p + off::kPlayerCharacter);
        if (!alive(c)) {
            continue;
        }
        if (*(bool*)((uintptr_t)c + off::kCharIsDead)) {
            continue;
        }

        Vec3 aimPos;
        bool headshot = false;
        if (!RageAimPoint(c, aimPos, headshot) || !Math::Finite(aimPos)) {
            continue;
        }

        float dist = RageDist(g_localEye, aimPos);
        if (!std::isfinite(dist) || dist > maxRange) {
            continue;
        }

        // Cone check in screen space: "within N pixels of the crosshair", resolution-free.
        Vec3 sp;
        if (!w2sFast(cam, aimPos, sp) || sp.z <= 0.05f) {
            continue;
        }
        float cx = gScreenPts.width * 0.5f;
        float cy = gScreenPts.height * 0.5f;
        float dx = sp.x - cx;
        float dy = sp.y - cy;
        float screenDist = sqrtf(dx*dx + dy*dy);

        // A strafing target gets a slightly wider effective cone when the expander is on.
        float effectiveFov = fov;
        if (gRageHitboxExpand.load()) {
            void* cc = *(void**)((uintptr_t)c + off::kCharController);
            if (alive(cc)) {
                Vec3 vel = *(Vec3*)((uintptr_t)cc + off::kMoveVelocity);
                if (Math::Finite(vel)) {
                    float speed = sqrtf(vel.x*vel.x + vel.z*vel.z);
                    if (speed > 1.0f) {
                        effectiveFov += gRageHitboxExpandPx.load();
                    }
                }
            }
        }

        if (!std::isfinite(screenDist) || screenDist > effectiveFov) {
            continue;
        }

        bool visible = true;
        // Smoke bypass: inside 25 m a failed line-of-sight test is usually a smoke puff
        // sitting between the camera and the target rather than a real occluder, so the
        // target is treated as visible there. Outside that range the test still decides.
        bool smokeRelaxed = gRageBypassSmoke.load() && dist <= 25.0f;
        if (gRageVisibleOnly.load() && !smokeRelaxed && p_CheckSeen && alive(g_localSceneChar)) {
            if (!p_CheckSeen(g_localSceneChar, aimPos, p_checkSeenMI)) {
                visible = false;
            }
        }

        float score = RageScore(c, dist, aimPos, visible);

        // Switch-delay gate: hold the current target briefly so the crosshair does not
        // snap between two enemies in the same frame.
        void* held = gRageTarget.load();
        if (held && held == p && now - lockSince < (uint64_t)gRageSwitchDelay.load()) {
            score -= 50.0f;
        }

        if (score < bestScore) {
            bestScore = score;
            best = p;
            bestAim = aimPos;
            bestHead = headshot;
            bestDist = dist;
            bestVisible = visible;
            bestDamage = RageShotDamage(g_localWeapon);
        }
    }

    if (best) {
        if (gRageTarget.load() != best) {
            gRageTargetSince = now;
            gRageLastTargetMs = now;
        }

        // "Ignore mates in cone": off means a teammate standing nearer the crosshair than the
        // chosen enemy suppresses the shot, so a spray cannot be sent through a mate's back.
        // On means teammates never factor in, which is the default for a rage build.
        if (!gRageIgnoreTeammatesInFov.load() && gTeam >= 0 && alive(best)) {
            float cx = gScreenPts.width * 0.5f;
            float cy = gScreenPts.height * 0.5f;

            Vec3 bestSp;
            float bestScreen = 1e9f;
            if (w2sFast(cam, bestAim, bestSp) && bestSp.z > 0.05f) {
                float dx = bestSp.x - cx;
                float dy = bestSp.y - cy;
                bestScreen = sqrtf(dx*dx + dy*dy);
            }

            if (bestScreen < 1e8f) {
                for (void* mate : gCached) {
                    if (!alive(mate) || mate == best || mate == gLocal) {
                        continue;
                    }
                    if (*(bool*)((uintptr_t)mate + off::kPlayerIsDead)) {
                        continue;
                    }
                    if (*(int*)((uintptr_t)mate + off::kPlayerTeam) != gTeam) {
                        continue;
                    }
                    void* mc = *(void**)((uintptr_t)mate + off::kPlayerCharacter);
                    if (!alive(mc)) {
                        continue;
                    }
                    void* mmc = *(void**)((uintptr_t)mc + off::kCharModelContainer);
                    if (!alive(mmc)) {
                        continue;
                    }
                    Vec3 mpos;
                    if (!getPosFast(mmc, mpos) || !Math::Finite(mpos)) {
                        continue;
                    }
                    Vec3 msp;
                    if (!w2sFast(cam, mpos, msp) || msp.z <= 0.05f) {
                        continue;
                    }
                    float mdx = msp.x - cx;
                    float mdy = msp.y - cy;
                    float mateScreen = sqrtf(mdx*mdx + mdy*mdy);
                    if (mateScreen < bestScreen) {
                        // A mate is in front of the target: hold fire this frame.
                        best = nullptr;
                        break;
                    }
                }
            }
        }

        if (best) {
            gRageTarget = best;
        }
    } else if (now - lockSince > 1000) {
        // Nothing for a full second: drop the lock so the next pick starts clean.
        gRageTarget = nullptr;
    }

    outVisible = bestVisible;
    outAimPos = bestAim;
    outHeadshot = bestHead;
    outDistance = bestDist;
    outDamage = bestDamage;
    return best;
}

// -----------------------------------------------------------------------------------------
// 3. aim
// -----------------------------------------------------------------------------------------

// Point the local scene camera at a world position.
//
// Goes through SceneLevelCamera.LookAtTarget, the same entry the game's own aim assist
// uses, so no view angle is ever written into memory by hand.
static void RageAimAt(const Vec3& aimPos) {
    if (!p_lookAtTarget || !alive(g_localSceneChar) || !Math::Finite(aimPos)) {
        return;
    }

    // IsBusy / IsDisable live on SceneLevelCamera (0x60 / 0x61). g_localCamera is the
    // UnityEngine.Camera component, so reading those offsets there returned garbage and
    // silently aborted the rage aim on most frames.
    if (!alive(g_localSceneChar)) {
        return;
    }
    if (*(bool*)((uintptr_t)g_localSceneChar + off::kCamIsDisable) ||
        *(bool*)((uintptr_t)g_localSceneChar + off::kCamIsBusy)) {
        return;
    }

    Vec3 target = aimPos;
    float s = gRageSmooth.load();
    if (!std::isfinite(s) || s < 0.0f) {
        s = 0.0f;
    }
    if (s > 0.98f) {
        s = 0.98f;
    }

    if (s > 0.0f) {
        if (!Math::Finite(g_smoothTarget)) {
            g_smoothTarget = target;
        }
        Vec3 diff = target - g_smoothTarget;
        g_smoothTarget = g_smoothTarget + diff * (1.0f - s);
        target = g_smoothTarget;
    } else {
        g_smoothTarget = target;
    }

    // Aim step: advance only a slice per frame, turning a hard snap into a visible sweep.
    float step = gRageAimStep.load();
    if (std::isfinite(step) && step > 0.0f) {
        int steps = (int)step;
        if (steps < 1) {
            steps = 1;
        }
        if (steps > 32) {
            steps = 32;
        }
        if (!g_smoothAimCursorValid || !Math::Finite(g_smoothAimCursor)) {
            g_smoothAimCursor = target;
            g_smoothAimCursorValid = true;
        }
        Vec3 from = g_smoothAimCursor;
        g_smoothAimCursor = from + (target - from) * (1.0f / (float)steps);
        target = g_smoothAimCursor;
    } else {
        g_smoothAimCursor = target;
        g_smoothAimCursorValid = true;
    }

    if (!Math::Finite(target)) {
        return;
    }

    p_lookAtTarget(g_localSceneChar, target, p_lookAtTargetMI);
    gRageLastTargetMs = NowMs();
}

// -----------------------------------------------------------------------------------------
// 4. fire gate
// -----------------------------------------------------------------------------------------

static bool RageWeaponReady() {
    if (!alive(g_localWeapon)) {
        return false;
    }
    if (*(bool*)((uintptr_t)g_localWeapon + off::kWepIsReload)) {
        return false;
    }
    int ammo = *(int*)((uintptr_t)g_localWeapon + off::kWepAmmo);
    if (ammo <= 0) {
        return false;
    }
    return true;
}

static bool RageCanFire(bool visible, float distance, int damage, bool headshot, void*& outTarget) {
    outTarget = nullptr;

    if (!gRageAutoFire.load()) {
        return false;
    }
    if (gRageOnKey.load() && !gRageTriggerHeld.load()) {
        return false;
    }
    if (!RageWeaponReady()) {
        return false;
    }

    uint64_t now = NowMs();
    if (gRageBurst.load()) {
        if (gRageBurstLeft.load() <= 0 && now < gRageBurstNextMs.load()) {
            return false;
        }
    } else {
        uint64_t since = now - gRageLastFireMs.load();
        uint64_t need = (uint64_t)(gRageFireDelay.load() + gRageSlowAim.load());
        if (since < need) {
            return false;
        }
    }

    if (gRageVisibleOnly.load() && !visible) {
        return false;
    }

    float maxRange = gRageMaxRange.load();
    if (!std::isfinite(maxRange) || maxRange < 10.0f) {
        maxRange = 300.0f;
    }
    if (distance > maxRange) {
        return false;
    }

    // Melee / Zeus class: only pull the trigger when the target is actually in reach.
    if (!RageMeleeGuard(distance)) {
        return false;
    }

    int need = gRageMinDamage.load();
    if (need > 1) {
        int effective = damage > 0 ? damage : RageShotDamage(g_localWeapon);
        if (effective < need) {
            return false;
        }
    }

    int hc = RageHitchance(g_localWeapon, distance, headshot);
    if (hc > 0 && hc < gRageHitchance.load()) {
        return false;
    }

    // Air-stuck: only fire while grounded, so a jump cannot waste the shot.
    if (gRageAirStuck.load() && alive(g_localCC)) {
        if (!*(bool*)((uintptr_t)g_localCC + off::kMoveIsGrounded)) {
            return false;
        }
    }

    outTarget = gRageTarget.load();
    return alive(outTarget);
}

// Pull the trigger through the real mobile-input path.
//
// Reuses TriggerbotFireDown/Up so there is exactly one place that knows how to synthesise
// a fire event, and one place to fix if the mobile input class changes.
static void RageFire() {
    if (!RageWeaponReady() || gRageTriggerHeld.load()) {
        return;
    }

    TriggerbotFireDown();
    gRageTriggerHeld = true;
    gRageLastFireMs = NowMs();
    gRageShotSerial = gRageShotSerial.load() + 1;

    if (gRageBurst.load()) {
        int left = gRageBurstLeft.load();
        if (left <= 0) {
            left = gRageBurstCount.load();
        }
        left -= 1;
        gRageBurstLeft = left;
        if (left <= 0) {
            gRageBurstNextMs = NowMs() + (uint64_t)gRageBurstPause.load();
        }
    }

    if (gRageLogShots.load()) {
        RageLogEntry e;
        memset(&e, 0, sizeof(e));

        void* t = gRageTarget.load();
        if (alive(t)) {
            void* ni = *(void**)((uintptr_t)t + off::kPlayerNickName);
            NSString* nick = getIL2CPPString(ni);
            if (nick && nick.length > 0) {
                strncpy(e.target, [nick UTF8String], sizeof(e.target) - 1);
            } else {
                strncpy(e.target, "?", sizeof(e.target) - 1);
            }
        } else {
            strncpy(e.target, "-", sizeof(e.target) - 1);
        }

        e.distance = 0.0f;
        e.damage = RageShotDamage(g_localWeapon);
        e.hit = false;
        e.atMs = NowMs();

        int maxEntries = gRageLogMax.load();
        if (maxEntries < 4) {
            maxEntries = 4;
        }
        if (maxEntries > 64) {
            maxEntries = 64;
        }
        if ((int)gRageLog.size() >= maxEntries) {
            gRageLog.erase(gRageLog.begin());
        }
        gRageLog.push_back(e);
        gRageLastLogMs = NowMs();

        if (gRageDebug.load()) {
            LOG(@"[RAGE] fire -> %s dist=%.1f dmg=%d", e.target, e.distance, e.damage);
        }
    }
}

static void RageReleaseTrigger() {
    if (!gRageTriggerHeld.load()) {
        return;
    }
    TriggerbotFireUp();
    gRageTriggerHeld = false;
    if (gRageBurst.load() && gRageBurstLeft.load() <= 0) {
        gRageBurstNextMs = NowMs() + (uint64_t)gRageBurstPause.load();
    }
}

// -----------------------------------------------------------------------------------------
// 4b. weapon service (reload / swap / scope)
//
// Everything here goes through the weapon's own public methods via runtime_invoke, so the
// game's state machine still owns the reload, the animation and the ammo bookkeeping. No
// ammo/reload flag is ever poked by hand.
// -----------------------------------------------------------------------------------------

// Invoke a zero/one-arg instance method resolved lazily from the live object's class.
static void* RageInvoke(void* instance, const char* name, int argc, void** args) {
    if (!p_runtime_invoke || !p_class_get_method_from_name || !alive(instance)) {
        return nullptr;
    }
    void* klass = *(void**)instance;
    if (!SANE_PTR(klass)) {
        return nullptr;
    }
    void* mi = p_class_get_method_from_name(klass, name, argc);
    if (!mi) {
        return nullptr;
    }
    void* exc = nullptr;
    return p_runtime_invoke(mi, instance, args, &exc);
}

// Ask the equipped weapon to reload through ItemEquipWeaponRange.Reload().
// Falls back to RequestReload() (the [Command] wrapper) on builds where Reload is hidden.
static void TriggerRageReload() {
    if (!alive(g_localWeapon)) {
        return;
    }

    void* klass = *(void**)g_localWeapon;
    if (!SANE_PTR(klass)) {
        return;
    }

    void* mi = p_class_get_method_from_name(klass, "Reload", 0);
    if (!mi) {
        mi = p_class_get_method_from_name(klass, "RequestReload", 0);
    }
    if (!mi) {
        if (gRageDebug.load()) {
            LOG(@"[RAGE] reload: no Reload()/RequestReload() on weapon class");
        }
        return;
    }

    void* exc = nullptr;
    p_runtime_invoke(mi, g_localWeapon, nullptr, &exc);

    if (gRageDebug.load()) {
        LOG(@"[RAGE] reload requested (exc=%p)", exc);
    }
}

// Swap to another inventory slot.
//
// slot 1 is the sidearm on the standard two-slot rig. The character resolves the slot to an
// Item (SceneLevelCharacter.GetItemBySlot), we take its DataId and hand that to
// SceneLevelCharacterController.EquipItem(string), which is the same path the weapon wheel
// uses.
static void TriggerRageSwitchWeapon(int slot) {
    if (!alive(g_localChar)) {
        return;
    }

    void* item = nullptr;
    {
        int s = slot;
        void* args[1] = {&s};
        item = RageInvoke(g_localChar, "GetItemBySlot", 1, args);
    }
    if (!alive(item)) {
        if (gRageDebug.load()) {
            LOG(@"[RAGE] switch weapon: slot %d empty", slot);
        }
        return;
    }

    void* dataId = *(void**)((uintptr_t)item + off::kItemDataId);
    if (!SANE_PTR(dataId)) {
        return;
    }

    void* ctrl = *(void**)((uintptr_t)g_localChar + off::kCharController);
    if (!alive(ctrl)) {
        return;
    }

    void* args[1] = {&dataId};
    void* exc = nullptr;
    void* klass = *(void**)ctrl;
    void* mi = p_class_get_method_from_name(klass, "EquipItem", 1);
    if (mi) {
        p_runtime_invoke(mi, ctrl, args, &exc);
    } else {
        mi = p_class_get_method_from_name(klass, "RefreshEquip", 0);
        if (mi) {
            p_runtime_invoke(mi, ctrl, nullptr, &exc);
        }
    }

    if (gRageDebug.load()) {
        LOG(@"[RAGE] switch weapon -> slot %d (exc=%p)", slot, exc);
    }
}

// Force the scope in before a shot when auto-scope is on.
//
// SetAimingState(bool) is the same entry the fire button uses, so the ADS animation, the
// FOV change and the spread reduction all come from the game.
static void RageAutoScopeTick() {
    if (!gRageAutoScope.load() || !alive(g_localWeapon) || !gRageEnabled.load()) {
        return;
    }
    if (*(bool*)((uintptr_t)g_localWeapon + off::kWepIsAiming)) {
        return;
    }
    if (!gRageAutoFire.load()) {
        return;
    }
    if (gRageOnKey.load() && !gRageTriggerHeld.load() && !gRageAutoAim.load()) {
        return;
    }

    // SetAimingState(bool) takes the value by pointer, exactly like runtime_invoke wants it.
    static bool scopeOn = true;
    void* scopeArgs[1] = {&scopeOn};
    RageInvoke(g_localWeapon, "SetAimingState", 1, scopeArgs);
}

// Zeus / knife class weapons only connect at hugging range. Refuse the shot past that so the
// auto-fire path does not burn a charge on a target it cannot reach.
static bool RageMeleeGuard(float distance) {
    if (!gRageAutoZeus.load()) {
        return true;
    }
    if (IsRangeWeapon(g_localWeapon)) {
        return true;
    }
    return distance <= 3.0f;
}

// -----------------------------------------------------------------------------------------
// 5. anti-aim
// -----------------------------------------------------------------------------------------

// Rotate the local camera state so the player model faces away, while the view stays where
// the player is actually looking.
//
// Writes SceneLevelCamera::additionalRot (0x38): the same field the recoil kick lands in, so
// the write is a bounded 8-byte window on the camera rather than a blind poke. The player's
// real look angle (rot, 0x30) is left alone on purpose: anti-aim only needs to move the
// rendered muzzle/hands, and leaving rot intact keeps the aim pipeline (which goes through
// LookAtTarget) authoritative.
static void RageAntiAimTick() {
    // Always release the offset first, so toggling anti-aim off mid-match restores the view.
    static Vec2 lastWritten = Vec2(0.0f, 0.0f);

    if (!gRageAntiAim.load() || !alive(g_localCamera)) {
        if (lastWritten.x != 0.0f || lastWritten.y != 0.0f) {
            *(Vec2*)((uintptr_t)g_localCamera + off::kCamRotOffset) = Vec2(0.0f, 0.0f);
            lastWritten = Vec2(0.0f, 0.0f);
        }
        return;
    }

    if (*(bool*)((uintptr_t)g_localCamera + off::kCamIsBusy) ||
        *(bool*)((uintptr_t)g_localCamera + off::kCamIsDisable)) {
        return;
    }

    int mode = gRageAntiAimMode.load();
    if (mode < 0 || mode > 3) {
        mode = 0;
    }

    float yaw = gRageAntiAimYaw.load();
    float pitch = gRageAntiAimPitch.load();
    if (!std::isfinite(yaw)) {
        yaw = 180.0f;
    }
    if (!std::isfinite(pitch)) {
        pitch = -89.0f;
    }

    uint64_t now = NowMs();

    switch (mode) {
        case 1: {
            // Spin: yaw advances at a fixed rate and wraps at 360.
            float spin = gRageAntiAimSpin.load();
            if (!std::isfinite(spin) || spin <= 0.0f) {
                spin = 720.0f;
            }
            static uint64_t spinStart = 0;
            if (spinStart == 0) {
                spinStart = now;
            }
            float dt = (float)(now - spinStart) / 1000.0f;
            float a = fmodf(dt * spin, 360.0f);
            if (a < 0.0f) {
                a += 360.0f;
            }
            yaw = a > 180.0f ? a - 360.0f : a;
            break;
        }
        case 2: {
            // Jitter: flip between +offset and -offset every frame.
            static bool flip = false;
            flip = !flip;
            yaw = flip ? yaw : -yaw;
            pitch = flip ? pitch : -pitch * 0.5f;
            break;
        }
        case 3: {
            // Back and forth: triangle wave across the configured yaw.
            static uint64_t t0 = 0;
            if (t0 == 0) {
                t0 = now;
            }
            float dt = (float)(now - t0) / 1000.0f;
            float period = 1.2f;
            float phase = fmodf(dt / period, 2.0f);
            float tri = phase < 1.0f ? phase : 2.0f - phase;
            yaw = (tri * 2.0f - 1.0f) * yaw;
            break;
        }
        default:
            // Static: use the configured offsets verbatim.
            break;
    }

    if (gRageAntiAimJitter.load() && mode != 2) {
        yaw += ((float)(arc4random_uniform(41)) / 10.0f - 2.0f);
    }

    if (!std::isfinite(yaw) || !std::isfinite(pitch)) {
        return;
    }
    if (yaw > 180.0f)  yaw = 180.0f;
    if (yaw < -180.0f) yaw = -180.0f;
    if (pitch > 89.0f)  pitch = 89.0f;
    if (pitch < -89.0f) pitch = -89.0f;

    // Only write when the value actually changes, so a static anti-aim does not cause a
    // dirty-frame storm.
    Vec2 want = Vec2(yaw, pitch);
    if (fabsf(want.x - lastWritten.x) < 0.01f && fabsf(want.y - lastWritten.y) < 0.01f) {
        return;
    }

    *(Vec2*)((uintptr_t)g_localCamera + off::kCamRotOffset) = want;
    lastWritten = want;
}

// -----------------------------------------------------------------------------------------
// 6. per-target bookkeeping
// -----------------------------------------------------------------------------------------

static void RageUpdateStats(void* player, void* playerChar, float distance, bool visible) {
    if (!gRagePerTargetStats.load() || !alive(player) || !alive(playerChar)) {
        return;
    }

    RageTargetStat& s = gRageStats[player];
    uint64_t now = NowMs();
    if (s.firstSeenMs == 0) {
        s.firstSeenMs = now;
    }
    s.lastSeenMs = now;
    s.lastDistance = distance;
    s.lastHealth = *(int*)((uintptr_t)playerChar + off::kCharHealth);
    s.lastArmor = *(int*)((uintptr_t)playerChar + off::kCharArmor);
    s.visible = visible;
}

// Drop stat rows for players that left the cache.
static void RagePruneStats() {
    if (gRageStats.empty()) {
        return;
    }
    for (auto it = gRageStats.begin(); it != gRageStats.end(); ) {
        bool found = false;
        for (void* q : gCached) {
            if (q == it->first) {
                found = true;
                break;
            }
        }
        if (!found) {
            it = gRageStats.erase(it);
        } else {
            ++it;
        }
    }
}

// Note a shot against the current target.
static void RageNoteShot() {
    void* t = gRageTarget.load();
    if (!alive(t)) {
        return;
    }
    auto it = gRageStats.find(t);
    if (it != gRageStats.end()) {
        it->second.shots += 1;
    } else {
        RageTargetStat s;
        s.shots = 1;
        s.firstSeenMs = NowMs();
        gRageStats[t] = s;
    }
}

// Note a hit against the current target. Called from the damage-delta path in espTick.
static void RageNoteHit() {
    if (!gRagePerTargetStats.load()) {
        return;
    }
    gRageHitSerial = gRageHitSerial.load() + 1;
    gRageLastHitMs = NowMs();
    gRageLastHitSerial = gRageShotSerial.load();

    // Attribute the hit to the newest log row for the current target.
    void* t = gRageTarget.load();
    if (alive(t) && !gRageLog.empty()) {
        for (size_t i = gRageLog.size(); i-- > 0; ) {
            if (gRageLog[i].hit) {
                continue;
            }
            gRageLog[i].hit = true;
            break;
        }
    }

    if (!alive(t)) {
        return;
    }
    auto it = gRageStats.find(t);
    if (it != gRageStats.end()) {
        it->second.hits += 1;
        if (gRagePoint.load() == 0) {
            it->second.headshots += 1;
        }
    }
}

// -----------------------------------------------------------------------------------------
// 7. entry point
// -----------------------------------------------------------------------------------------

// One RAGE frame. Called from espTick, which already runs on the display-link thread and
// already refreshes gCached, g_localEye, g_localCamera and g_localSceneChar.
static void RageTick() {
    if (!gRageEnabled.load()) {
        // Master switch off: never leave a synthetic trigger held down.
        RageReleaseTrigger();
        return;
    }

    if (!gAttached || !p_runtime_invoke || !p_lookAtTarget) {
        return;
    }
    if (!alive(g_localSceneChar) || !alive(g_localCamera)) {
        RageReleaseTrigger();
        return;
    }

    uint64_t now = NowMs();

    // --- aim --------------------------------------------------------------------------
    bool visible = false;
    Vec3 aimPos = Vec3{0.0f, 0.0f, 0.0f};
    bool headshot = false;
    float distance = 0.0f;
    int damage = 0;
    void* target = RagePickTarget(g_localCamera, visible, aimPos, headshot, distance, damage);

    bool haveTarget = alive(target) && Math::Finite(aimPos);

    if (gRageAutoAim.load() && haveTarget) {
        RageAimAt(aimPos);
    } else if (!gRageAutoAim.load()) {
        // Auto-aim off: anchor the smooth target so re-enabling does not sweep.
        g_smoothTarget = Vec3{0.0f, 0.0f, 0.0f};
        g_smoothAimCursorValid = false;
    }

    // Keep the shared aim state in sync so the HUD aim line and the aim-info panel show
    // what the rage pipeline is doing, not what the legacy aimbot would do.
    if (haveTarget) {
        g_targetHead = aimPos;
        g_haveTarget = true;
        g_silentAimTarget = aimPos;
        g_aimTargetObj = target;
    } else if (!gAimbotEnabled.load() && !gAimOnFireEnabled.load() && !gSilentAimEnabled.load()) {
        // Nobody else owns the shared aim state: release it, and drop the step cursor so the
        // next lock starts from the real position instead of sweeping in from the old one.
        g_smoothAimCursorValid = false;
        g_haveTarget = false;
        g_silentAimActive = false;
        g_aimTargetObj = nullptr;
    }

    // --- bookkeeping ------------------------------------------------------------------
    if (haveTarget) {
        void* c = *(void**)((uintptr_t)target + off::kPlayerCharacter);
        RageUpdateStats(target, c, distance, visible);

        if (alive(c)) {
            void* mc = *(void**)((uintptr_t)c + off::kCharModelContainer);
            if (alive(mc)) {
                Vec3 tpos;
                if (getPosFast(mc, tpos) && Math::Finite(tpos)) {
                    gRageLastTargetPos = tpos;
                    gRageLastTargetMs = now;
                }
            }
        }
    }

    // --- trigger ----------------------------------------------------------------------
    if (gRageAutoFire.load() && haveTarget) {
        void* fireTarget = nullptr;
        if (RageCanFire(visible, distance, damage, headshot, fireTarget)) {
            RageNoteShot();
            RageFire();
        }
    }

    // The mobile input fire path is edge-triggered, so lift the synthetic trigger once the
    // shot has had time to register.
    if (gRageTriggerHeld.load()) {
        uint64_t held = now - gRageLastFireMs.load();
        uint64_t holdFor = gRageBurst.load() ? 60 : 90;
        if (held >= holdFor) {
            RageReleaseTrigger();
        }
    }

    // --- auto reload / auto pistol ----------------------------------------------------
    if (alive(g_localWeapon)) {
        bool reloading = *(bool*)((uintptr_t)g_localWeapon + off::kWepIsReload);
        int ammo = *(int*)((uintptr_t)g_localWeapon + off::kWepAmmo);

        if (gRageAutoReload.load() && !reloading && ammo <= 0 && !gRageAutoStop.load()) {
            // Reload through the weapon's own path, not by flipping the flag by hand.
            TriggerRageReload();
            if (gRageDebug.load() && now - gRageLastPruneMs.load() > 1000) {
                gRageLastPruneMs = now;
                LOG(@"[RAGE] auto reload (ammo=%d)", ammo);
            }
        }

        if (gRageAutoPistol.load() && ammo <= 0 && !reloading) {
            int total = *(int*)((uintptr_t)g_localWeapon + off::kWepAmmoTotal);
            if (total <= 0) {
                // Dry primary: try the sidearm slot. No-op if the game has no slot bound.
                TriggerRageSwitchWeapon(1);
            }
        }
    }

    // --- anti-aim ---------------------------------------------------------------------
    RageAntiAimTick();

    // --- periodic housekeeping --------------------------------------------------------
    if (now - gRageLastPruneMs.load() > 2000) {
        gRageLastPruneMs = now;
        RagePruneStats();

        if (!gRageLog.empty()) {
            size_t before = gRageLog.size();
            gRageLog.erase(
                std::remove_if(gRageLog.begin(), gRageLog.end(),
                               [now](const RageLogEntry& e) { return now - e.atMs > 30000; }),
                gRageLog.end());
            if (gRageLog.size() != before && gRageDebug.load()) {
                LOG(@"[RAGE] pruned %zu log entries", before - gRageLog.size());
            }
        }
    }
}


// =========================================================================================
// HUD MODEL
// =========================================================================================

static void HudBeginFrame(void) {
    gHudPlayers.clear();
    gHudRadar.clear();
    gHudAimLineActive = false;
    gHudCrosshairVisible = false;
    gHudScopeActive = false;
    
    uint64_t now = NowMs();
    for (auto it = gHudDamage.begin(); it != gHudDamage.end(); ) {
        if (it->until <= now) {
            it = gHudDamage.erase(it);
        } else {
            ++it;
        }
    }
    for (auto it = gHudKills.begin(); it != gHudKills.end(); ) {
        if (it->until <= now) {
            it = gHudKills.erase(it);
        } else {
            ++it;
        }
    }
    for (auto it = gHudEvents.begin(); it != gHudEvents.end(); ) {
        if (it->until <= now) {
            it = gHudEvents.erase(it);
        } else {
            ++it;
        }
    }
}

static void HudAddPlayer(const HudPlayerInfo& info) {
    if (gHudPlayers.size() < 128) {
        gHudPlayers.push_back(info);
    }
}

static void HudAddDamage(CGPoint pos, int amount, uint64_t until) {
    if (!gDamageNumbersEnabled.load()) {
        return;
    }
    if (gDamageStack.load()) {
    uint64_t now = NowMs();
        for (auto& d : gHudDamage) {
            float dx = d.pos.x - pos.x;
            float dy = d.pos.y - pos.y;
            if (dx * dx + dy * dy < 900.0f && d.until > now) {
                d.amount += amount;
                d.until = until;
                return;
            }
        }
    }
    if (gHudDamage.size() >= 48) {
        gHudDamage.erase(gHudDamage.begin());
    }
    HudDamageInfo d;
    d.pos = pos;
    d.amount = amount;
    d.until = until;
    gHudDamage.push_back(d);
}

static void HudAddKill(const char* name, uint64_t until) {
    if (!gKillFeedEnabled.load() || !name) {
        return;
    }
    int maxEntries = gKillFeedMax.load();
    if (maxEntries < 1) {
        maxEntries = 1;
    }
    if (maxEntries > 16) {
        maxEntries = 16;
    }
    if ((int)gHudKills.size() >= maxEntries) {
        gHudKills.erase(gHudKills.begin());
    }
    HudKillInfo k;
    memset(k.name, 0, sizeof(k.name));
    strncpy(k.name, name, sizeof(k.name) - 1);
    k.until = until;
    gHudKills.push_back(k);
}

static void HudAddEvent(const char* text, int kind, uint64_t until) {
    if (!gEventLogEnabled.load() || !text) {
        return;
    }
    int maxEntries = gEventLogMax.load();
    if (maxEntries < 1) {
        maxEntries = 1;
    }
    if (maxEntries > 12) {
        maxEntries = 12;
    }
    if ((int)gHudEvents.size() >= maxEntries) {
        gHudEvents.erase(gHudEvents.begin());
    }
    HudEventInfo e;
    memset(e.text, 0, sizeof(e.text));
    strncpy(e.text, text, sizeof(e.text) - 1);
    e.until = until;
    e.kind = kind;
    gHudEvents.push_back(e);
}

static void HudAddRadar(float x, float y, int team, bool dead) {
    if (!gRadarEnabled.load()) {
        return;
    }
    if (gHudRadar.size() >= 128) {
        gHudRadar.erase(gHudRadar.begin());
    }
    HudRadarBlip b;
    b.x = x;
    b.y = y;
    b.team = team;
    b.dead = dead;
    gHudRadar.push_back(b);
}

static void HudSetAimLine(bool active, CGPoint target) {
    gHudAimLineActive = active;
    gHudAimLineTarget = target;
}

static void HudSetCrosshair(float gap, bool visible) {
    if (!std::isfinite(gap)) {
        gap = 6.0f;
    }
    gHudCrosshairGap = Math::Clamp(gap, 2.0f, 80.0f);
    gHudCrosshairVisible = visible;
}

static void HudSetScope(bool active) {
    gHudScopeActive = active;
}

// =========================================================================================
// HUD VIEW
// =========================================================================================

@interface HudView : UIView
@end

static HudView* gHudView = nil;

static void HudSampleFrame(void) {
    uint64_t now = NowMs();
    if (gFpsLastSample == 0) {
        gFpsLastSample = now;
        gFpsFrames = 0;
        return;
    }
    
    gFpsFrames++;
    uint64_t elapsed = now - gFpsLastSample;
    if (elapsed < 500) {
        return;
    }
    
    float fps = (float)gFpsFrames * 1000.0f / (float)elapsed;
    if (!std::isfinite(fps) || fps < 0.0f) {
        fps = 0.0f;
    }
    if (fps > 999.0f) {
        fps = 999.0f;
    }
    
    float frameMs = (float)elapsed / (float)gFpsFrames;
    gFpsValue = (int)(fps + 0.5f);
    gFrameMs = std::isfinite(frameMs) ? frameMs : 0.0f;
    
    if (gFpsHistory.size() >= 120) {
        gFpsHistory.erase(gFpsHistory.begin());
    }
    gFpsHistory.push_back(fps);
    
    gFpsFrames = 0;
    gFpsLastSample = now;
}

static void HudTick(void) {
    HudSampleFrame();
    if (gHudView) {
        [gHudView setNeedsDisplay];
    }
}

@implementation HudView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = NO;
        self.opaque = NO;
        self.clearsContextBeforeDrawing = NO;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    }
    return self;
}

- (void)drawScopeOverlay:(CGContextRef)ctx rect:(CGRect)rect {
    if (!gHudScopeActive || !gScopeOverlayEnabled) {
        return;
    }
    
    CGFloat w = rect.size.width;
    CGFloat h = rect.size.height;
    CGFloat radius = MIN(w, h) * 0.42f;
    CGRect hole = CGRectMake(w/2 - radius, h/2 - radius, radius * 2, radius * 2);
    
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathAddRect(path, NULL, rect);
    CGPathAddEllipseInRect(path, NULL, hole);
    
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.0 alpha:0.88].CGColor);
    CGContextAddPath(ctx, path);
    CGContextEOFillPath(ctx);
    CGPathRelease(path);
    
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:0.0 alpha:0.95].CGColor);
    CGContextSetLineWidth(ctx, 2.0);
    CGContextStrokeEllipseInRect(ctx, hole);
}

- (void)drawRadar:(CGContextRef)ctx rect:(CGRect)rect {
    if (!gRadarEnabled) {
        return;
    }
    
    CGFloat size = Math::Clamp(gRadarSize.load(), 70.0f, 220.0f);
    CGFloat margin = 24.0f;
    CGFloat cx = rect.size.width - margin - size / 2.0f;
    CGFloat cy = rect.size.height - margin - size / 2.0f;
    CGFloat radius = size / 2.0f;
    
    float radarAlpha = gRadarOpacity.load();
    if (!std::isfinite(radarAlpha) || radarAlpha < 0.05f) {
        radarAlpha = 0.38f;
    }
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.0 alpha:radarAlpha].CGColor);
    CGContextFillEllipseInRect(ctx, CGRectMake(cx - radius, cy - radius, size, size));
    
    CGContextSetStrokeColorWithColor(ctx, (gRadarColor ?: [UIColor greenColor]).CGColor);
    CGContextSetLineWidth(ctx, 1.0);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(cx - radius, cy - radius, size, size));
    CGContextStrokeEllipseInRect(ctx, CGRectMake(cx - radius * 0.66f, cy - radius * 0.66f, radius * 1.32f, radius * 1.32f));
    CGContextStrokeEllipseInRect(ctx, CGRectMake(cx - radius * 0.33f, cy - radius * 0.33f, radius * 0.66f, radius * 0.66f));
    
    CGContextMoveToPoint(ctx, cx - radius, cy);
    CGContextAddLineToPoint(ctx, cx + radius, cy);
    CGContextMoveToPoint(ctx, cx, cy - radius);
    CGContextAddLineToPoint(ctx, cx, cy + radius);
    CGContextStrokePath(ctx);
    
    float range = (float)Math::Clamp((float)gRadarRange.load(), 20.0f, 150.0f);
    float scale = radius / range;
    
    for (const HudRadarBlip& b : gHudRadar) {
        if (!std::isfinite(b.x) || !std::isfinite(b.y)) {
            continue;
        }
        float px = cx + b.x * scale;
        float py = cy + b.y * scale;
        float dx = px - cx;
        float dy = py - cy;
        float len = sqrtf(dx * dx + dy * dy);
        if (len > radius) {
            px = cx + dx / len * radius;
            py = cy + dy / len * radius;
        }
        
        UIColor* color = (b.team == gTeam && gTeam >= 0) ? [UIColor cyanColor] : [UIColor redColor];
        if (b.dead) {
            color = [UIColor grayColor];
        }
        
        float blip = gRadarBlipSize.load();
        if (!std::isfinite(blip) || blip < 1.0f) {
            blip = 2.5f;
        }
        CGContextSetFillColorWithColor(ctx, color.CGColor);
        CGContextFillEllipseInRect(ctx, CGRectMake(px - blip, py - blip, blip * 2.0f, blip * 2.0f));
    }
    
    CGContextSetFillColorWithColor(ctx, [UIColor whiteColor].CGColor);
    CGContextFillEllipseInRect(ctx, CGRectMake(cx - 2.0f, cy - 2.0f, 4.0f, 4.0f));
}

- (void)strokeCrosshairShape:(CGContextRef)ctx cx:(CGFloat)cx cy:(CGFloat)cy gap:(CGFloat)gap len:(CGFloat)len style:(int)style {
    if (style == 1) {
        return;
    }
    if (style == 2) {
        CGContextStrokeEllipseInRect(ctx, CGRectMake(cx - gap - len, cy - gap - len, (gap + len) * 2.0f, (gap + len) * 2.0f));
        return;
    }
    if (style == 3) {
        CGContextMoveToPoint(ctx, cx - gap - len, cy);
        CGContextAddLineToPoint(ctx, cx - gap, cy);
        CGContextMoveToPoint(ctx, cx + gap, cy);
        CGContextAddLineToPoint(ctx, cx + gap + len, cy);
        CGContextMoveToPoint(ctx, cx, cy + gap);
        CGContextAddLineToPoint(ctx, cx, cy + gap + len);
        CGContextStrokePath(ctx);
        return;
    }
    if (style == 4) {
        CGContextMoveToPoint(ctx, cx - gap - len, cy - gap - len);
        CGContextAddLineToPoint(ctx, cx - gap, cy - gap);
        CGContextMoveToPoint(ctx, cx + gap, cy - gap);
        CGContextAddLineToPoint(ctx, cx + gap + len, cy - gap - len);
        CGContextMoveToPoint(ctx, cx - gap - len, cy + gap + len);
        CGContextAddLineToPoint(ctx, cx - gap, cy + gap);
        CGContextMoveToPoint(ctx, cx + gap, cy + gap);
        CGContextAddLineToPoint(ctx, cx + gap + len, cy + gap + len);
        CGContextStrokePath(ctx);
        return;
    }
    CGContextMoveToPoint(ctx, cx - gap - len, cy);
    CGContextAddLineToPoint(ctx, cx - gap, cy);
    CGContextMoveToPoint(ctx, cx + gap, cy);
    CGContextAddLineToPoint(ctx, cx + gap + len, cy);
    CGContextMoveToPoint(ctx, cx, cy - gap - len);
    CGContextAddLineToPoint(ctx, cx, cy - gap);
    CGContextMoveToPoint(ctx, cx, cy + gap);
    CGContextAddLineToPoint(ctx, cx, cy + gap + len);
    CGContextStrokePath(ctx);
}

- (void)drawCrosshair:(CGContextRef)ctx rect:(CGRect)rect {
    if (!gHudCrosshairVisible || !gCrosshairEnabled) {
        return;
    }
    
    CGFloat cx = rect.size.width / 2.0f;
    CGFloat cy = rect.size.height / 2.0f;
    CGFloat gap = gHudCrosshairGap;
    CGFloat len = gCrosshairLength.load();
    CGFloat th = gCrosshairThickness.load();
    CGFloat dot = gCrosshairDot.load();
    int style = gCrosshairStyle.load();
    if (!std::isfinite(len) || len < 1.0f) len = 9.0f;
    if (!std::isfinite(th) || th < 0.5f) th = 1.4f;
    if (!std::isfinite(dot) || dot < 0.0f) dot = 1.5f;
    
    UIColor* col = gCrosshairColor ?: [UIColor whiteColor];
    
    if (gCrosshairOutline.load()) {
        CGContextSetStrokeColorWithColor(ctx, [[UIColor blackColor] colorWithAlphaComponent:0.65].CGColor);
        CGContextSetLineWidth(ctx, th + 2.0f);
        [self strokeCrosshairShape:ctx cx:cx cy:cy gap:gap len:len style:style];
    }
    
    CGContextSetStrokeColorWithColor(ctx, col.CGColor);
    CGContextSetLineWidth(ctx, th);
    [self strokeCrosshairShape:ctx cx:cx cy:cy gap:gap len:len style:style];
    
    if (style == 1 || style == 2 || dot > 0.0f) {
        CGContextSetFillColorWithColor(ctx, col.CGColor);
        CGContextFillEllipseInRect(ctx, CGRectMake(cx - dot, cy - dot, dot * 2.0f, dot * 2.0f));
    }
}

- (void)drawHitMarker:(CGContextRef)ctx rect:(CGRect)rect {
    if (!gHitMarkerEnabled) {
        return;
    }
    
    uint64_t now = NowMs();
    if (now >= gHudHitMarkerUntil) {
        return;
    }
    
    int duration = gHitMarkerDuration.load();
    if (duration < 50) {
        duration = 260;
    }
    float remain = (float)(gHudHitMarkerUntil - now) / (float)duration;
    remain = Math::Clamp(remain, 0.0f, 1.0f);
    
    CGFloat cx = rect.size.width / 2.0f;
    CGFloat cy = rect.size.height / 2.0f;
    CGFloat base = gHitMarkerSize.load();
    if (!std::isfinite(base) || base < 4.0f) {
        base = 10.0f;
    }
    CGFloat s = base + (1.0f - remain) * 4.0f;
    int style = gHitMarkerStyle.load();
    
    UIColor* color = gHitMarkerColor ?: [UIColor whiteColor];
    CGContextSetStrokeColorWithColor(ctx, [color colorWithAlphaComponent:remain].CGColor);
    CGContextSetFillColorWithColor(ctx, [color colorWithAlphaComponent:remain].CGColor);
    CGContextSetLineWidth(ctx, 2.0);
    
    if (style == 0 || style == 2) {
        CGContextMoveToPoint(ctx, cx - s, cy - s);
        CGContextAddLineToPoint(ctx, cx - 3, cy - 3);
        CGContextMoveToPoint(ctx, cx + s, cy - s);
        CGContextAddLineToPoint(ctx, cx + 3, cy - 3);
        CGContextMoveToPoint(ctx, cx - s, cy + s);
        CGContextAddLineToPoint(ctx, cx - 3, cy + 3);
        CGContextMoveToPoint(ctx, cx + s, cy + s);
        CGContextAddLineToPoint(ctx, cx + 3, cy + 3);
        CGContextStrokePath(ctx);
    }
    
    if (style == 1 || style == 2) {
        CGFloat dot = 2.2f;
        CGContextFillEllipseInRect(ctx, CGRectMake(cx - dot, cy - dot, dot * 2.0f, dot * 2.0f));
    }
    
    if (gHitMarkerShowDamage.load() && gHudHitMarkerDamage > 0) {
        static UIFont* hmFont = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            hmFont = [UIFont boldSystemFontOfSize:12];
        });
        NSString* dmg = SafeFmt(@"-%d", gHudHitMarkerDamage);
        NSDictionary* attrs = @{
            NSFontAttributeName: hmFont ?: [UIFont boldSystemFontOfSize:12],
            NSForegroundColorAttributeName: [color colorWithAlphaComponent:remain]
        };
        CGSize sz = [dmg sizeWithAttributes:attrs];
        [dmg drawAtPoint:CGPointMake(cx - sz.width / 2.0f, cy + s + 2.0f) withAttributes:attrs];
    }
}

- (void)drawDamageNumbers:(CGContextRef)ctx rect:(CGRect)rect {
    if (!gDamageNumbersEnabled) {
        return;
    }
    
    float fontSize = gDamageNumberSize.load();
    if (!std::isfinite(fontSize) || fontSize < 6.0f) {
        fontSize = 13.0f;
    }
    UIFont* dmgFont = [UIFont boldSystemFontOfSize:fontSize];
    if (!dmgFont) {
        dmgFont = [UIFont boldSystemFontOfSize:13];
    }
    
    int duration = gDamageNumberDuration.load();
    if (duration < 100) {
        duration = 650;
    }
    float rise = gDamageNumberRise.load();
    if (!std::isfinite(rise) || rise < 0.0f) {
        rise = 32.0f;
    }
    
    UIColor* baseColor = gDamageNumberColor ?: [UIColor colorWithRed:1.0 green:0.75 blue:0.1 alpha:1.0];
    bool outline = gDamageNumberOutline.load();
    uint64_t now = NowMs();
    
    for (const HudDamageInfo& d : gHudDamage) {
        if (d.until <= now) {
            continue;
        }
        float remain = (float)(d.until - now) / (float)duration;
        remain = Math::Clamp(remain, 0.0f, 1.0f);
        if (!std::isfinite(d.pos.x) || !std::isfinite(d.pos.y)) {
            continue;
        }
        
        NSString* text = SafeFmt(@"-%d", d.amount);
        UIColor* color = [baseColor colorWithAlphaComponent:remain];
        NSDictionary* attrs = @{
            NSFontAttributeName: dmgFont,
            NSForegroundColorAttributeName: color
        };
        CGSize sz = [text sizeWithAttributes:attrs];
        CGFloat tx = d.pos.x - sz.width / 2.0f;
        CGFloat ty = d.pos.y - (1.0f - remain) * rise;
        
        if (outline) {
            NSDictionary* outlineAttrs = @{
                NSFontAttributeName: dmgFont,
                NSForegroundColorAttributeName: [[UIColor blackColor] colorWithAlphaComponent:remain * 0.9f]
            };
            [text drawAtPoint:CGPointMake(tx - 1.0f, ty) withAttributes:outlineAttrs];
            [text drawAtPoint:CGPointMake(tx + 1.0f, ty) withAttributes:outlineAttrs];
            [text drawAtPoint:CGPointMake(tx, ty - 1.0f) withAttributes:outlineAttrs];
            [text drawAtPoint:CGPointMake(tx, ty + 1.0f) withAttributes:outlineAttrs];
        }
        
        [text drawAtPoint:CGPointMake(tx, ty) withAttributes:attrs];
    }
}

- (void)drawKillFeed:(CGContextRef)ctx rect:(CGRect)rect {
    if (!gKillFeedEnabled) {
        return;
    }
    
    static UIFont* kfFont = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kfFont = [UIFont boldSystemFontOfSize:11];
    });
    
    CGFloat x = rect.size.width - 12.0f;
    CGFloat y = 90.0f;
    uint64_t now = NowMs();
    float dur = gKillFeedDuration.load();
    if (!std::isfinite(dur) || dur < 500.0f) {
        dur = 6000.0f;
    }
    UIColor* kc = gKillFeedColor ?: [UIColor colorWithRed:1.0 green:0.35 blue:0.35 alpha:1.0];
    
    for (const HudKillInfo& k : gHudKills) {
        if (k.until <= now) {
            continue;
        }
        float remain = (float)(k.until - now) / dur;
        remain = Math::Clamp(remain, 0.0f, 1.0f);
        NSString* text = SafeFmt(@"[FlopDLC] %s", k.name);
        NSDictionary* attrs = @{
            NSFontAttributeName: kfFont ?: [UIFont boldSystemFontOfSize:11],
            NSForegroundColorAttributeName: [kc colorWithAlphaComponent:remain]
        };
        CGSize sz = [text sizeWithAttributes:attrs];
        [text drawAtPoint:CGPointMake(x - sz.width, y) withAttributes:attrs];
        y += sz.height + 3.0f;
    }
}

- (void)drawAimLine:(CGContextRef)ctx rect:(CGRect)rect {
    if (!gAimLineEnabled || !gHudAimLineActive) {
        return;
    }
    
    CGFloat cx = rect.size.width / 2.0f;
    CGFloat cy = rect.size.height / 2.0f;
    
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:0.9 green:0.2 blue:0.9 alpha:0.8].CGColor);
    CGContextSetLineWidth(ctx, 1.2);
    CGFloat dash[] = {5.0, 4.0};
    CGContextSetLineDash(ctx, 0.0, dash, 2);
    CGContextMoveToPoint(ctx, cx, cy);
    CGContextAddLineToPoint(ctx, gHudAimLineTarget.x, gHudAimLineTarget.y);
    CGContextStrokePath(ctx);
    CGContextSetLineDash(ctx, 0.0, NULL, 0);
}

- (void)drawFpsGraph:(CGContextRef)ctx rect:(CGRect)rect {
    if (!gFpsEnabled) {
        return;
    }
    
    static UIFont* fpsFont = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fpsFont = [UIFont boldSystemFontOfSize:10];
    });
    
    CGFloat w = 132.0f;
    CGFloat h = 46.0f;
    CGFloat x = 10.0f;
    CGFloat y = 10.0f;
    
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.0 alpha:0.45].CGColor);
    CGContextFillRect(ctx, CGRectMake(x, y, w, h));
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:0.5 alpha:0.6].CGColor);
    CGContextSetLineWidth(ctx, 0.8);
    CGContextStrokeRect(ctx, CGRectMake(x, y, w, h));
    
    int fps = gFpsValue.load();
    float ms = gFrameMs.load();
    UIColor* fpsColor = [UIColor greenColor];
    if (fps < 50) {
        fpsColor = [UIColor yellowColor];
    }
    if (fps < 30) {
        fpsColor = [UIColor redColor];
    }
    
    NSString* line = SafeFmt(@"%d FPS  %.1f ms", fps, ms);
    NSDictionary* attrs = @{
        NSFontAttributeName: fpsFont ?: [UIFont boldSystemFontOfSize:10],
        NSForegroundColorAttributeName: fpsColor
    };
    [line drawAtPoint:CGPointMake(x + 6.0f, y + 3.0f) withAttributes:attrs];
    
    CGFloat graphY = y + 18.0f;
    CGFloat graphH = h - 22.0f;
    CGFloat graphW = w - 12.0f;
    CGFloat stepX = graphW / 119.0f;
    
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:0.25 alpha:0.7].CGColor);
    CGContextSetLineWidth(ctx, 0.5);
    CGContextMoveToPoint(ctx, x + 6.0f, graphY + graphH / 2.0f);
    CGContextAddLineToPoint(ctx, x + 6.0f + graphW, graphY + graphH / 2.0f);
    CGContextStrokePath(ctx);
    
    if (gFpsHistory.size() >= 2) {
        CGContextSetStrokeColorWithColor(ctx, fpsColor.CGColor);
        CGContextSetLineWidth(ctx, 1.2);
        
        CGFloat baseX = x + 6.0f + graphW - ((CGFloat)(gFpsHistory.size() - 1) * stepX);
        bool started = false;
        for (NSUInteger i = 0; i < gFpsHistory.size(); i++) {
            float v = gFpsHistory[i];
            v = Math::Clamp(v, 0.0f, 120.0f);
            CGFloat px = baseX + (CGFloat)i * stepX;
            CGFloat py = graphY + graphH - (v / 120.0f) * graphH;
            if (!started) {
                CGContextMoveToPoint(ctx, px, py);
                started = true;
            } else {
                CGContextAddLineToPoint(ctx, px, py);
            }
        }
        CGContextStrokePath(ctx);
    }
}

- (void)drawFovCircle:(CGContextRef)ctx rect:(CGRect)rect {
    if (!gFovCircleEnabled.load() || !gAimDrawFov.load()) {
        return;
    }
    if (!(gAimbotEnabled || gAimOnFireEnabled || gSilentAimEnabled || gHotAimbotEnabled || gHotAimOnFireEnabled)) {
        return;
    }
    float fov = (float)gAimbotFovPx.load();
    if (!std::isfinite(fov) || fov <= 0.0f) {
        return;
    }
    CGFloat cx = rect.size.width / 2.0f;
    CGFloat cy = rect.size.height / 2.0f;
    UIColor* col = gFovCircleColor ?: [UIColor whiteColor];
    float th = gFovCircleThickness.load();
    if (!std::isfinite(th) || th < 0.5f) th = 1.0f;
    int style = gFovCircleStyle.load();
    bool filled = gFovCircleFilled.load();
    CGRect box = CGRectMake(cx - fov, cy - fov, fov * 2.0f, fov * 2.0f);
    
    if (filled) {
        CGContextSetFillColorWithColor(ctx, [col colorWithAlphaComponent:0.08].CGColor);
        if (style == 1) {
            CGContextFillRect(ctx, box);
        } else {
            CGContextFillEllipseInRect(ctx, box);
        }
    }
    
    CGContextSetStrokeColorWithColor(ctx, col.CGColor);
    CGContextSetLineWidth(ctx, th);
    
    if (style == 1) {
        CGContextStrokeRect(ctx, box);
    } else if (style == 2) {
        CGFloat cl = fov * 0.35f;
        CGContextMoveToPoint(ctx, box.origin.x, box.origin.y + cl);
        CGContextAddLineToPoint(ctx, box.origin.x, box.origin.y);
        CGContextAddLineToPoint(ctx, box.origin.x + cl, box.origin.y);
        CGContextMoveToPoint(ctx, box.origin.x + box.size.width - cl, box.origin.y);
        CGContextAddLineToPoint(ctx, box.origin.x + box.size.width, box.origin.y);
        CGContextAddLineToPoint(ctx, box.origin.x + box.size.width, box.origin.y + cl);
        CGContextMoveToPoint(ctx, box.origin.x + box.size.width, box.origin.y + box.size.height - cl);
        CGContextAddLineToPoint(ctx, box.origin.x + box.size.width, box.origin.y + box.size.height);
        CGContextAddLineToPoint(ctx, box.origin.x + box.size.width - cl, box.origin.y + box.size.height);
        CGContextMoveToPoint(ctx, box.origin.x + cl, box.origin.y + box.size.height);
        CGContextAddLineToPoint(ctx, box.origin.x, box.origin.y + box.size.height);
        CGContextAddLineToPoint(ctx, box.origin.x, box.origin.y + box.size.height - cl);
        CGContextStrokePath(ctx);
    } else {
        CGContextStrokeEllipseInRect(ctx, box);
    }
}

- (void)drawEventLog:(CGContextRef)ctx rect:(CGRect)rect {
    if (!gEventLogEnabled.load() || gHudEvents.empty()) {
        return;
    }
    static UIFont* f = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        f = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    });
    CGFloat x = gEventLogX.load();
    CGFloat y = gEventLogY.load();
    if (!std::isfinite(x)) x = 12.0f;
    if (!std::isfinite(y)) y = 300.0f;
    uint64_t now = NowMs();
    UIColor* base = gEventLogColor ?: [UIColor whiteColor];
    for (const HudEventInfo& e : gHudEvents) {
        if (e.until <= now) {
            continue;
        }
        float remain = (float)(e.until - now) / 1000.0f;
        remain = Math::Clamp(remain, 0.0f, 1.0f);
        UIColor* c = base;
        if (e.kind == 1) {
            c = gDamageLogColor ?: base;
        } else if (e.kind == 2) {
            c = gKillFeedColor ?: base;
        }
        NSDictionary* attrs = @{
            NSFontAttributeName: f ?: [UIFont systemFontOfSize:10],
            NSForegroundColorAttributeName: [c colorWithAlphaComponent:remain]
        };
        NSString* text = SafeFmt(@"%s", e.text);
        [text drawAtPoint:CGPointMake(x, y) withAttributes:attrs];
        y += 14.0f;
    }
}

- (void)drawPlayerList:(CGContextRef)ctx rect:(CGRect)rect {
    if (!gPlayerListEnabled.load() || gHudPlayers.empty()) {
        return;
    }
    CGFloat x = gPlayerListX.load();
    CGFloat y = gPlayerListY.load();
    float scale = gPlayerListScale.load();
    if (!std::isfinite(x)) x = 12.0f;
    if (!std::isfinite(y)) y = 220.0f;
    if (!std::isfinite(scale) || scale < 0.5f) scale = 1.0f;
    int maxN = gPlayerListMax.load();
    if (maxN < 1) maxN = 1;
    if (maxN > 16) maxN = 16;
    UIColor* base = gPlayerListColor ?: [UIColor whiteColor];
    UIFont* f = [UIFont systemFontOfSize:10.0f * scale weight:UIFontWeightMedium];
    int shown = 0;
    for (const HudPlayerInfo& p : gHudPlayers) {
        if (shown >= maxN) {
            break;
        }
        if (!gPlayerListDead.load() && p.health <= 0) {
            continue;
        }
        NSMutableString* line = [NSMutableString string];
        if (gPlayerListTeam.load()) {
            [line appendFormat:@"[%d] ", p.team];
        }
        if (gPlayerListHealth.load()) {
            [line appendFormat:@"%dHP ", p.health];
        }
        if (gPlayerListDistance.load()) {
            [line appendFormat:@"%.0fm ", p.distance];
        }
        if (gPlayerListWeapon.load()) {
            [line appendString:@"•"];
        }
        NSDictionary* attrs = @{
            NSFontAttributeName: f ?: [UIFont systemFontOfSize:10],
            NSForegroundColorAttributeName: base
        };
        [line drawAtPoint:CGPointMake(x, y) withAttributes:attrs];
        y += 14.0f * scale;
        shown++;
    }
}

- (void)drawInfoPanel:(CGContextRef)ctx rect:(CGRect)rect {
    if (!gInfoPanelEnabled.load()) {
        return;
    }
    CGFloat x = gInfoPanelX.load();
    CGFloat y = gInfoPanelY.load();
    if (!std::isfinite(x)) x = 12.0f;
    if (!std::isfinite(y)) y = 120.0f;
    UIColor* base = gInfoPanelColor ?: [UIColor whiteColor];
    UIFont* f = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    NSMutableArray<NSString*>* lines = [NSMutableArray array];
    if (gInfoPanelHealth.load()) {
        [lines addObject:SafeFmt(@"HP: %d", gLocalHealthVal.load())];
    }
    if (gInfoPanelAmmo.load()) {
        [lines addObject:SafeFmt(@"AMMO: %d/%d", gLocalAmmoVal.load(), gLocalAmmoTotalVal.load())];
    }
    if (gInfoPanelFps.load()) {
        [lines addObject:SafeFmt(@"FPS: %d", gFpsValue.load())];
    }
    if (gInfoPanelSpeed.load()) {
        [lines addObject:SafeFmt(@"SPD: %.1f", gLocalSpeedVal.load())];
    }
    if (lines.count == 0) {
        return;
    }
    if (gPanelBackground.load()) {
        CGFloat w = 0.0f;
        for (NSString* s in lines) {
            CGSize sz = [s sizeWithAttributes:@{NSFontAttributeName: f ?: [UIFont systemFontOfSize:10]}];
            if (sz.width > w) w = sz.width;
        }
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.0 alpha:0.35].CGColor);
        CGContextFillRect(ctx, CGRectMake(x - 4.0f, y - 3.0f, w + 8.0f, lines.count * 14.0f + 6.0f));
    }
    for (NSString* s in lines) {
        NSDictionary* attrs = @{
            NSFontAttributeName: f ?: [UIFont systemFontOfSize:10],
            NSForegroundColorAttributeName: base
        };
        [s drawAtPoint:CGPointMake(x, y) withAttributes:attrs];
        y += 14.0f;
    }
}

- (void)drawStatsPanel:(CGContextRef)ctx rect:(CGRect)rect {
    if (!gStatsPanelEnabled.load()) {
        return;
    }
    CGFloat x = gStatsPanelX.load();
    CGFloat y = gStatsPanelY.load();
    if (!std::isfinite(x)) x = 12.0f;
    if (!std::isfinite(y)) y = 420.0f;
    UIColor* base = gStatsColor ?: [UIColor whiteColor];
    UIFont* f = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    uint64_t start = gStatSessionStart.load();
    uint64_t now = NowMs();
    uint64_t secs = (start > 0 && now > start) ? (now - start) / 1000ULL : 0;
    NSArray<NSString*>* lines = @[
        SafeFmt(@"KILLS: %d", gStatKills.load()),
        SafeFmt(@"HITS: %d", gStatHits.load()),
        SafeFmt(@"DMG: %d", gStatDamage.load()),
        SafeFmt(@"HS: %d", gStatHeadshots.load()),
        SafeFmt(@"TIME: %02llu:%02llu", secs / 60ULL, secs % 60ULL)
    ];
    if (gPanelBackground.load()) {
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.0 alpha:0.35].CGColor);
        CGContextFillRect(ctx, CGRectMake(x - 4.0f, y - 3.0f, 110.0f, lines.count * 14.0f + 6.0f));
    }
    for (NSString* s in lines) {
        NSDictionary* attrs = @{
            NSFontAttributeName: f ?: [UIFont systemFontOfSize:10],
            NSForegroundColorAttributeName: base
        };
        [s drawAtPoint:CGPointMake(x, y) withAttributes:attrs];
        y += 14.0f;
    }
}

- (void)drawAimInfo:(CGContextRef)ctx rect:(CGRect)rect {
    if (!gAimInfoEnabled.load() || !g_haveTarget.load()) {
        return;
    }
    UIColor* base = gAimInfoColor ?: [UIColor magentaColor];
    UIFont* f = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    CGFloat cx = rect.size.width / 2.0f;
    CGFloat y = rect.size.height / 2.0f + (CGFloat)gAimbotFovPx.load() + 8.0f;
    NSString* text = SafeFmt(@"TARGET  FOV %d  BONE %d", gAimbotFovPx.load(), gAimBone.load());
    NSDictionary* attrs = @{
        NSFontAttributeName: f ?: [UIFont systemFontOfSize:10],
        NSForegroundColorAttributeName: base
    };
    CGSize sz = [text sizeWithAttributes:attrs];
    [text drawAtPoint:CGPointMake(cx - sz.width / 2.0f, y) withAttributes:attrs];
}

- (void)drawKeybindList:(CGContextRef)ctx rect:(CGRect)rect {
    if (!gKeybindListEnabled.load()) {
        return;
    }
    UIFont* f = [UIFont systemFontOfSize:9 weight:UIFontWeightMedium];
    CGFloat x = 12.0f;
    CGFloat y = rect.size.height - 90.0f;
    NSArray<NSString*>* lines = @[
        SafeFmt(@"AIMBOT: %@", (gAimbotEnabled || gHotAimbotEnabled) ? @"ON" : @"OFF"),
        SafeFmt(@"AIM FIRE: %@", (gAimOnFireEnabled || gHotAimOnFireEnabled) ? @"ON" : @"OFF"),
        SafeFmt(@"SA: %@ tgt=%d fire=%d fke=%@",
                gSilentAimEnabled.load() ? @"ON" : @"OFF",
                g_haveTarget.load() ? 1 : 0,
                IsFireHeld() ? 1 : 0,
                gFkePatched.load() ? @"OK" : @"NO"),
        SafeFmt(@"ESP: %@", (gEspEnabled || gHotEspEnabled) ? @"ON" : @"OFF"),
        SafeFmt(@"TRIGGER: %@", gTriggerbotEnabled.load() ? @"ON" : @"OFF")
    ];
    for (NSString* s in lines) {
        NSDictionary* attrs = @{
            NSFontAttributeName: f ?: [UIFont systemFontOfSize:9],
            NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.85]
        };
        [s drawAtPoint:CGPointMake(x, y) withAttributes:attrs];
        y += 12.0f;
    }
}

- (void)drawVelocityGraph:(CGContextRef)ctx rect:(CGRect)rect {
    if (!gVelocityGraphEnabled.load()) {
        return;
    }
    CGFloat w = 132.0f;
    CGFloat h = 46.0f;
    CGFloat x = 10.0f;
    CGFloat y = 60.0f;
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.0 alpha:0.45].CGColor);
    CGContextFillRect(ctx, CGRectMake(x, y, w, h));
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:0.5 alpha:0.6].CGColor);
    CGContextSetLineWidth(ctx, 0.8);
    CGContextStrokeRect(ctx, CGRectMake(x, y, w, h));
    
    static UIFont* vf = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        vf = [UIFont boldSystemFontOfSize:10];
    });
    NSString* line = SafeFmt(@"SPEED %.1f", gLocalSpeedVal.load());
    NSDictionary* attrs = @{
        NSFontAttributeName: vf ?: [UIFont boldSystemFontOfSize:10],
        NSForegroundColorAttributeName: [UIColor cyanColor]
    };
    [line drawAtPoint:CGPointMake(x + 6.0f, y + 3.0f) withAttributes:attrs];
    
    CGFloat graphY = y + 18.0f;
    CGFloat graphH = h - 22.0f;
    CGFloat graphW = w - 12.0f;
    CGFloat stepX = graphW / 119.0f;
    
    if (gSpeedHistory.size() >= 2) {
        CGContextSetStrokeColorWithColor(ctx, [UIColor cyanColor].CGColor);
        CGContextSetLineWidth(ctx, 1.2);
        CGFloat baseX = x + 6.0f + graphW - ((CGFloat)(gSpeedHistory.size() - 1) * stepX);
        bool started = false;
        for (NSUInteger i = 0; i < gSpeedHistory.size(); i++) {
            float v = Math::Clamp(gSpeedHistory[i], 0.0f, 20.0f);
            CGFloat px = baseX + (CGFloat)i * stepX;
            CGFloat py = graphY + graphH - (v / 20.0f) * graphH;
            if (!started) {
                CGContextMoveToPoint(ctx, px, py);
                started = true;
            } else {
                CGContextAddLineToPoint(ctx, px, py);
            }
        }
        CGContextStrokePath(ctx);
    }
}

- (void)drawSessionInfo:(CGContextRef)ctx rect:(CGRect)rect {
    if (!gSessionInfoEnabled.load()) {
        return;
    }
    static UIFont* f = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        f = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    });
    uint64_t start = gStatSessionStart.load();
    uint64_t now = NowMs();
    uint64_t secs = (start > 0 && now > start) ? (now - start) / 1000ULL : 0;
    CGFloat x = rect.size.width - 150.0f;
    CGFloat y = 10.0f;
    NSArray<NSString*>* lines = @[
        SafeFmt(@"SESSION %02llu:%02llu", secs / 60ULL, secs % 60ULL),
        SafeFmt(@"FPS %d", gFpsValue.load()),
        SafeFmt(@"HP %d", gLocalHealthVal.load()),
        SafeFmt(@"AMMO %d", gLocalAmmoVal.load())
    ];
    if (gPanelBackground.load()) {
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.0 alpha:0.35].CGColor);
        CGContextFillRect(ctx, CGRectMake(x - 4.0f, y - 3.0f, 140.0f, lines.count * 14.0f + 6.0f));
    }
    for (NSString* s in lines) {
        NSDictionary* attrs = @{
            NSFontAttributeName: f ?: [UIFont systemFontOfSize:10],
            NSForegroundColorAttributeName: [UIColor whiteColor]
        };
        [s drawAtPoint:CGPointMake(x, y) withAttributes:attrs];
        y += 14.0f;
    }
}

- (void)drawDamageLogPanel:(CGContextRef)ctx rect:(CGRect)rect {
    if (!gDamageLogPanelEnabled.load() || gHudEvents.empty()) {
        return;
    }
    static UIFont* f = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        f = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    });
    CGFloat x = rect.size.width - 150.0f;
    CGFloat y = 90.0f;
    uint64_t now = NowMs();
    UIColor* base = gDamageLogColor ?: [UIColor redColor];
    int shown = 0;
    for (const HudEventInfo& e : gHudEvents) {
        if (e.kind != 1 || e.until <= now) {
            continue;
        }
        if (shown >= 6) {
            break;
        }
        float remain = Math::Clamp((float)(e.until - now) / 1000.0f, 0.0f, 1.0f);
        NSDictionary* attrs = @{
            NSFontAttributeName: f ?: [UIFont systemFontOfSize:10],
            NSForegroundColorAttributeName: [base colorWithAlphaComponent:remain]
        };
        NSString* text = SafeFmt(@"%s", e.text);
        [text drawAtPoint:CGPointMake(x, y) withAttributes:attrs];
        y += 14.0f;
        shown++;
    }
}

- (void)drawTargetList:(CGContextRef)ctx rect:(CGRect)rect {
    if (!gTargetListEnabled.load() || gHudPlayers.empty()) {
        return;
    }
    static UIFont* f = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        f = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    });
    CGFloat x = rect.size.width - 170.0f;
    CGFloat y = 180.0f;
    std::vector<HudPlayerInfo> sorted = gHudPlayers;
    std::sort(sorted.begin(), sorted.end(), [](const HudPlayerInfo& a, const HudPlayerInfo& b) {
        return a.distance < b.distance;
    });
    int shown = 0;
    for (const HudPlayerInfo& p : sorted) {
        if (shown >= 8) {
            break;
        }
        if (p.health <= 0) {
            continue;
        }
        NSString* line = SafeFmt(@"%.0fm  %dHP  %@", p.distance, p.health, p.visible ? @"VIS" : @"HID");
        NSDictionary* attrs = @{
            NSFontAttributeName: f ?: [UIFont systemFontOfSize:10],
            NSForegroundColorAttributeName: p.visible ? [UIColor greenColor] : [UIColor redColor]
        };
        [line drawAtPoint:CGPointMake(x, y) withAttributes:attrs];
        y += 14.0f;
        shown++;
    }
}

- (void)drawCrosshairDebug:(CGContextRef)ctx rect:(CGRect)rect {
    if (!gCrosshairDebugEnabled.load()) {
        return;
    }
    static UIFont* f = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        f = [UIFont systemFontOfSize:9 weight:UIFontWeightMedium];
    });
    CGFloat cx = rect.size.width / 2.0f;
    CGFloat y = rect.size.height / 2.0f + 40.0f;
    NSString* text = SafeFmt(@"GAP %.1f  SCOPE %@", gHudCrosshairGap, gLocalScoped.load() ? @"ON" : @"OFF");
    NSDictionary* attrs = @{
        NSFontAttributeName: f ?: [UIFont systemFontOfSize:9],
        NSForegroundColorAttributeName: [UIColor yellowColor]
    };
    CGSize sz = [text sizeWithAttributes:attrs];
    [text drawAtPoint:CGPointMake(cx - sz.width / 2.0f, y) withAttributes:attrs];
}

- (void)drawAmmoBar:(CGContextRef)ctx rect:(CGRect)rect {
    if (!gAmmoBarEnabled.load()) {
        return;
    }
    int ammo = gLocalAmmoVal.load();
    int total = gLocalAmmoTotalVal.load();
    if (total <= 0) {
        total = 1;
    }
    CGFloat w = 180.0f;
    CGFloat h = 8.0f;
    CGFloat x = rect.size.width / 2.0f - w / 2.0f;
    CGFloat y = rect.size.height - 60.0f;
    float pct = Math::Clamp((float)ammo / (float)total, 0.0f, 1.0f);
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.1 alpha:0.7].CGColor);
    CGContextFillRect(ctx, CGRectMake(x, y, w, h));
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithRed:0.3 green:0.8 blue:1.0 alpha:0.9].CGColor);
    CGContextFillRect(ctx, CGRectMake(x, y, w * pct, h));
    
    static UIFont* f = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        f = [UIFont boldSystemFontOfSize:10];
    });
    NSString* text = SafeFmt(@"%d / %d", ammo, total);
    NSDictionary* attrs = @{
        NSFontAttributeName: f ?: [UIFont boldSystemFontOfSize:10],
        NSForegroundColorAttributeName: [UIColor whiteColor]
    };
    CGSize sz = [text sizeWithAttributes:attrs];
    [text drawAtPoint:CGPointMake(rect.size.width / 2.0f - sz.width / 2.0f, y - 14.0f) withAttributes:attrs];
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) {
        return;
    }
    
    // Stream mode: keep only the crosshair/scope so the HUD looks like a normal game.
    if (gStreamMode) {
        [self drawScopeOverlay:ctx rect:rect];
        [self drawCrosshair:ctx rect:rect];
        return;
    }
    
    [self drawFpsGraph:ctx rect:rect];
    [self drawScopeOverlay:ctx rect:rect];
    [self drawRadar:ctx rect:rect];
    [self drawAimLine:ctx rect:rect];
    [self drawFovCircle:ctx rect:rect];
    [self drawCrosshair:ctx rect:rect];
    [self drawHitMarker:ctx rect:rect];
    [self drawDamageNumbers:ctx rect:rect];
    [self drawKillFeed:ctx rect:rect];
    [self drawEventLog:ctx rect:rect];
    [self drawPlayerList:ctx rect:rect];
    [self drawInfoPanel:ctx rect:rect];
    [self drawStatsPanel:ctx rect:rect];
    [self drawAimInfo:ctx rect:rect];
    [self drawKeybindList:ctx rect:rect];
    [self drawVelocityGraph:ctx rect:rect];
    [self drawSessionInfo:ctx rect:rect];
    [self drawDamageLogPanel:ctx rect:rect];
    [self drawTargetList:ctx rect:rect];
    [self drawCrosshairDebug:ctx rect:rect];
    [self drawAmmoBar:ctx rect:rect];
}

@end

static void SetupHudView(void) {
    if (gHudView || !gEspView) {
        return;
    }
    gHudView = [[HudView alloc] initWithFrame:gEspView.bounds];
    gHudView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [gEspView addSubview:gHudView];
}

