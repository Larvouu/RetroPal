//
//  RAClient.h
//  EmulateurGBA
//
//  Objective-C++ wrapper around rcheevos' rc_client (MIT). This is the ONLY
//  place that touches the rcheevos C API; everything above it (the Swift
//  RetroAchievements manager, the UI) speaks this clean ObjC interface.
//
//  rc_client is NOT thread-safe. Every entry point here must be driven from the
//  same thread that runs the emulator frame loop (the main thread, per
//  EmulatorMetalView). The async server callbacks are marshalled back onto that
//  thread internally, so callers never have to think about it.
//
//  Surfaces wired here (Branch 1 — softcore, GB/GBC/GBA, free):
//    • create + the four rc_client callbacks (read_memory, server_call, log,
//      event handler) and a monotonic time source
//    • login (password → token, and token → session) and logout
//    • identify-and-load a game (rc_hash does the MD5), per-frame do_frame
//    • save-state progress serialize / deserialize
//  Hardcore is forced OFF here; it is a Branch-2 concern.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class RAClient;

/// Reads `length` bytes of live console memory at a REAL bus `address` into
/// `buffer`, returning bytes read (0 = unmapped). Supplied by the active
/// emulator session; the RA-flat→real translation has already happened inside
/// RAClient before this is called.
typedef NSInteger (^RAMemoryReader)(uint32_t address, uint8_t *buffer, NSInteger length);

/// Login result. On success `token` is the durable RA token to persist in the
/// Keychain (NEVER the password). On failure `error` carries the server message.
/// `credentialsRejected` is YES only when the SERVER refused the credentials
/// (invalid / expired / banned) — a transport failure (offline, timeout)
/// reports NO, so callers keep the stored token and retry later instead of
/// silently signing the user out after one offline launch.
typedef void (^RALoginCompletion)(BOOL success, NSString *_Nullable token,
                                  NSString *_Nullable error, BOOL credentialsRejected);

/// One achievement of the loaded game, for the in-app dashboard. Built from
/// rc_client's achievement list (no Web API key needed).
@interface RAAchievementInfo : NSObject
/// RA's stable achievement id — the key for the locally persisted
/// measured-progress snapshots (titles can be edited server-side).
@property (nonatomic, assign) uint32_t achievementID;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *detail;        // description
@property (nonatomic, copy, nullable) NSString *badgeURL;
@property (nonatomic, assign) NSInteger points;
@property (nonatomic, assign) BOOL unlocked;
/// Measured progress for partially-done achievements (e.g. "12/50"), else nil.
@property (nonatomic, copy, nullable) NSString *measuredProgress;
/// Fraction complete of a measured achievement, 0-100 (rc_client's
/// measured_percent). 0 when the achievement isn't measured (or no progress);
/// drives the gold progress bars in the row and badge-wall UIs.
@property (nonatomic, assign) double measuredPercent;
/// Percentage of players who have earned this achievement (softcore). 0 if unknown.
@property (nonatomic, assign) double rarity;
/// Which set this achievement belongs to, for GROUPING ONLY.
///
/// **0 means "this game has one set"**, and that is rc_client's own convention,
/// not ours: it writes `subset_id = (num_subsets > 1) ? subset->id : 0`. So the
/// overwhelmingly common case reports 0 and every surface behaves exactly as it
/// did before subsets existed.
///
/// Never persisted. The stored per-game record keeps the MERGED counts, which
/// is what `af0c185` fixed and must not be undone.
@property (nonatomic, assign) uint32_t subsetID;
@end

/// One set inside a multi-set game, with the counts that belong to IT alone.
///
/// Exists because two different numbers are both correct and have different
/// audiences. The merged total (base + bonus sets) is what the player actually
/// earns from and what every surface of ours must agree on. The per-set total is
/// what retroachievements.org shows, because the site deliberately does not let
/// a bonus set dilute main completion. Showing the merged number as the headline
/// and the per-set numbers as section headers satisfies both at once, and needs
/// no schema change to do it.
@interface RASubsetInfo : NSObject
@property (nonatomic, assign) uint32_t subsetID;
@property (nonatomic, copy) NSString *title;
/// The set's own badge on retroachievements.org. Nil when the server sent none.
@property (nonatomic, copy, nullable) NSString *badgeURL;
@property (nonatomic, assign) NSInteger unlocked;
@property (nonatomic, assign) NSInteger total;
@end

/// One game's progress from the all-user-progress endpoint: how many core
/// achievements the set has and how many the signed-in user unlocked (softcore).
@interface RAProgressEntry : NSObject
@property (nonatomic, assign) uint32_t gameId;
@property (nonatomic, assign) NSInteger numAchievements;
@property (nonatomic, assign) NSInteger numUnlocked;
@end

@protocol RAClientDelegate <NSObject>
/// An achievement was just earned (softcore). Celebration only — never a Pro trigger.
/// `rarity` is the % of players who have earned it (0 if unknown).
- (void)raClient:(RAClient *)client
    didUnlockAchievementTitle:(NSString *)title
                  description:(NSString *)description
                     badgeURL:(nullable NSString *)badgeURL
                       points:(NSInteger)points
                       rarity:(double)rarity;
/// A game finished identifying. `gameTitle` is nil when the ROM has no RA set
/// (unidentified). The counts + points cover EVERY core achievement the
/// dashboard lists — all active subsets merged (base set + bonus sets), NOT
/// rc_client's user-game-summary, which only counts the FIRST subset and made
/// the totals disagree with the visible list.
- (void)raClient:(RAClient *)client
   didLoadGameTitle:(nullable NSString *)gameTitle
           unlocked:(NSInteger)unlocked
              total:(NSInteger)total
       pointsEarned:(NSInteger)pointsEarned
        pointsTotal:(NSInteger)pointsTotal;
@optional
/// Every achievement in the game has been earned. rc_client's
/// `RC_CLIENT_EVENT_GAME_COMPLETED`, which we listened for nowhere until now,
/// so the app's single biggest moment passed in silence.
///
/// `masteredTitle` is the game's title. Celebration only, never a Pro trigger:
/// the same rule the unlock HUD already follows.
- (void)raClient:(RAClient *)client didMasterGameTitle:(NSString *)masteredTitle
            points:(NSInteger)points;
/// Every achievement in ONE set has been earned, where the game has several.
/// rc_client's `RC_CLIENT_EVENT_SUBSET_COMPLETED`. Fires for the base set of a
/// multi-set game too, so a player finishing the main game hears about it
/// without having to also finish the bonus sets.
- (void)raClient:(RAClient *)client didCompleteSubsetTitle:(NSString *)subsetTitle
            points:(NSInteger)points;
/// A measured (multi-step) achievement progressed, e.g. "2/151". rc_client
/// shows the indicator for a couple of seconds then sends the hide event.
/// Celebration only — mirrors the unlock HUD, never interactive.
- (void)raClient:(RAClient *)client
    didUpdateProgressIndicatorTitle:(NSString *)title
                           badgeURL:(nullable NSString *)badgeURL
                           progress:(NSString *)progress
                            percent:(double)percent;
/// The progress indicator's display window ended.
- (void)raClientDidHideProgressIndicator:(RAClient *)client;
/// Login state / score changed (login, logout, score update) — refresh UI.
- (void)raClientDidChangeUser:(RAClient *)client;
/// Connectivity changed: an unlock is pending (offline) or all pending unlocks
/// synced (back online). Read `hasPendingSync` for the current state.
- (void)raClientDidChangeConnectivity:(RAClient *)client;
/// A non-fatal server error worth surfacing (e.g. an unlock could not be sent).
- (void)raClient:(RAClient *)client didEncounterError:(NSString *)message;
@end

@interface RAClient : NSObject

@property (nonatomic, weak) id<RAClientDelegate> delegate;

@property (nonatomic, readonly, getter=isLoggedIn) BOOL loggedIn;
@property (nonatomic, readonly, getter=isGameLoaded) BOOL gameLoaded;
/// YES while a game load is in flight (identify + patch download). Lets the
/// reconnect retry avoid stacking a second load on a pending one.
@property (nonatomic, readonly, getter=isLoadInFlight) BOOL loadInFlight;
@property (nonatomic, readonly, nullable) NSString *username;
@property (nonatomic, readonly, nullable) NSString *displayName;
@property (nonatomic, readonly) NSInteger softcoreScore;
/// YES when an unlock could not be sent and is queued for retry (offline).
@property (nonatomic, readonly) BOOL hasPendingSync;

/// The loaded game's core achievements for the in-app dashboard (empty if no
/// game / no set). Built from rc_client; no Web API key required.
- (NSArray<RAAchievementInfo *> *)currentGameAchievements;

/// The sets making up the loaded game, base set first, EMPTY when the game has
/// only one set (rc_client reports `subset_id = 0` there, so there is nothing to
/// group and nothing to label).
///
/// Counts come from `rc_client_get_user_subset_summary`, which is the per-set
/// view retroachievements.org shows. Deliberately NOT a replacement for the
/// merged totals in the delegate's load callback: see `RASubsetInfo`.
- (NSArray<RASubsetInfo *> *)currentGameSubsets;

/// Box-art URL for the loaded game (from rc_client; no Web API key). nil if none.
- (nullable NSString *)currentGameBoxArtURL;

/// The loaded game's RA id (0 when no game is loaded or the ROM has no set).
- (uint32_t)currentGameID;

// MARK: - Game identification (no login required)

/// The RA console id for a ROM path, from its extension
/// (.gba/.gbc/.gb/.nds). 0 for anything else (no RA support here).
+ (uint32_t)consoleIdForROMPath:(NSString *)path;

/// Compute the RetroAchievements hash (rc_hash MD5 form) of the ROM at `path`.
/// nil when the console is unsupported or the file is unreadable. Pure file
/// I/O + CPU; safe (and preferable) to call from a background queue.
+ (nullable NSString *)hashForROMAtPath:(NSString *)path;

/// Ask the RA server which game a rc_hash belongs to. Requires NO credentials,
/// so it works before the user connects an account. `gameId` is 0 when the
/// hash matches no RA set; `success` is NO on a transport/server failure (in
/// which case gameId is meaningless and the caller should retry later).
/// The completion is invoked on the main thread.
- (void)resolveHash:(NSString *)hash
         completion:(void (^)(BOOL success, uint32_t gameId))completion;

/// Fetch the signed-in user's unlocked/total counts for every game they have
/// progress on, for one console (uses the connect token; no Web API key).
/// The completion is invoked on the main thread.
- (void)fetchAllProgressForConsole:(uint32_t)consoleId
                        completion:(void (^)(BOOL success, NSArray<RAProgressEntry *> *entries))completion;

/// `userAgentProductClause` is our STABLE product identifier, e.g.
/// "RetroPal/1.2.1 (iOS 17.0; iPhone14,2)". rcheevos' own version clause is
/// appended automatically. This string is load-bearing for the eventual
/// hardcore listing and must never change once shipped.
- (instancetype)initWithUserAgentProductClause:(NSString *)userAgentProductClause;

/// Supply the live memory reader for the active game session. Pass nil to detach
/// (e.g. when the session ends). Held strongly; the caller should capture self
/// weakly inside the block to avoid a retain cycle.
- (void)setMemoryReader:(nullable RAMemoryReader)reader;

// MARK: - Login
- (void)loginWithUsername:(NSString *)username
                 password:(NSString *)password
               completion:(RALoginCompletion)completion;
- (void)loginWithUsername:(NSString *)username
                    token:(NSString *)token
               completion:(RALoginCompletion)completion;
- (void)logout;

// MARK: - Game session
/// Identify (hash) and load the ROM at `path`. No-op if not logged in. The
/// delegate's didLoadGameTitle:… fires when identification completes.
- (void)loadGameAtPath:(NSString *)path;
- (void)unloadGame;

// MARK: - Frame loop
- (void)doFrame;  /// once per emulated frame, on the emulation thread
- (void)idle;     /// when emulation is paused, to keep the session alive

// MARK: - Save-state progress (keeps in-flight unlocks consistent across a load)
- (nullable NSData *)serializeProgress;
- (BOOL)deserializeProgress:(NSData *)data;

- (void)shutdown;

@end

NS_ASSUME_NONNULL_END
