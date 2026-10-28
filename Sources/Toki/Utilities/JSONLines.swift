import Foundation

enum JSONLines {
    private static let chunkSize = 1 << 20

    /// Returns the offset just past the last complete line; a line still being written is left for the next call.
    @discardableResult
    static func forEachLine(inFileAt path: String, from offset: UInt64 = 0, _ body: (Data) -> Void) -> UInt64? {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return nil
        }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil else {
            return nil
        }

        var end = offset
        var buffer = Data()
        while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            buffer.append(chunk)
            var start = buffer.startIndex
            while let newline = buffer[start...].firstIndex(of: 0x0A) {
                if newline > start {
                    autoreleasepool {
                        body(Data(buffer[start..<newline]))
                    }
                }
                start = buffer.index(after: newline)
            }
            end += UInt64(start - buffer.startIndex)
            buffer.removeSubrange(buffer.startIndex..<start)
        }
        return end
    }
}
