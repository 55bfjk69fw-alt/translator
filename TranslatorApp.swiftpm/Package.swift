// swift-tools-version: 5.9

// App playground package for Swift Playgrounds on iPad.
// Open this folder (TranslatorApp.swiftpm) in Swift Playgrounds 4.7+ on iPadOS 26.
import PackageDescription
import AppleProductTypes

let package = Package(
    name: "Translator",
    platforms: [
        // iOS 26: SpeechAnalyzer/SpeechTranscriber and the headless
        // TranslationSession initializer (docs/CASCADE-PIPELINE.md §4).
        // Swift Playgrounds 4.7 — required to build this app — already
        // needs iPadOS 26 hardware, so nothing is lost.
        .iOS("26.0")
    ],
    products: [
        .iOSApplication(
            name: "Translator",
            targets: ["AppModule"],
            bundleIdentifier: "com.stufflebeam.translator",
            displayVersion: "0.1",
            bundleVersion: "1",
            accentColor: .presetColor(.indigo),
            supportedDeviceFamilies: [
                .pad,
                .phone
            ],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeRight,
                .landscapeLeft
            ],
            capabilities: [
                .microphone(purposeString: "Captures audio from the DJI Mic receiver and AirPods to translate conversations in real time.")
            ],
            appCategory: .productivity
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: ".",
            resources: [
                // Silero VAD v5 weights (MIT, © Silero Team), consumed by
                // Audio/SileroVAD.swift. Regenerate with tools/silero/.
                .copy("Resources/silero_vad_16k.svad")
            ]
        )
    ]
)
