import Foundation

public enum EditorOperations {
    public static func replace(_ text: String, ranges: [NSRange], with replacement: String) throws -> (String, [NSRange]) {
        let sorted = ranges.sorted { $0.location < $1.location }, source = text as NSString
        var end = -1
        for range in sorted {
            guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= source.length, range.location > end else { throw AgentError.protocolError("Overlapping selections.") }
            end = max(range.location, NSMaxRange(range) - 1)
        }
        var result = text
        for range in sorted.reversed() { result = (result as NSString).replacingCharacters(in: range, with: replacement) }
        var shift = 0
        let carets = sorted.map { range in
            let offset = range.location + shift + (replacement as NSString).length
            shift += (replacement as NSString).length - range.length
            return NSRange(location: offset, length: 0)
        }
        return (result, carets)
    }
}
