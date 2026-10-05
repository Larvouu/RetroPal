//
//  ThirdPartyLicensesView.swift
//  EmulateurGBA
//
//  Every licence the software inside Retro Pal is distributed under, one page
//  per licence text (asked 2026-09-27). The Legal page names the five engines;
//  this is where their licences, and those of everything compiled in with them,
//  are given in full, which MIT, BSD, zlib and Apache-2.0 ask of a binary.
//
//  THE LIST IS AN INVENTORY OF WHAT IS COMPILED, not of what is on disk. It was
//  established on 2026-09-27 from the build inputs themselves (the Xcode
//  project's link list, each core's build script, mGBA's unity files and its
//  config header, the MoltenVK archive's own symbols): a library present in a
//  submodule and not built (mGBA's libpng, melonDS's libslirp, GLideN64) is not
//  here, and must not be. Adding a core or a dependency means adding it here.
//
//  The licence texts are bundled files (`Resources/Licenses`), copied verbatim
//  from the components' own licence files; MIT, BSD-2, BSD-3 and zlib are
//  written once, in their standard wording, and each component's own copyright
//  lines are shown beside it, which is what those licences require. Licence
//  texts and copyright lines stay in English, their legal form; only the page
//  around them is localized.
//

import SwiftUI

struct ThirdPartyLicense: Identifiable {
    struct Component: Hashable {
        let name: String
        let notices: [String]
    }
    let id: String
    let name: String
    /// The bundled text, `Resources/Licenses/<file>.txt`. nil where no text is
    /// owed (the public-domain credits) or where a link is the licence's own
    /// way of being given (Creative Commons).
    let file: String?
    /// An English note under the components, for what a text cannot say.
    let note: String?
    let components: [Component]

    private static func c(_ name: String, _ notices: String...) -> Component {
        Component(name: name, notices: notices)
    }

    static let all: [ThirdPartyLicense] = [
        ThirdPartyLicense(
            id: "gpl-3.0", name: "GNU General Public License v3.0", file: "license-gpl-3.0",
            note: nil,
            components: [
                c("Retro Pal", "Copyright (c) 2026 Retro Pal"),
                c("melonDS", "Copyright 2016-2025 melonDS team", "Copyright 2020 PoroCYon"),
                c("MesenCE", "Copyright (C) 2014-2026 Sour, 2026 contributors"),
                c("xBRZ (in MesenCE), with its authors' special exception, stated in its source",
                  "Copyright (C) Zenju"),
                c("2xSaI, Super2xSaI and SuperEagle (in MesenCE)",
                  "Copyright (C) 2010-2014 Hans-Kristian Arntzen",
                  "Copyright (C) 2011-2014 Daniel De Matteis"),
            ]),
        ThirdPartyLicense(
            id: "gpl-2.0", name: "GNU General Public License v2.0 or later", file: "license-gpl-2.0",
            note: nil,
            components: [
                c("PCSX-ReARMed",
                  "Copyright (C) 2007 Ryan Schultz, PCSX-df Team, PCSX team",
                  "Copyright (C) 2009 Wei Mingzhi",
                  "Copyright (C) 2009-2010 PCSX-Revolution Dev Team",
                  "Copyright (C) 2010 by Blade_Arma",
                  "Copyright (C) 2010 Gabriele Gorla",
                  "Copyright (c) 2002 Pete Bernert",
                  "Copyright (C) SPU2-X, gigaherz, Pcsx2 Development Team",
                  "Copyright (C) 2011 Gilead Kutnick \"Exophase\"",
                  "Copyright (C) 2010-2026 Gražvydas \"notaz\" Ignotas"),
                c("Mupen64Plus-Next",
                  "Copyright (C) 2002 Hacktarux",
                  "Copyright (C) 2008-2009 Richard Goedeken",
                  "Copyright (C) 2008 Ebenblues Nmn Okaygo Tillin9",
                  "Copyright (C) 2012 CasualJames",
                  "Copyright (C) 2012-2014 Bobby Smiles",
                  "Copyright (C) 2020 M4xw"),
                c("Scale2x (in MesenCE)", "Copyright (C) 2001-2004 Andrea Mazzoleni"),
                c("ZMBV codec and AVI writer (in MesenCE)", "Copyright (C) 2002-2011 The DOSBox Team"),
            ]),
        ThirdPartyLicense(
            id: "lgpl-2.1", name: "GNU Lesser General Public License v2.1 or later",
            file: "license-lgpl-2.1", note: nil,
            components: [
                c("blip_buf (in melonDS and MesenCE)", "Copyright (C) 2003-2009 Shay Green"),
                c("nes_ntsc, snes_ntsc and sms_ntsc (in MesenCE)", "Copyright (C) 2006-2007 Shay Green"),
                c("HQX (in MesenCE)", "Copyright (C) 2003 Maxim Stepin", "Copyright (C) 2010 Cameron Zemek"),
            ]),
        ThirdPartyLicense(
            id: "mpl-2.0", name: "Mozilla Public License 2.0", file: "license-mpl-2.0", note: nil,
            components: [
                c("mGBA", "Copyright (c) 2013-2025 Jeffrey Pfau", "Copyright (c) 2016 taizou"),
            ]),
        ThirdPartyLicense(
            id: "mit", name: "MIT License", file: "license-mit", note: nil,
            components: [
                c("ParaLLEl-RDP (in Mupen64Plus-Next)",
                  "Copyright (c) 2020-2021 Themaister",
                  "Copyright (c) 2017-2022 Hans-Kristian Arntzen"),
                c("volk (in ParaLLEl-RDP)", "Copyright (c) 2018-2022 Arseny Kapoulkine"),
                c("libretro-common (in PCSX-ReARMed and Mupen64Plus-Next)",
                  "Copyright (C) 2010-2024 The RetroArch team"),
                c("rcheevos", "Copyright (c) 2018 RetroAchievements.org"),
                c("TelemetryDeck Swift SDK", "Copyright (c) 2020 Daniel Jilg"),
                c("teakra (in melonDS)", "Copyright (c) 2018 Weiyi Wang"),
                c("miniz 3.1.1 (in PCSX-ReARMed)",
                  "Copyright 2013-2014 RAD Game Tools and Valve Software",
                  "Copyright 2010-2014 Rich Geldreich and Tenacious Software LLC"),
                c("magic_enum (in MesenCE)", "Copyright (c) 2019-2022 Daniil Goncharov"),
                c("Lua (in MesenCE)", "Copyright (C) 1994-2025 Lua.org, PUC-Rio"),
                c("LuaSocket (in MesenCE)", "Copyright (C) 2004-2022 Diego Nehab"),
                c("emu2413 (in MesenCE)", "Copyright (c) 2001-2019 Mitsutaka Okazaki"),
                c("stb_vorbis (in MesenCE)", "Copyright (c) 2017 Sean Barrett"),
                c("SSE2NEON (in Mupen64Plus-Next)",
                  "John W. Ratcliff, Brandon Rowlett, Ken Fast and the SSE2NEON contributors"),
                c("SPIRV-Headers (in MoltenVK)", "Copyright (c) 2015-2024 The Khronos Group Inc."),
            ]),
        ThirdPartyLicense(
            id: "bsd-2-clause", name: "BSD 2-Clause License", file: "license-bsd-2-clause", note: nil,
            components: [
                c("xxHash (in melonDS)", "Copyright (C) 2012-2023 Yann Collet"),
                c("FreeBIOS (in melonDS)", "Copyright (c) 2013, Gilead Kutnick"),
                c("libspng (in MesenCE)", "Copyright (c) 2018-2023, Randy <randy408@protonmail.com>"),
                c("n64_cic_nus_6105 (in Mupen64Plus-Next)", "Copyright 2011 X-Scale. All rights reserved."),
            ]),
        ThirdPartyLicense(
            id: "bsd-3-clause", name: "BSD 3-Clause License", file: "license-bsd-3-clause", note: nil,
            components: [
                c("inih (in mGBA)", "Copyright (c) 2009-2020, Ben Hoyt"),
                c("libchdr (in PCSX-ReARMed)", "Copyright Romain Tisserand", "Copyright Aaron Giles"),
                c("Zstandard (in PCSX-ReARMed)", "Copyright (c) Meta Platforms, Inc. and affiliates."),
                c("ymfm (in MesenCE)", "Copyright (c) 2021, Aaron Giles"),
                c("KISS FFT (in MesenCE)", "Copyright (c) 2003-2010, Mark Borgerding. All rights reserved."),
                c("GTE divider (in PCSX-ReARMed)", "Copyright 2003-2013 smf"),
                c("cereal (in MoltenVK)", "Copyright (c) 2013-2022, Randolph Voorhies, Shane Grant"),
            ]),
        ThirdPartyLicense(
            id: "zlib", name: "zlib License", file: "license-zlib", note: nil,
            components: [
                c("zlib (in Mupen64Plus-Next)", "Copyright (C) 1995-2013 Jean-loup Gailly and Mark Adler"),
                c("Minizip (in Mupen64Plus-Next), its encryption code derived from Info-ZIP",
                  "Copyright (C) 1998-2010 Gilles Vollant",
                  "Copyright (C) 2007-2008 Even Rouault",
                  "Copyright (C) 2009-2010 Mathias Svensson"),
                c("MD5 (in Mupen64Plus-Next and rcheevos)",
                  "Copyright (C) 1999, 2000, 2002 Aladdin Enterprises. All rights reserved."),
                c("CRC32 (in MesenCE)", "Copyright (c) 2011-2016 Stephan Brumme"),
                c("GBA multiplication (in MesenCE)", "Copyright (c) 2024 zaydlang"),
            ]),
        ThirdPartyLicense(
            id: "libpng-2.0", name: "PNG Reference Library License version 2",
            file: "license-libpng-2.0", note: nil,
            components: [
                c("libpng SIMD filters (in MesenCE's libspng)",
                  "Copyright (c) 1995-2019 The PNG Reference Library Authors",
                  "Copyright (c) 2018-2019 Cosmin Truta",
                  "Copyright (c) 2000-2002, 2004, 2006-2018 Glenn Randers-Pehrson",
                  "Copyright (c) 1996-1997 Andreas Dilger",
                  "Copyright (c) 1995-1996 Guy Eric Schalnat, Group 42, Inc."),
            ]),
        ThirdPartyLicense(
            id: "apache-2.0", name: "Apache License 2.0", file: "license-apache-2.0", note: nil,
            components: [
                c("MoltenVK",
                  "Copyright (c) 2015-2026 The Brenwill Workshop Ltd.",
                  "Copyright (c) 2012-2026 Dr. Torsten Hans",
                  "Copyright (c) 2018-2026 Chip Davis for CodeWeavers",
                  "Copyright (c) 2023-2026 Evan Tang for CodeWeavers"),
                c("SPIRV-Cross (in MoltenVK)", "Copyright the SPIRV-Cross authors"),
                c("SPIRV-Tools (in MoltenVK)", "Copyright the SPIRV-Tools authors"),
                c("Vulkan-Headers (in MoltenVK and ParaLLEl-RDP)",
                  "Copyright 2015-2026 The Khronos Group Inc."),
            ]),
        ThirdPartyLicense(
            id: "cc0-1.0", name: "CC0 1.0 Universal", file: "license-cc0-1.0", note: nil,
            components: [
                c("cxd4 RSP (in Mupen64Plus-Next)", "By Iconoclast"),
            ]),
        ThirdPartyLicense(
            id: "public-domain", name: "Public domain, and credits", file: nil,
            note: "These components were placed in the public domain by their authors, or ask only to be credited, which this list does.",
            components: [
                c("MurmurHash3 (in mGBA)", "Austin Appleby"),
                c("CRC-32 (in mGBA)", "Gary S. Brown"),
                c("SHA-1 (in melonDS and MesenCE)", "Steve Reid"),
                c("tiny-AES-c (in melonDS and rcheevos)", "kokke"),
                c("miniz 1.15 (in MesenCE)", "Rich Geldreich"),
                c("gif.h (in MesenCE)", "Charlie Tangora"),
                c("LZMA SDK (in MesenCE and PCSX-ReARMed)", "Igor Pavlov"),
                c("S-DD1 decompressor (in MesenCE)", "Andreas Naive"),
                c("dr_flac (in PCSX-ReARMed)", "David Reid"),
                c("libco for 64-bit ARM (in Mupen64Plus-Next)", "webgeek1234"),
                c("Hermite resampler (in MesenCE)", "Paul Bourke"),
            ]),
        ThirdPartyLicense(
            id: "cc-by-sa-4.0", name: "Creative Commons Attribution-ShareAlike 4.0 (data)", file: nil,
            note: "Retro Pal's cheat code index and box art index are adapted from libretro-database (github.com/libretro/libretro-database), whose data is licensed under CC BY-SA 4.0, and are shared under the same license: creativecommons.org/licenses/by-sa/4.0",
            components: [
                c("libretro-database", "The libretro-database contributors"),
            ]),
    ]

    /// The bundled text, read once when a page opens. nil for an entry
    /// without one, or a file missing from the bundle.
    var text: String? {
        guard let file,
              let url = Bundle.main.url(forResource: file, withExtension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// The list: one row per licence text, each opening its own page.
struct ThirdPartyLicensesView: View {
    var body: some View {
        LandscapeListSwitch(title: NSLocalizedString("legal.thirdParty.title", comment: "")) {
            List {
                Section {
                    ForEach(ThirdPartyLicense.all) { licence in
                        NavigationLink(destination: LicenseTextView(licence: licence)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(licence.name)
                                    .font(.subheadline)
                                Text(licence.components.map(\.name)
                                        .map { $0.components(separatedBy: " (").first ?? $0 }
                                        .joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                } footer: {
                    Text(NSLocalizedString("legal.thirdParty.caption", comment: ""))
                }
                .landscapeGlassRow()
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle(NSLocalizedString("legal.thirdParty.title", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One licence: who uses it, with their copyright lines, then its full text.
struct LicenseTextView: View {
    let licence: ThirdPartyLicense
    @State private var text: String?

    var body: some View {
        LandscapeListSwitch(title: licence.name) {
            List {
                Section {
                    ForEach(licence.components, id: \.self) { component in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(component.name)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            ForEach(component.notices, id: \.self) { notice in
                                Text(notice)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    if let note = licence.note {
                        Text(note)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text(NSLocalizedString("legal.thirdParty.usedBy", comment: ""))
                }
                .landscapeGlassRow()

                if let text {
                    Section {
                        Text(text)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    } header: {
                        Text(NSLocalizedString("legal.thirdParty.fullText", comment: ""))
                    }
                    .landscapeGlassRow()
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle(licence.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if text == nil { text = licence.text } }
    }
}
