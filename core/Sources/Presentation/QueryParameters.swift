import Foundation

/// A query's names and values, as the Request tab lists them: in order, duplicates kept, each
/// split at its first `=`, and each half percent-decoded where it can be. `+` stays a plus,
/// since only form bodies make it a space.
public enum QueryParameters {
    public static func parse(_ query: String) -> [(name: String, value: String)] {
        query.split(separator: "&").map { pair in
            // Empty halves count, so "=x" has an empty name, and a lone "=" has neither.
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map {
                String($0).removingPercentEncoding ?? String($0)
            }
            return (parts[0], parts.count > 1 ? parts[1] : "")
        }
    }
}
