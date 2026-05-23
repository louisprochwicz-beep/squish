import Foundation
import Vision
import ImageIO
import AppKit

/// On-device image classification via Apple's Vision framework.
///
/// Uses `VNClassifyImageRequest` (macOS 13+) which ships a pre-trained
/// classifier covering ~1300 categories — animals, vehicles, scenes,
/// objects, etc. Apple Photos uses the same classifier under the hood
/// for the "Categories" search.
///
/// Pros: free, on-device, ≈100 ms / image, no network, full privacy.
/// Cons: returns generic labels (`mountain`, not `Mont Blanc`).
///
/// Naming strategy:
///  1. Filter classifications above a sane confidence + precision floor.
///  2. Take the top ~4 leaf identifiers (the deepest segment after `.`
///     or `_`), e.g. `outdoor.nature.mountain` → `mountain`.
///  3. Deduplicate (multiple results often share parents).
///  4. Join with `-`, lowercase, ASCII-only, capped at 50 chars.
///  5. Fallback to a generic stem (`image`) if no label crosses the floor.
enum AIRenamer {

    /// Per-image timeout. The request itself usually returns in 50–150 ms
    /// on Apple Silicon; we cap at a couple of seconds so a hung request
    /// can't lock up the whole batch.
    private static let perImageTimeout: TimeInterval = 5.0

    /// How many top labels to combine into the generated name.
    private static let maxLabels: Int = 3

    /// Maximum total length of the generated basename (without extension).
    /// Keeps Finder + the editor header from truncating the name later on.
    private static let maxNameLength: Int = 50

    /// Confidence floor for an individual classification. Vision returns
    /// many low-confidence results; 0.3 keeps only the meaningful ones.
    private static let minConfidence: VNConfidence = 0.30

    /// Generate a clean filename basename from the contents of `imageURL`.
    /// Returns nil if classification failed entirely (file unreadable,
    /// Vision error, or no label crossed the confidence floor).
    static func suggestName(for imageURL: URL) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = classifySync(url: imageURL)
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Sync classification (runs off-main inside the async wrapper)

    private static func classifySync(url: URL) -> String? {
        // Load CGImage via ImageIO — same path the rest of Squish uses,
        // so we benefit from the system caches.
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }

        let request = VNClassifyImageRequest()
        // macOS 14+ defaults to GPU/ANE for classification, which is
        // ~3× faster than CPU. The historic `usesCPUOnly` toggle was
        // deprecated and is no longer needed.

        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observations = request.results else { return nil }

        // Filter to the meaningful labels.
        //
        // Vision exposes a `hasMinimumPrecision(_:forRecall:)` helper for
        // tuning the precision/recall trade-off, but raw confidence is
        // simpler and predictable for our naming use-case.
        let strong = observations
            .filter { $0.confidence >= minConfidence }
            .sorted { $0.confidence > $1.confidence }

        // Collect leaf identifiers, deduplicating + capping.
        var leaves: [String] = []
        var seen = Set<String>()
        for obs in strong {
            let leaf = leafLabel(from: obs.identifier)
            guard !leaf.isEmpty, !seen.contains(leaf) else { continue }
            seen.insert(leaf)
            leaves.append(leaf)
            if leaves.count >= maxLabels { break }
        }

        guard !leaves.isEmpty else { return nil }

        // Join → kebab-case → cap length.
        let joined = leaves.joined(separator: "-")
        return truncate(sanitize(joined), to: maxNameLength)
    }

    // MARK: - String helpers

    /// Extract the deepest segment of a Vision identifier.
    /// `outdoor.nature.mountain` → `mountain`
    /// `animal_mammal_dog`        → `dog`
    private static func leafLabel(from identifier: String) -> String {
        // Vision uses both `.` and `_` as hierarchy separators depending
        // on the category. Split on either, keep the last non-empty piece.
        let parts = identifier
            .split(whereSeparator: { $0 == "." || $0 == "_" })
            .map(String.init)
        return parts.last ?? identifier
    }

    /// Lowercase, ASCII letters/digits/dash only. Anything else becomes
    /// a single `-`. Consecutive dashes get collapsed.
    private static func sanitize(_ s: String) -> String {
        let lower = s.lowercased()
        var out = ""
        out.reserveCapacity(lower.count)
        var lastWasDash = false
        for scalar in lower.unicodeScalars {
            let isAlnum = (scalar.value >= 0x30 && scalar.value <= 0x39) // 0-9
                       || (scalar.value >= 0x61 && scalar.value <= 0x7A) // a-z
            if isAlnum {
                out.append(Character(scalar))
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        // Trim leading/trailing dashes
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func truncate(_ s: String, to maxLen: Int) -> String {
        guard s.count > maxLen else { return s }
        let idx = s.index(s.startIndex, offsetBy: maxLen)
        // Don't cut mid-word: rewind to the last `-` if there is one.
        let prefix = String(s[..<idx])
        if let lastDash = prefix.lastIndex(of: "-") {
            return String(prefix[..<lastDash])
        }
        return prefix
    }
}
