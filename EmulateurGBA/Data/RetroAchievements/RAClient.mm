//
//  RAClient.mm
//  EmulateurGBA
//
//  Objective-C++ implementation wrapping rcheevos' rc_client. See RAClient.h.
//
//  The four rc_client callbacks (read_memory, server_call, log, events) plus the
//  time source and the login / load-game completions are static C functions at
//  the bottom of this file; each recovers the owning RAClient via
//  rc_client_get_userdata(). All async server responses are marshalled back onto
//  the main thread before re-entering rc_client, so the library only ever runs
//  single-threaded as it requires.
//

#import "RAClient.h"

// rcheevos is linked as a SwiftPM package; its public headers (Vendor/rcheevos/
// include) are on the target's header search path. We include them TEXTUALLY
// rather than `@import rcheevos;` because @import requires C++ modules, which are
// off for Objective-C++ (.mm) and which we don't want to enable (it would change
// how the melonDS C++ sources compile). RC_CLIENT_SUPPORTS_HASH must match the
// package build so the identify-and-load-by-hash API is declared here too.
#define RC_CLIENT_SUPPORTS_HASH 1
#import "rc_client.h"
#import "rc_consoles.h"
#import "rc_api_request.h"
#import "rc_api_runtime.h"
#import "rc_api_user.h"
#import "rc_error.h"
#import "rc_hash.h"

#include <time.h>
#import <os/log.h>

@implementation RAAchievementInfo
@end

@implementation RAProgressEntry
@end

// MARK: - Static C callbacks (defined after @end, forward-declared here so
// rc_client_create can reference read_memory + server_call).
static uint32_t RAReadMemory(uint32_t address, uint8_t *buffer, uint32_t num_bytes, rc_client_t *client);
static void RAServerCall(const rc_api_request_t *request, rc_client_server_callback_t callback,
                         void *callback_data, rc_client_t *client);
static rc_clock_t RAGetTimeMillisecs(const rc_client_t *client);
static void RAEventHandler(const rc_client_event_t *event, rc_client_t *client);
static void RALoginCallback(int result, const char *error_message, rc_client_t *client, void *userdata);
static void RALoadGameCallback(int result, const char *error_message, rc_client_t *client, void *userdata);
#if DEBUG
static void RALogMessage(const char *message, const rc_client_t *client);
#endif

// Debug-only [RA] tracing: bring-up logging, silent in release builds (the
// paths/titles it prints have no place in a shipping Console stream).
#if DEBUG
#define RADebugLog(...) os_log(OS_LOG_DEFAULT, __VA_ARGS__)
#else
#define RADebugLog(...)
#endif

// Private surface the static callbacks call into.
@interface RAClient ()
- (uint32_t)readRAAddress:(uint32_t)address into:(uint8_t *)buffer numBytes:(uint32_t)numBytes;
- (void)performServerCall:(const rc_api_request_t *)request
                 callback:(rc_client_server_callback_t)callback
             callbackData:(void *)callbackData;
- (void)handleEvent:(const rc_client_event_t *)event;
- (void)handleGameLoadResult:(int)result error:(const char *)error;
@end

@implementation RAClient {
    rc_client_t *_client;
    NSURLSession *_session;
    NSString *_userAgent;
    RAMemoryReader _memoryReader;
    const rc_memory_regions_t *_regions;  // cached for the loaded console
    uint32_t _consoleId;
    BOOL _gameLoaded;
    BOOL _loadInFlight;                   // identify+load started, callback pending
    BOOL _disconnected;                   // an unlock is queued for retry (offline)
}

- (BOOL)isLoadInFlight {
    return _loadInFlight;
}

- (BOOL)hasPendingSync {
    return _disconnected;
}

- (NSArray<RAAchievementInfo *> *)currentGameAchievements {
    NSMutableArray<RAAchievementInfo *> *result = [NSMutableArray array];
    if (!_client || !_gameLoaded) return result;
    rc_client_achievement_list_t *list = rc_client_create_achievement_list(
        _client, RC_CLIENT_ACHIEVEMENT_CATEGORY_CORE,
        RC_CLIENT_ACHIEVEMENT_LIST_GROUPING_LOCK_STATE);
    if (!list) return result;
    for (uint32_t b = 0; b < list->num_buckets; b++) {
        const rc_client_achievement_bucket_t *bucket = &list->buckets[b];
        for (uint32_t i = 0; i < bucket->num_achievements; i++) {
            const rc_client_achievement_t *ach = bucket->achievements[i];
            if (!ach) continue;
            // Skip rc_client's synthetic warning achievements ("Unknown Emulator",
            // "Unsupported Game Version") — they aren't real set achievements.
            // 101000001 == rc_client's private RC_CLIENT_ACHIEVEMENT_WARNING_ID.
            if (ach->id >= 101000001) continue;
            RAAchievementInfo *info = [RAAchievementInfo new];
            info.title = ach->title ? @(ach->title) : @"";
            info.detail = ach->description ? @(ach->description) : @"";
            info.points = (NSInteger)ach->points;
            // Use the server unlock FLAG, not the runtime state: when a set is
            // loaded without live memory (the Game Details display load) every
            // achievement is marked UNSUPPORTED/DISABLED, so `state` is never
            // UNLOCKED even for earned ones. `unlocked` reflects what the user
            // actually earned, regardless of trackability.
            info.unlocked = (ach->unlocked != RC_CLIENT_ACHIEVEMENT_UNLOCKED_NONE);
            info.measuredProgress = (ach->measured_progress[0] != '\0')
                ? @(ach->measured_progress) : nil;
            info.rarity = ach->rarity;  // % of players who earned it (softcore)
            char url[256] = {0};
            int state = info.unlocked ? RC_CLIENT_ACHIEVEMENT_STATE_UNLOCKED
                                      : RC_CLIENT_ACHIEVEMENT_STATE_ACTIVE;
            if (rc_client_achievement_get_image_url(ach, state, url, sizeof(url)) == RC_OK) {
                info.badgeURL = @(url);
            } else if (ach->badge_url) {
                info.badgeURL = @(ach->badge_url);
            }
            [result addObject:info];
        }
    }
    rc_client_destroy_achievement_list(list);
#if DEBUG
    const rc_client_game_t *gameForLog = rc_client_get_game_info(_client);
    RADebugLog("[RA] achievements list: game=%u \"%{public}s\" -> %lu items",
               gameForLog ? gameForLog->id : 0,
               (gameForLog && gameForLog->title) ? gameForLog->title : "(none)",
               (unsigned long)result.count);
#endif
    return result;
}

- (NSString *)currentGameBoxArtURL {
    if (!_client) return nil;
    const rc_client_game_t *game = rc_client_get_game_info(_client);
    if (!game) return nil;
    char url[256] = {0};
    if (rc_client_game_get_image_url(game, url, sizeof(url)) == RC_OK && url[0] != '\0') {
        return @(url);
    }
    return game->badge_url ? @(game->badge_url) : nil;
}

- (uint32_t)currentGameID {
    if (!_client) return 0;
    const rc_client_game_t *game = rc_client_get_game_info(_client);
    return game ? game->id : 0;
}

- (instancetype)initWithUserAgentProductClause:(NSString *)userAgentProductClause {
    self = [super init];
    if (!self) return nil;

    _client = rc_client_create(RAReadMemory, RAServerCall);
    if (!_client) return nil;
    rc_client_set_userdata(_client, (__bridge void *)self);
    rc_client_set_event_handler(_client, RAEventHandler);
    rc_client_set_get_time_millisecs_function(_client, RAGetTimeMillisecs);

    // Branch 1 is softcore only. Hardcore (which would gate our Pro actions and
    // needs RAdmin User-Agent validation) is a Branch-2 concern.
    rc_client_set_hardcore_enabled(_client, 0);

#if DEBUG
    rc_client_enable_logging(_client, RC_CLIENT_LOG_LEVEL_INFO, RALogMessage);
#endif

    // The User-Agent header is set on every request in performServerCall. It is
    // load-bearing for the eventual hardcore listing and must stay stable; we
    // append rcheevos' own version clause to our product clause.
    char rcClause[128] = {0};
    rc_client_get_user_agent_clause(_client, rcClause, sizeof(rcClause));
    _userAgent = [NSString stringWithFormat:@"%@ %s", userAgentProductClause, rcClause];

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 30;
    // Fail FAST when offline instead of parking requests until connectivity
    // returns (waitsForConnectivity made every RA surface hang forever in
    // airplane mode). rc_client owns retry for the calls that matter (queued
    // unlocks + the DISCONNECTED/RECONNECTED flow), and the UI shows explicit
    // offline states for the interactive loads.
    cfg.waitsForConnectivity = NO;
    _session = [NSURLSession sessionWithConfiguration:cfg];

    return self;
}

- (void)dealloc {
    [self shutdown];
}

- (void)setMemoryReader:(RAMemoryReader)reader {
    _memoryReader = [reader copy];
}

// MARK: - User state

- (BOOL)isLoggedIn {
    return _client && rc_client_get_user_info(_client) != NULL;
}

- (BOOL)isGameLoaded {
    return _gameLoaded;
}

- (NSString *)username {
    if (!_client) return nil;
    const rc_client_user_t *user = rc_client_get_user_info(_client);
    return (user && user->username) ? @(user->username) : nil;
}

- (NSString *)displayName {
    if (!_client) return nil;
    const rc_client_user_t *user = rc_client_get_user_info(_client);
    return (user && user->display_name) ? @(user->display_name) : nil;
}

- (NSInteger)softcoreScore {
    if (!_client) return 0;
    const rc_client_user_t *user = rc_client_get_user_info(_client);
    return user ? (NSInteger)user->score_softcore : 0;
}

// MARK: - Login

- (void)loginWithUsername:(NSString *)username
                 password:(NSString *)password
               completion:(RALoginCompletion)completion {
    // A missing client is a local condition, not a server rejection.
    if (!_client) { if (completion) completion(NO, nil, @"RA unavailable", NO); return; }
    // The completion is carried as callback_userdata; ownership transfers back
    // to ARC inside RALoginCallback via __bridge_transfer.
    void *ctx = (__bridge_retained void *)[completion copy];
    rc_client_begin_login_with_password(_client, username.UTF8String, password.UTF8String,
                                        RALoginCallback, ctx);
}

- (void)loginWithUsername:(NSString *)username
                    token:(NSString *)token
               completion:(RALoginCompletion)completion {
    if (!_client) { if (completion) completion(NO, nil, @"RA unavailable", NO); return; }
    void *ctx = (__bridge_retained void *)[completion copy];
    rc_client_begin_login_with_token(_client, username.UTF8String, token.UTF8String,
                                     RALoginCallback, ctx);
}

- (void)logout {
    if (_client) rc_client_logout(_client);
    if ([self.delegate respondsToSelector:@selector(raClientDidChangeUser:)]) {
        [self.delegate raClientDidChangeUser:self];
    }
}

// MARK: - Game session

- (void)loadGameAtPath:(NSString *)path {
    if (!_client || !self.isLoggedIn || path.length == 0) {
        RADebugLog("[RA] loadGame skipped (client=%d loggedIn=%d path=%lu)",
               _client != NULL, self.isLoggedIn, (unsigned long)path.length);
        return;
    }
    // Resolve the console + memory regions UP FRONT, from the ROM extension.
    // rc_client validates every achievement's address during load by calling
    // read_memory, which happens BEFORE the load-finished callback — so if we
    // waited until then to cache _regions, validation would read nothing and
    // disable every achievement. .gba=GBA, .gbc=GBC, .gb=GB, .nds=NDS.
    uint32_t consoleId = [RAClient consoleIdForROMPath:path];
    if (consoleId) {
        _consoleId = consoleId;
        _regions = rc_console_memory_regions(consoleId);
    }
    RADebugLog("[RA] identify+load: console=%u %{public}s", consoleId, path.UTF8String);
    _loadInFlight = YES;
    rc_client_begin_identify_and_load_game(_client, RC_CONSOLE_UNKNOWN, path.UTF8String,
                                           NULL, 0, RALoadGameCallback, NULL);
}

- (void)unloadGame {
    if (_client) rc_client_unload_game(_client);
    _gameLoaded = NO;
    _loadInFlight = NO;
    _regions = NULL;
    _consoleId = 0;
}

- (void)handleGameLoadResult:(int)result error:(const char *)error {
    _loadInFlight = NO;
    if (result == RC_OK && rc_client_is_game_loaded(_client)) {
        const rc_client_game_t *game = rc_client_get_game_info(_client);
        _consoleId = game ? game->console_id : 0;
        _regions = _consoleId ? rc_console_memory_regions(_consoleId) : NULL;
        _gameLoaded = YES;

        // Count from the SAME enumeration the dashboard lists (all active
        // subsets merged, warning ids skipped) so every surface agrees. Do NOT
        // use rc_client_get_user_game_summary: it only counts the FIRST subset
        // (the base set), which disagreed with the visible list on games with
        // merged bonus sets (e.g. FireRed's base 61 vs the full merged list).
        NSInteger unlocked = 0, total = 0, pointsEarned = 0, pointsTotal = 0;
        for (RAAchievementInfo *info in [self currentGameAchievements]) {
            total += 1;
            pointsTotal += info.points;
            if (info.unlocked) {
                unlocked += 1;
                pointsEarned += info.points;
            }
        }

        // id == 0 is rc_client's dummy record for an unidentified ROM (no set).
        BOOL identified = game && game->id != 0;
        NSString *title = (identified && game->title) ? @(game->title) : nil;
        RADebugLog(
               "[RA] loaded: identified=%d id=%u console=%u regions=%p core=%ld unlocked=%ld points=%ld/%ld title=%{public}s",
               identified, game ? game->id : 0, _consoleId, _regions,
               (long)total, (long)unlocked, (long)pointsEarned, (long)pointsTotal,
               title ? title.UTF8String : "(none)");
        [self.delegate raClient:self
               didLoadGameTitle:title
                       unlocked:unlocked
                          total:total
                   pointsEarned:pointsEarned
                    pointsTotal:pointsTotal];
    } else {
        _gameLoaded = NO;
        _regions = NULL;
        _consoleId = 0;
        RADebugLog("[RA] load FAILED result=%d error=%{public}s",
               result, error ? error : "(none)");
        [self.delegate raClient:self didLoadGameTitle:nil unlocked:0 total:0
                   pointsEarned:0 pointsTotal:0];
    }
}

// MARK: - Frame loop

- (void)doFrame {
    if (_client && _gameLoaded) rc_client_do_frame(_client);
}

- (void)idle {
    if (_client) rc_client_idle(_client);
}

// MARK: - Memory translation (RA flat address -> real bus address)

- (uint32_t)readRAAddress:(uint32_t)address into:(uint8_t *)buffer numBytes:(uint32_t)numBytes {
    if (!_regions || !_memoryReader || numBytes == 0) return 0;
    for (uint32_t i = 0; i < _regions->num_regions; i++) {
        const rc_memory_region_t *r = &_regions->region[i];
        if (address < r->start_address || address > r->end_address) continue;
        if (r->type == RC_MEMORY_TYPE_UNUSED) return 0;

        uint32_t realAddress = r->real_address + (address - r->start_address);
        // GB/GBC banked regions use synthetic real addresses (>0xFFFF) that the
        // bus reader cannot serve in Branch 1 — skip rather than feed garbage.
        if ((_consoleId == RC_CONSOLE_GAMEBOY || _consoleId == RC_CONSOLE_GAMEBOY_COLOR) &&
            realAddress > 0xFFFFu) {
            return 0;
        }

        uint32_t available = r->end_address - address + 1;
        uint32_t toRead = numBytes < available ? numBytes : available;
        NSInteger got = _memoryReader(realAddress, buffer, (NSInteger)toRead);
        return got > 0 ? (uint32_t)got : 0;
    }
    return 0;
}

// MARK: - Game identification (no login required)

+ (uint32_t)consoleIdForROMPath:(NSString *)path {
    NSString *ext = path.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"gba"]) return RC_CONSOLE_GAMEBOY_ADVANCE;
    if ([ext isEqualToString:@"gbc"]) return RC_CONSOLE_GAMEBOY_COLOR;
    if ([ext isEqualToString:@"gb"])  return RC_CONSOLE_GAMEBOY;
    if ([ext isEqualToString:@"nds"]) return RC_CONSOLE_NINTENDO_DS;
    return 0;  // everything else has no RA support here.
}

+ (NSString *)hashForROMAtPath:(NSString *)path {
    uint32_t consoleId = [self consoleIdForROMPath:path];
    if (!consoleId || path.length == 0) return nil;
    rc_hash_iterator_t iterator;
    rc_hash_initialize_iterator(&iterator, path.fileSystemRepresentation, NULL, 0);
    char hash[33] = {0};
    int generated = rc_hash_generate(hash, consoleId, &iterator);
    rc_hash_destroy_iterator(&iterator);
    return generated ? @(hash) : nil;
}

/// Send one rc_api request over the shared session. `apiRequest` only needs to
/// stay alive for the duration of this call (the NSURLRequest is built before
/// it returns), so callers can rc_api_destroy_request right after. The
/// completion runs on the main thread; `transportOK` is NO when the request
/// never produced an HTTP response (offline, DNS, timeout).
- (void)performAPIRequest:(const rc_api_request_t *)apiRequest
               completion:(void (^)(const rc_api_server_response_t *response, BOOL transportOK))completion {
    NSURL *url = apiRequest->url ? [NSURL URLWithString:@(apiRequest->url)] : nil;
    if (!url) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NULL, NO); });
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setValue:_userAgent forHTTPHeaderField:@"User-Agent"];
    if (apiRequest->post_data && apiRequest->post_data[0]) {
        req.HTTPMethod = @"POST";
        const char *ct = apiRequest->content_type ? apiRequest->content_type : "application/x-www-form-urlencoded";
        [req setValue:@(ct) forHTTPHeaderField:@"Content-Type"];
        req.HTTPBody = [NSData dataWithBytes:apiRequest->post_data length:strlen(apiRequest->post_data)];
    } else {
        req.HTTPMethod = @"GET";
    }
    NSURLSessionDataTask *task = [_session dataTaskWithRequest:req
                                            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) { completion(NULL, NO); return; }
            NSData *body = data ?: [NSData data];
            rc_api_server_response_t resp;
            memset(&resp, 0, sizeof(resp));
            resp.body = (const char *)body.bytes;
            resp.body_length = body.length;
            resp.http_status_code = (int)[(NSHTTPURLResponse *)response statusCode];
            completion(&resp, YES);
        });
    }];
    [task resume];
}

- (void)resolveHash:(NSString *)hash
         completion:(void (^)(BOOL success, uint32_t gameId))completion {
    if (hash.length == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, 0); });
        return;
    }
    rc_api_resolve_hash_request_t params;
    memset(&params, 0, sizeof(params));
    params.game_hash = hash.UTF8String;
    rc_api_request_t request;
    if (rc_api_init_resolve_hash_request(&request, &params) != RC_OK) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, 0); });
        return;
    }
    [self performAPIRequest:&request completion:^(const rc_api_server_response_t *response, BOOL transportOK) {
        if (!transportOK) { completion(NO, 0); return; }
        rc_api_resolve_hash_response_t resolved;
        int processed = rc_api_process_resolve_hash_server_response(&resolved, response);
        BOOL ok = (processed == RC_OK && resolved.response.succeeded);
        uint32_t gameId = ok ? resolved.game_id : 0;
        RADebugLog("[RA] resolve hash %{public}@ -> ok=%d gameId=%u", hash, ok, gameId);
        completion(ok, gameId);
        rc_api_destroy_resolve_hash_response(&resolved);
    }];
    rc_api_destroy_request(&request);
}

- (void)fetchAllProgressForConsole:(uint32_t)consoleId
                        completion:(void (^)(BOOL success, NSArray<RAProgressEntry *> *entries))completion {
    const rc_client_user_t *user = _client ? rc_client_get_user_info(_client) : NULL;
    if (!user || !user->username || !user->token) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, @[]); });
        return;
    }
    rc_api_fetch_all_user_progress_request_t params;
    memset(&params, 0, sizeof(params));
    params.username = user->username;
    params.api_token = user->token;
    params.console_id = consoleId;
    rc_api_request_t request;
    if (rc_api_init_fetch_all_user_progress_request(&request, &params) != RC_OK) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, @[]); });
        return;
    }
    [self performAPIRequest:&request completion:^(const rc_api_server_response_t *response, BOOL transportOK) {
        if (!transportOK) { completion(NO, @[]); return; }
        rc_api_fetch_all_user_progress_response_t progress;
        int processed = rc_api_process_fetch_all_user_progress_server_response(&progress, response);
        if (processed != RC_OK || !progress.response.succeeded) {
            completion(NO, @[]);
            rc_api_destroy_fetch_all_user_progress_response(&progress);
            return;
        }
        NSMutableArray<RAProgressEntry *> *entries = [NSMutableArray arrayWithCapacity:progress.num_entries];
        for (uint32_t i = 0; i < progress.num_entries; i++) {
            RAProgressEntry *entry = [RAProgressEntry new];
            entry.gameId = progress.entries[i].game_id;
            entry.numAchievements = (NSInteger)progress.entries[i].num_achievements;
            entry.numUnlocked = (NSInteger)progress.entries[i].num_unlocked_achievements;
            [entries addObject:entry];
        }
        RADebugLog("[RA] all-progress console=%u -> %lu entries",
               consoleId, (unsigned long)entries.count);
        completion(YES, entries);
        rc_api_destroy_fetch_all_user_progress_response(&progress);
    }];
    rc_api_destroy_request(&request);
}

// MARK: - HTTP

- (void)performServerCall:(const rc_api_request_t *)request
                 callback:(rc_client_server_callback_t)callback
             callbackData:(void *)callbackData {
    NSURL *url = request->url ? [NSURL URLWithString:@(request->url)] : nil;
    if (!url) {
        rc_api_server_response_t resp;
        memset(&resp, 0, sizeof(resp));
        callback(&resp, callbackData);  // http_status_code 0 => rc_client treats as failure
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setValue:_userAgent forHTTPHeaderField:@"User-Agent"];
    if (request->post_data && request->post_data[0]) {
        req.HTTPMethod = @"POST";
        const char *ct = request->content_type ? request->content_type : "application/x-www-form-urlencoded";
        [req setValue:@(ct) forHTTPHeaderField:@"Content-Type"];
        req.HTTPBody = [NSData dataWithBytes:request->post_data length:strlen(request->post_data)];
    } else {
        req.HTTPMethod = @"GET";
    }

    NSURLSessionDataTask *task = [_session dataTaskWithRequest:req
                                            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        // Re-enter rc_client only on the main thread (it is not thread-safe).
        dispatch_async(dispatch_get_main_queue(), ^{
            NSData *body = data ?: [NSData data];
            rc_api_server_response_t resp;
            memset(&resp, 0, sizeof(resp));
            resp.body = (const char *)body.bytes;
            resp.body_length = body.length;
            resp.http_status_code = error ? 0 : (int)[(NSHTTPURLResponse *)response statusCode];
            callback(&resp, callbackData);
        });
    }];
    [task resume];
}

// MARK: - Events

- (void)handleEvent:(const rc_client_event_t *)event {
    switch (event->type) {
        case RC_CLIENT_EVENT_ACHIEVEMENT_TRIGGERED: {
            const rc_client_achievement_t *ach = event->achievement;
            if (!ach) break;
            NSString *title = ach->title ? @(ach->title) : @"";
            NSString *desc = ach->description ? @(ach->description) : @"";
            NSString *badge = (ach->badge_url && ach->badge_url[0]) ? @(ach->badge_url) : nil;
            [self.delegate raClient:self
          didUnlockAchievementTitle:title
                        description:desc
                           badgeURL:badge
                             points:(NSInteger)ach->points
                             rarity:ach->rarity];
            break;
        }
        case RC_CLIENT_EVENT_ACHIEVEMENT_PROGRESS_INDICATOR_SHOW:
        case RC_CLIENT_EVENT_ACHIEVEMENT_PROGRESS_INDICATOR_UPDATE: {
            const rc_client_achievement_t *ach = event->achievement;
            if (!ach || ach->measured_progress[0] == '\0') break;
            if (![self.delegate respondsToSelector:
                    @selector(raClient:didUpdateProgressIndicatorTitle:badgeURL:progress:percent:)]) break;
            // The locked badge variant: the achievement is in progress, not earned.
            NSString *badge = nil;
            char url[256] = {0};
            if (rc_client_achievement_get_image_url(ach, RC_CLIENT_ACHIEVEMENT_STATE_ACTIVE,
                                                    url, sizeof(url)) == RC_OK && url[0] != '\0') {
                badge = @(url);
            }
            [self.delegate raClient:self
    didUpdateProgressIndicatorTitle:(ach->title ? @(ach->title) : @"")
                           badgeURL:badge
                           progress:@(ach->measured_progress)
                            percent:(double)ach->measured_percent];
            break;
        }
        case RC_CLIENT_EVENT_ACHIEVEMENT_PROGRESS_INDICATOR_HIDE: {
            if ([self.delegate respondsToSelector:@selector(raClientDidHideProgressIndicator:)]) {
                [self.delegate raClientDidHideProgressIndicator:self];
            }
            break;
        }
        case RC_CLIENT_EVENT_DISCONNECTED: {
            // An unlock couldn't be sent; rc_client queues it and retries. Surface
            // a "pending sync" state rather than an error — nothing is lost.
            _disconnected = YES;
            if ([self.delegate respondsToSelector:@selector(raClientDidChangeConnectivity:)]) {
                [self.delegate raClientDidChangeConnectivity:self];
            }
            break;
        }
        case RC_CLIENT_EVENT_RECONNECTED: {
            _disconnected = NO;
            if ([self.delegate respondsToSelector:@selector(raClientDidChangeConnectivity:)]) {
                [self.delegate raClientDidChangeConnectivity:self];
            }
            break;
        }
        case RC_CLIENT_EVENT_SERVER_ERROR: {
            if ([self.delegate respondsToSelector:@selector(raClient:didEncounterError:)]) {
                [self.delegate raClient:self
                      didEncounterError:NSLocalizedString(@"ra.error.server",
                                                          @"RetroAchievements request failed")];
            }
            break;
        }
        default:
            break;
    }
}

// MARK: - Save-state progress

- (NSData *)serializeProgress {
    if (!_client || !_gameLoaded) return nil;
    size_t size = rc_client_progress_size(_client);
    if (size == 0) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:size];
    int r = rc_client_serialize_progress_sized(_client, (uint8_t *)data.mutableBytes, size);
    return (r == RC_OK) ? data : nil;
}

- (BOOL)deserializeProgress:(NSData *)data {
    if (!_client || !_gameLoaded || data.length == 0) return NO;
    int r = rc_client_deserialize_progress_sized(_client, (const uint8_t *)data.bytes, data.length);
    return r == RC_OK;
}

// MARK: - Lifecycle

- (void)shutdown {
    if (_client) {
        rc_client_destroy(_client);
        _client = NULL;
    }
    _memoryReader = nil;
    _regions = NULL;
    _gameLoaded = NO;
}

@end

// MARK: - Static C callback definitions

static uint32_t RAReadMemory(uint32_t address, uint8_t *buffer, uint32_t num_bytes, rc_client_t *client) {
    RAClient *self = (__bridge RAClient *)rc_client_get_userdata(client);
    if (!self) return 0;
    return [self readRAAddress:address into:buffer numBytes:num_bytes];
}

static void RAServerCall(const rc_api_request_t *request, rc_client_server_callback_t callback,
                         void *callback_data, rc_client_t *client) {
    RAClient *self = (__bridge RAClient *)rc_client_get_userdata(client);
    [self performServerCall:request callback:callback callbackData:callback_data];
}

static rc_clock_t RAGetTimeMillisecs(const rc_client_t *client) {
    (void)client;
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (rc_clock_t)ts.tv_sec * 1000 + (rc_clock_t)(ts.tv_nsec / 1000000);
}

static void RAEventHandler(const rc_client_event_t *event, rc_client_t *client) {
    RAClient *self = (__bridge RAClient *)rc_client_get_userdata(client);
    [self handleEvent:event];
}

static void RALoginCallback(int result, const char *error_message, rc_client_t *client, void *userdata) {
    // Ownership of the completion block transfers back to ARC here.
    RALoginCompletion completion = (__bridge_transfer RALoginCompletion)userdata;
    RAClient *self = (__bridge RAClient *)rc_client_get_userdata(client);
    if (result == RC_OK) {
        const rc_client_user_t *user = rc_client_get_user_info(client);
        NSString *token = (user && user->token) ? @(user->token) : nil;
        if ([self.delegate respondsToSelector:@selector(raClientDidChangeUser:)]) {
            [self.delegate raClientDidChangeUser:self];
        }
        if (completion) completion(YES, token, nil, NO);
    } else {
        // Only these mean the SERVER refused the credentials; anything else
        // (RC_NO_RESPONSE, timeouts, API failures) is transport-shaped and
        // must not cost the user their stored token.
        BOOL rejected = (result == RC_INVALID_CREDENTIALS
                         || result == RC_EXPIRED_TOKEN
                         || result == RC_ACCESS_DENIED);
        NSString *err = error_message ? @(error_message)
                                      : NSLocalizedString(@"ra.error.login", @"Login failed");
        if (completion) completion(NO, nil, err, rejected);
    }
}

static void RALoadGameCallback(int result, const char *error_message, rc_client_t *client, void *userdata) {
    (void)userdata;
    RAClient *self = (__bridge RAClient *)rc_client_get_userdata(client);
    [self handleGameLoadResult:result error:error_message];
}

#if DEBUG
static void RALogMessage(const char *message, const rc_client_t *client) {
    (void)client;
    os_log(OS_LOG_DEFAULT, "[RA] %{public}s", message ? message : "");
}
#endif
