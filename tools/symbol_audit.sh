#!/usr/bin/env bash
# Cross-file symbol audit for TranslatorApp.swiftpm — a poor man's global
# resolution pass for an environment with no Swift compiler (Claude's
# Linux container). Catches the "conformance to a protocol nobody ever
# wrote" class of error that per-file review structurally cannot see
# (found the hard way: SpeechSynth/Translator, 2026-07-14).
#
# Usage: tools/symbol_audit.sh   (from the repo root)
# Output: capitalized identifiers used in the app that are neither
# declared in the module nor on the framework whitelist. Expect comment
# words and framework symbols to survive the filter — the point is that
# APP-LOOKING type names in the output are bugs.
set -euo pipefail
cd "$(dirname "$0")/../TranslatorApp.swiftpm"

declared=$(mktemp) used=$(mktemp)
grep -rhoE '\b(final +)?(class|struct|enum|protocol|actor|typealias) +[A-Z][A-Za-z0-9_]*' --include='*.swift' . \
  | awk '{print $NF}' | sort -u > "$declared"
grep -rhoE '\b[A-Z][A-Za-z0-9_]{2,}\b' --include='*.swift' . | sort -u > "$used"

comm -23 "$used" "$declared" \
  | grep -vE '^(AV|UI|NS|CG|CM|SF|CB|CF|WK|CA|Cblas|Sec|DSP)' \
  | grep -vwE 'Swift|SwiftUI|Foundation|UIKit|Combine|Speech|Translation|CoreMedia|Accelerate|PackageDescription|AppleProductTypes|SpeechAnalyzer|SpeechTranscriber|AnalyzerInput|AssetInventory|TranslationSession|TranslationError|LanguageAvailability|Logger|String|Int|Int16|Int32|Int64|UInt|UInt8|UInt16|UInt32|UInt64|Double|Float|Float32|Bool|Data|Date|UUID|URL|URLRequest|URLSession|URLSessionWebSocketTask|URLSessionTask|URLSessionWebSocketDelegate|Array|Set|Dictionary|Optional|Result|Error|Void|Character|Substring|Task|TaskPriority|AsyncStream|AsyncSequence|AsyncThrowingStream|CheckedContinuation|CancellationError|DispatchQueue|DispatchTime|DispatchSource|DispatchSourceTimer|DispatchWorkItem|OperationQueue|NotificationCenter|Notification|RunLoop|Timer|Locale|TimeInterval|JSONSerialization|JSONEncoder|MemoryLayout|ObservableObject|Published|State|StateObject|ObservedObject|EnvironmentObject|Environment|AppStorage|Binding|ViewBuilder|Identifiable|Equatable|Hashable|Comparable|Codable|CaseIterable|RawRepresentable|CustomStringConvertible|LocalizedError|Sendable|AnyObject|MainActor|ProcessInfo|Bundle|Progress|HTTPURLResponse|UserDefaults|ObjectIdentifier|ClosedRange|Stride|UnsafePointer|UnsafeMutablePointer|UnsafeBufferPointer|UnsafeMutableBufferPointer|UnsafeRawBufferPointer|UnsafeMutableRawPointer|ISO8601DateFormatter|Mirror|Never|Self' \
  | grep -vwE 'ForEach|NavigationStack|ScrollView|ScrollViewReader|ScrollViewProxy|LazyVGrid|LazyVStack|GridItem|GridRow|TabView|WindowGroup|ToolbarItem|ToolbarItemGroup|GeometryReader|RoundedRectangle|EmptyView|ProgressView|TextField|ShareLink|LabeledContent|DisclosureGroup|PresentationDetent|ProposedViewSize|TapGesture|StrokeStyle|KeyPath|DateFormatter|LineMark|BarMark|AreaMark|PointMark|AxisMarks|CloseCode|CategoryOptions|InterruptionType|RouteChangeReason|ThermalState|DiscoverySession|AudioStreamBasicDescription|AppModule|CoreAudio|CoreGraphics|QoS|WebSocket|SwiftPM|ObjC|AirPods|OpenAI|DeepL|ElevenLabs|MacinTalk|PyTorch|ReLU|YouTube|SpeechAnalyzers' \
  | grep -E '^[A-Z][a-z]+[A-Z]' || true
echo "--- (empty above this line = no unresolved CamelCase app symbols)"
rm -f "$declared" "$used"
