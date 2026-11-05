//
//  CTRGameProbe.h
//  EmulateurGBA
//
//  What a Nintendo 3DS game file is, read from its bytes: whether it is one at
//  all, and whether it is ENCRYPTED.
//
//  WHY THE APP READS IT ITSELF. Retro Pal ships no console keys (decided
//  2026-10-16), and Azahar reads decrypted games only. An encrypted game is
//  the case a player will meet most, and the core does not say so clearly: on
//  a `.3ds` it stops on its metadata first and answers "Failed to load ROM
//  metadata." (measured on the host, 2026-10-19). The app can say exactly what
//  is wrong, at import, before a game that can never start is filed.
//
//  THE TEST IS AZAHAR'S OWN (core/file_sys/ncch_container.cpp, LoadHeader):
//  the game's NCCH header carries a `no_crypto` flag (flags[7], bit 2), and a
//  game without it is refused. A `.3ds` / `.cci` is an NCSD (its magic at
//  0x100) whose first partition, the game, starts at the partition table's
//  first offset times 0x200; a `.cxi` / `.app` is an NCCH at offset 0; a
//  `.3dsx` is a homebrew executable, never encrypted.
//
//  ONE implementation, in C, read by the Swift importer (through the bridging
//  header) and by CTRBridge. Reads two 512-byte blocks: safe on a 4 GB image.
//

#ifndef CTRGameProbe_h
#define CTRGameProbe_h

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    /// Not a 3DS game Retro Pal recognises (no NCSD, NCCH or 3DSX magic, or a
    /// file that cannot be read).
    CTRGameProbeNotCTR = 0,
    /// A 3DS game the core can read: a decrypted NCSD / NCCH, or a `.3dsx`.
    CTRGameProbeDecrypted = 1,
    /// A 3DS game that is encrypted: the core cannot read it, and Retro Pal
    /// ships no keys to decrypt it.
    CTRGameProbeEncrypted = 2,
} CTRGameProbeAnswer;

/// The file's bytes alone.
CTRGameProbeAnswer CTRGameProbeRead(const char *path);

/// The game's title ID (its NCCH's program_id, NCCH + 0x118), which is the
/// name of its save folder on the emulated SD card
/// (`title/<high 8 hex>/<low 8 hex>/data`, Azahar's GetSaveDataPath). 0 for a
/// file that is not a 3DS game and for a `.3dsx`, which has no title ID (the
/// core runs homebrew as title 0, and homebrew keeps its files on the SD card
/// itself).
unsigned long long CTRGameProbeReadTitleID(const char *path);

/// The game's own extra save data ("extdata") ID, from its decrypted extended
/// header (`ext_save_data_id`, as Azahar's NCCHContainer::ReadExtdataId reads
/// it): the folder `extdata/<high 8 hex>/<low 8 hex>` on the emulated SD card,
/// where many games keep content beside their save (Pokémon Sun: 0x1648). 0
/// when the game has none, for a `.3dsx`, for an encrypted file, and for a
/// game with extended save data access (several IDs, not guessed).
unsigned long long CTRGameProbeReadExtdataID(const char *path);

#ifdef __cplusplus
}
#endif

#endif /* CTRGameProbe_h */
