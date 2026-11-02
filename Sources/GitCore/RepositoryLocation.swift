import Foundation

/// Converts a Finder path or local file URL without inspecting the filesystem.
/// GitRepository.open performs repository validation asynchronously afterward.
public enum RepositoryLocation {
    public static func url(from input: String) throws -> URL {
        guard !input.isEmpty, !input.utf8.contains(0) else {
            throw GitError.invalidInput("Enter a repository folder path.")
        }
        if input.prefix(7).lowercased() == "file://" {
            guard let url = URL(string: input), url.isFileURL,
                  url.host == nil || url.host == "" || url.host == "localhost",
                  url.user == nil, url.password == nil, url.port == nil,
                  url.query == nil, url.fragment == nil, url.path.hasPrefix("/"), !url.path(percentEncoded: false).utf8.contains(0) else {
                throw GitError.invalidInput("Use a local folder path or a local file URL. For a network drive, use its mounted path in Finder.")
            }
            return url
        }
        let path: String
        if input == "~" || input.hasPrefix("~/") {
            path = FileManager.default.homeDirectoryForCurrentUser.path + input.dropFirst()
        } else { path = input }
        guard path.hasPrefix("/") else {
            throw GitError.invalidInput("Use a full folder path, such as /Users/you/Projects/Repository or ~/Projects/Repository.")
        }
        // Spaces, newlines, quotes, percent signs and Unicode are literal path
        // characters here. This is not a shell command or a URL to a Git remote.
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
