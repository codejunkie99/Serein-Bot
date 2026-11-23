// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "Serein", platforms: [.macOS(.v14)],
  products: [
    .executable(name: "Serein", targets: ["Serein"]),
    .executable(name: "serein-browser-mcp", targets: ["BrowserMCP"]),
    .executable(name: "serein-process-host", targets: ["ProcessHost"]),
    .executable(name: "serein-agent", targets: ["SereinAgent"]),
    .executable(name: "serein-mac-guest", targets: ["MacGuest"]),
    .executable(name: "serein-mac-provisioner", targets: ["MacProvision"]),
  ],
  dependencies: [
    // Updates.swift links Sparkle. Free v1 ships without a feed.
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
  ],
  targets: [
    .target(name: "SereinCore"),
    // Runs the agent CLIs: one `Engines` actor, drivers internal to it.
    .target(name: "SereinEngines", dependencies: ["SereinCore"]),
    // transcribe.cpp 0.4.2, the engine that runs the dictation model (SpeechModel) on Metal. Its
    // release ships this ready-made framework; the checksum is the only file this address can give.
    .binaryTarget(
      name: "CTranscribe",
      url: "https://github.com/handy-computer/transcribe.cpp/releases/download/v0.4.2/TranscribeCpp.xcframework.zip",
      checksum: "650a42ee7836558d3047f328078be2b8a8d4c6e9f6a0a3f4ea145481ad1c1a86"),
    .executableTarget(name: "ProcessHost"),
    .executableTarget(
      name: "Serein", dependencies: ["SereinCore", "SereinEngines", "CTranscribe", .product(name: "Sparkle", package: "Sparkle")],
      resources: [.copy("PageKit.js"), .copy("PageNav.js"), .copy("KeptPassages.js"), .copy("DarkPages.js"), .copy("PasswordCapture.js"), .copy("PagePoint.js"), .copy("PiBrowser.js"),.copy("ClaudeModels.json"), .copy("Fonts"), .copy("Icons"), .copy("Quirks"), .copy("Wallpapers"), .copy("Avatar"), .copy("Skills"), .copy("Computer"), .copy("Catalog")]),
    .executableTarget(name: "BrowserMCP", dependencies: ["SereinCore"]),
    .executableTarget(name: "SereinAgent", dependencies: ["SereinCore"]),
    .executableTarget(name: "MacGuest", dependencies: ["SereinCore"]),
    .executableTarget(name: "MacProvision"),
  ])
