import Foundation

// MARK: - ZipArchiveWriter
/// The smallest ZIP writer a `.pkpass` needs: entries are stored
/// uncompressed (ZIP method 0 — Wallet reads any standard archive, and
/// the PNGs inside are already compressed), timestamps are fixed, and
/// entries keep their given order, so identical inputs give identical
/// bytes. No external dependency, builds everywhere AtmoCore does.
public enum ZipArchiveWriter {

    public struct Entry: Sendable, Equatable {
        public var name: String
        public var data: Data

        public init(name: String, data: Data) {
            self.name = name
            self.data = data
        }
    }

    /// The archive bytes for `entries` (local headers, central directory,
    /// end-of-central-directory record).
    public static func archive(_ entries: [Entry]) -> Data {
        var out = Data()
        var central = Data()
        // 1980-01-01 00:00 in MS-DOS packed form — the format's epoch.
        let dosTime: UInt16 = 0
        let dosDate: UInt16 = 0x0021

        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(out.count)

            // Local file header.
            out.append(le32(0x0403_4b50))
            out.append(le16(20))            // version needed: 2.0
            out.append(le16(0x0800))        // flags: UTF-8 names
            out.append(le16(0))             // method: stored
            out.append(le16(dosTime))
            out.append(le16(dosDate))
            out.append(le32(crc))
            out.append(le32(size))          // compressed
            out.append(le32(size))          // uncompressed
            out.append(le16(UInt16(name.count)))
            out.append(le16(0))             // extra length
            out.append(name)
            out.append(entry.data)

            // Central directory record.
            central.append(le32(0x0201_4b50))
            central.append(le16(20))        // version made by
            central.append(le16(20))        // version needed
            central.append(le16(0x0800))
            central.append(le16(0))
            central.append(le16(dosTime))
            central.append(le16(dosDate))
            central.append(le32(crc))
            central.append(le32(size))
            central.append(le32(size))
            central.append(le16(UInt16(name.count)))
            central.append(le16(0))         // extra length
            central.append(le16(0))         // comment length
            central.append(le16(0))         // disk number start
            central.append(le16(0))         // internal attributes
            central.append(le32(0))         // external attributes
            central.append(le32(offset))
            central.append(name)
        }

        let centralOffset = UInt32(out.count)
        out.append(central)

        // End of central directory.
        out.append(le32(0x0605_4b50))
        out.append(le16(0))                 // this disk
        out.append(le16(0))                 // disk with central dir
        out.append(le16(UInt16(entries.count)))
        out.append(le16(UInt16(entries.count)))
        out.append(le32(UInt32(central.count)))
        out.append(le32(centralOffset))
        out.append(le16(0))                 // comment length
        return out
    }

    // MARK: CRC-32 (IEEE 802.3, as ZIP uses)

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static func le16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    private static func le32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)])
    }
}
