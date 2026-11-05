//
//  ZIPWriter.swift
//  EmulateurGBA
//
//  The smallest ZIP writer that every unzip reads: STORED entries (no
//  compression), one local header and one central-directory record each, no
//  ZIP64. For archives that are small FOLDERS, a Nintendo 3DS game's save data
//  (`CTRSaveData`, a few kilobytes to a few megabytes), where Files, the
//  share sheet and other emulators expect a `.zip` and compression would buy
//  nothing worth a dependency. `ZIPExtractor` reads them back.
//

import Foundation

enum ZIPWriter {

    enum WriteError: Error {
        /// A file over 4 GB or more than 65 535 entries: ZIP64 territory, which
        /// a save never reaches and this writer does not do.
        case tooLarge
        case cannotRead(String)
        case cannotWrite
    }

    /// Writes every regular file under `directory` into `zipURL`, named by its
    /// path relative to `directory` (with `/`), in a stable (sorted) order,
    /// and every EMPTY folder as a folder entry (`name/`): a 3DS extdata's
    /// `boss/` is usually empty, and the core does not open an extdata
    /// without it (audit, 2026-10-20). Hidden files (`.DS_Store` and the like)
    /// are left out.
    /// `extra`: further folders, each written under its name prefix (`"extdata/"`
    /// puts a folder's files under `extdata/…`), a folder that does not exist
    /// skipped. `literal`: small files given as bytes, under their name.
    static func zipFolder(_ directory: URL, to zipURL: URL,
                          extra: [(prefix: String, folder: URL)] = [],
                          literal: [(name: String, contents: Data)] = []) throws {
        var files: [(name: String, url: URL?, contents: Data?)] = literal.map { ($0.name, nil, $0.contents) }
        func collect(_ folder: URL, prefix: String) {
            let base = folder.standardizedFileURL.path
            guard let walker = FileManager.default.enumerator(at: folder,
                                                              includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                                                              options: [.skipsHiddenFiles]) else { return }
            for case let url as URL in walker {
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(base + "/") else { continue }
                let name = prefix + String(path.dropFirst(base.count + 1))
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                if values?.isDirectory == true {
                    let children = (try? FileManager.default.contentsOfDirectory(
                        at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                    if children.isEmpty { files.append((name + "/", nil, Data())) }
                    continue
                }
                guard values?.isRegularFile == true else { continue }
                files.append((name, url, nil))
            }
        }
        collect(directory, prefix: "")
        for (prefix, folder) in extra { collect(folder, prefix: prefix) }
        files.sort { $0.name < $1.name }
        guard files.count <= 0xFFFF else { throw WriteError.tooLarge }

        var archive = Data()
        var central = Data()
        for file in files {
            guard let contents = file.contents ?? file.url.flatMap({ try? Data(contentsOf: $0) }) else {
                throw WriteError.cannotRead(file.name)
            }
            guard contents.count < 0xFFFF_FFFF, archive.count < 0xFFFF_FFFF else { throw WriteError.tooLarge }
            let name = Data(file.name.utf8)
            let crc = ZIPExtractor.crc32(contents)
            let offset = UInt32(archive.count)
            let size = UInt32(contents.count)

            // Local file header (APPNOTE 4.3.7). Bit 11: the name is UTF-8.
            archive.append(u32: 0x04034b50)
            archive.append(u16: 20)            // version needed: 2.0
            archive.append(u16: 0x0800)        // flags: UTF-8 name
            archive.append(u16: 0)             // method: stored
            archive.append(u16: 0)             // mod time
            archive.append(u16: 0x21)          // mod date: 1980-01-01, so equal folders zip to equal bytes
            archive.append(u32: crc)
            archive.append(u32: size)
            archive.append(u32: size)
            archive.append(u16: UInt16(name.count))
            archive.append(u16: 0)             // extra length
            archive.append(name)
            archive.append(contents)

            // Central directory record (APPNOTE 4.3.12).
            central.append(u32: 0x02014b50)
            central.append(u16: 20)            // version made by
            central.append(u16: 20)            // version needed
            central.append(u16: 0x0800)
            central.append(u16: 0)
            central.append(u16: 0)
            central.append(u16: 0x21)
            central.append(u32: crc)
            central.append(u32: size)
            central.append(u32: size)
            central.append(u16: UInt16(name.count))
            central.append(u16: 0)             // extra length
            central.append(u16: 0)             // comment length
            central.append(u16: 0)             // disk number
            central.append(u16: 0)             // internal attributes
            central.append(u32: 0)             // external attributes
            central.append(u32: offset)
            central.append(name)
        }
        guard archive.count < 0xFFFF_FFFF else { throw WriteError.tooLarge }
        let centralOffset = UInt32(archive.count)
        archive.append(central)
        // End of central directory (APPNOTE 4.3.16).
        archive.append(u32: 0x06054b50)
        archive.append(u16: 0)
        archive.append(u16: 0)
        archive.append(u16: UInt16(files.count))
        archive.append(u16: UInt16(files.count))
        archive.append(u32: UInt32(central.count))
        archive.append(u32: centralOffset)
        archive.append(u16: 0)
        do {
            try archive.write(to: zipURL, options: .atomic)
        } catch {
            throw WriteError.cannotWrite
        }
    }
}

private extension Data {
    mutating func append(u16 value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }
    mutating func append(u32 value: UInt32) {
        append(u16: UInt16(value & 0xFFFF))
        append(u16: UInt16(value >> 16))
    }
}
