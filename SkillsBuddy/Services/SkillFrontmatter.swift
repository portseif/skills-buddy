//
//  SkillFrontmatter.swift
//  SkillsBuddy
//
//  Reads `name` and `description` from a SKILL.md YAML frontmatter block.
//  Not a YAML parser: it handles the shapes skills actually use — plain and
//  quoted scalars, and `>` / `|` block scalars.
//

import Foundation

nonisolated struct SkillFrontmatter: Equatable, Sendable {
    var name: String?
    var description: String?

    static func parse(_ markdown: String) -> SkillFrontmatter {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return SkillFrontmatter() }

        var fields: [String: String] = [:]
        var lineIndex = 1
        while lineIndex < lines.count {
            let line = lines[lineIndex]
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }

            // Only top-level keys: indented lines belong to the previous key.
            guard let first = line.first, !first.isWhitespace, let colonIndex = line.firstIndex(of: ":") else {
                lineIndex += 1
                continue
            }
            let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
            lineIndex += 1

            if rawValue.hasPrefix(">") || rawValue.hasPrefix("|") {
                var blockLines: [String] = []
                while lineIndex < lines.count {
                    let blockLine = lines[lineIndex]
                    let isIndented = blockLine.first?.isWhitespace ?? false
                    if !(isIndented || blockLine.isEmpty) { break }
                    if blockLine.trimmingCharacters(in: .whitespaces) == "---" { break }
                    blockLines.append(blockLine.trimmingCharacters(in: .whitespaces))
                    lineIndex += 1
                }
                // Folded even for `|`: descriptions are prose shown on one line or reflowed.
                fields[key] = blockLines.filter { !$0.isEmpty }.joined(separator: " ")
            } else {
                fields[key] = unquote(rawValue)
            }
        }

        return SkillFrontmatter(
            name: fields["name"].flatMap { $0.isEmpty ? nil : $0 },
            description: fields["description"].flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    static func load(from skillFileURL: URL) -> SkillFrontmatter {
        guard let text = try? String(contentsOf: skillFileURL, encoding: .utf8) else { return SkillFrontmatter() }
        return parse(text)
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, let last = value.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'") else { return value }
        let inner = String(value.dropFirst().dropLast())
        return first == "\"" ? inner.replacingOccurrences(of: "\\\"", with: "\"") : inner.replacingOccurrences(of: "''", with: "'")
    }
}
