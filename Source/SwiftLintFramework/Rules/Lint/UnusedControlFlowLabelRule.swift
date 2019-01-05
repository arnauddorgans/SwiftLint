import Foundation
import SourceKittenFramework

public struct UnusedControlFlowLabelRule: ASTRule, ConfigurationProviderRule, AutomaticTestableRule, CorrectableRule {
    public var configuration = SeverityConfiguration(.warning)

    public init() {}

    public static let description = RuleDescription(
        identifier: "unused_control_flow_label",
        name: "Unused Control Flow Label",
        description: "Unused control flow label should be removed.",
        kind: .lint,
        nonTriggeringExamples: [
            "loop: while true { break loop }",
            "loop: while true { continue loop }",
            "loop:\n    while true { break loop }",
            "while true { break }",
            "loop: for x in array { break loop }",
            """
            label: switch number {
            case 1: print("1")
            case 2: print("2")
            default: break label
            }
            """,
            """
            loop: repeat {
                if x == 10 {
                    break loop
                }
            } while true
            """
        ],
        triggeringExamples: [
            "↓loop: while true { break }",
            "↓loop: while true { break loop1 }",
            "↓loop: while true { break outerLoop }",
            "↓loop: for x in array { break }",
            """
            ↓label: switch number {
            case 1: print("1")
            case 2: print("2")
            default: break
            }
            """,
            """
            ↓loop: repeat {
                if x == 10 {
                    break
                }
            } while true
            """
        ],
        corrections: [
            "↓loop: while true { break }": "while true { break }",
            "↓loop: while true { break loop1 }": "while true { break loop1 }",
            "↓loop: while true { break outerLoop }": "while true { break outerLoop }",
            "↓loop: for x in array { break }": "for x in array { break }",
            """
            ↓label: switch number {
            case 1: print("1")
            case 2: print("2")
            default: break
            }
            """: """
                switch number {
                case 1: print("1")
                case 2: print("2")
                default: break
                }
                """,
            """
            ↓loop: repeat {
                if x == 10 {
                    break
                }
            } while true
            """: """
                repeat {
                    if x == 10 {
                        break
                    }
                } while true
                """
        ]
    )

    private static let kinds: Set<StatementKind> = [.if, .for, .forEach, .while, .repeatWhile, .switch]

    public func validate(file: File, kind: StatementKind,
                         dictionary: [String: SourceKitRepresentable]) -> [StyleViolation] {
        return self.violationRanges(in: file, kind: kind, dictionary: dictionary).map { range in
            StyleViolation(ruleDescription: type(of: self).description,
                           severity: configuration.severity,
                           location: Location(file: file, characterOffset: range.location))
        }
    }

    public func correct(file: File) -> [Correction] {
        let matches = violationRanges(in: file)
            .filter { !file.ruleEnabled(violatingRanges: [$0], for: self).isEmpty }
        guard !matches.isEmpty else { return [] }

        let description = type(of: self).description
        var corrections = [Correction]()
        var contents = file.contents
        for range in matches {
            var rangeToRemove = range
            if let byteRange = file.contents.bridge().NSRangeToByteRange(start: range.location, length: range.length),
                let nextToken = file.syntaxMap.tokens.first(where: { $0.offset > byteRange.location }),
                let nextTokenCharacterLocation = file.contents.bridge().byteRangeToNSRange(start: nextToken.offset, length: 0) {
                rangeToRemove.length = nextTokenCharacterLocation.location - range.location
            }

            contents = contents.bridge().replacingCharacters(in: rangeToRemove, with: "")
            let location = Location(file: file, characterOffset: range.location)
            corrections.append(Correction(ruleDescription: description, location: location))
        }

        file.write(contents)
        return corrections
    }

    private func violationRanges(in file: File, kind: StatementKind,
                                 dictionary: [String: SourceKitRepresentable]) -> [NSRange] {
        guard type(of: self).kinds.contains(kind),
            let offset = dictionary.offset, let length = dictionary.length,
            case let byteRange = NSRange(location: offset, length: length),
            case let tokens = file.syntaxMap.tokens(inByteRange: byteRange),
            let firstToken = tokens.first,
            SyntaxKind(rawValue: firstToken.type) == .identifier,
            case let contents = file.contents.bridge(),
            let tokenContent = contents.substring(with: firstToken),
            let range = contents.byteRangeToNSRange(start: offset, length: length) else {
                return []
        }

        let pattern = "(?:break|continue)\\s+\(tokenContent)\\b"
        guard file.match(pattern: pattern, with: [.keyword, .identifier], range: range).isEmpty else {
            return []
        }

        return [file.contents.bridge().byteRangeToNSRange(start: firstToken.offset, length: firstToken.length)!]
    }

    private func violationRanges(in file: File, dictionary: [String: SourceKitRepresentable]) -> [NSRange] {
        let ranges = dictionary.substructure.flatMap { subDict -> [NSRange] in
            var ranges = violationRanges(in: file, dictionary: subDict)
            if let kind = subDict.kind.flatMap(StatementKind.init(rawValue:)) {
                ranges += violationRanges(in: file, kind: kind, dictionary: subDict)
            }

            return ranges
        }

        return ranges.unique
    }

    private func violationRanges(in file: File) -> [NSRange] {
        return violationRanges(in: file, dictionary: file.structure.dictionary).sorted { lhs, rhs in
            lhs.location > rhs.location
        }
    }
}

private extension NSString {
    func substring(with token: SyntaxToken) -> String? {
        return substringWithByteRange(start: token.offset, length: token.length)
    }
}

extension Collection where Element == SyntaxToken {
    func firstToken(afterByteOffset byteOffset: Int) -> SyntaxToken? {
        return first(where: { $0.offset > byteOffset })
    }
}