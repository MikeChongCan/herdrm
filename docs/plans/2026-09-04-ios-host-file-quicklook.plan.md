# Implement iOS host-file Quick Look

Read `docs/ios-host-file-quicklook.md`. This file is the executable spec. Implement all of it. Do not stop early.

Branch: `review/ios-host-file-quicklook` (already checked out). Commit here. Never push.

## Rules for the implementer

- Code only. Targeted tests only. One or two commits. Never push.
- Do not modify SwiftTerm sources, `project.yml`, xcstrings, design/, rust/, or the resume `.txt`.
- Comments: short, factual, only non-obvious constraints.
- `String(localized:)` for user-visible strings.
- HerdrKit remains Foundation-only. QuickLook stays in HerdrMobile.
- Self-check: `cd Packages/HerdrKit && swift test --filter TerminalLinkTests` AND `cd Packages/HerdrSSH && swift test` if there is an existing test target you can filter; otherwise only HerdrKit tests. Do not run xcodebuild.
- Commit message must end with `cosigned by OpenAI Codex at M1 Max`.

## Files

Create if needed:

- Keep using `Packages/HerdrKit/Sources/HerdrKit/TerminalLink.swift` (extend)
- `Packages/HerdrKit/Tests/HerdrKitTests/TerminalLinkTests.swift` (extend)
- Maybe `Sources/HerdrMobile/HostFilePreview.swift` for QL + fetch (keep MobileTerminalView from growing too much)

Edit:

- `Packages/HerdrSSH/Sources/HerdrSSH/PublicTypes.swift` (`SSHSFTPAttributes`)
- `Packages/HerdrSSH/Sources/HerdrSSH/SessionDriver.swift` (stat + bounded read)
- `Packages/HerdrSSH/Sources/HerdrSSH/SSHSFTPClient.swift`
- `Sources/HerdrMobile/MobileTransport.swift`
- `Sources/HerdrMobile/MobileTerminalView.swift`
- `Sources/HerdrMobile/MobileRootView.swift` (pass a live cwd/home provider, not a frozen cwd string)
- `CHANGELOG.md` Unreleased Added bullet

## 1. HerdrKit — classify links

```swift
public enum DetectedLink: Equatable {
    case web(URL)
    case hostFile(String) // absolute POSIX path on the SSH host
}

public enum HostFilePath {
    public static func parse(raw: String, cwd: String?, home: String?) -> String?
}

extension DetectedLink {
    public static func parse(_ raw: String, cwd: String?, home: String?) -> DetectedLink?
}
```

`DetectedLink.parse`:

- Trim ends.
- If `WebURL.first(in: raw)` → `.web`
- If `URL(string:)` / `URL(string: raw.addingPercentEncoding)` has a scheme:
  - `file`: host empty or `localhost` (case-insensitive) → path from URL; percent-decode. Other hosts → nil
  - any other scheme → nil
- Else `HostFilePath.parse`

`HostFilePath.parse`:

- Reject empty, reject internal whitespace, reject `\\` or `^[A-Za-z]:[\\/]`
- Expand `~` / `~/` with `home` (must start with `/`); no home → nil
- Absolute `/…` → standardizingPath
- Relative: require `cwd` starting with `/`, join, standardizingPath
- Result must start with `/`

Keep `WebURL.first` http(s)-only. Collector unchanged.

Add the tests listed in the product plan (section 测试).

## 2. HerdrSSH — directory bit + bounded read

In `sftpAttributes`, compute `isDirectory` from the **unmasked** `attributes.permissions` (`(mode & 0o170000) == 0o040000`) when permissions flag is set. Keep `permissions` as `& 0o777`.

```swift
public struct SSHSFTPAttributes: Sendable, Equatable {
    public let size: UInt64?
    public let permissions: UInt32?
    public let isDirectory: Bool
}
```

Update every `SSHSFTPAttributes(` construction in the package.

Add:

```swift
public func readFileIfPresent(at path: String, maxBytes: Int, timeout: Duration) async throws -> Data?
```

Existing no-max overload can call this with a large default **or** stay unbounded for current callers — prefer routing existing callers through a high cap only if tests allow; otherwise add the maxBytes overload and use it from iOS only.

While appending chunks, if `contents.count > maxBytes` close the handle and throw a dedicated error (e.g. `SSHError.sftpFailure` is ok if you don't want a new case; better a clear `SSHError` if one fits). Do not keep the oversize Data.

Timeout for preview reads: 60 seconds at the iOS call site.

## 3. MobileTransport

- Store `let remoteHome: String` on `SSHDirectTransport`.
- Always probe `$HOME` even when `device.socketPath` is set. Socket override still wins for the sock path; home is independent.
- Expose `var remoteHome: String { get }` on `MobileTransport` (default empty forbidden — required).
- `func openSFTP(timeout: Duration) async throws -> SSHSFTPClient`

`MobileTransportProvider` should surface `remoteHome` via `currentTransport()`.

Live cwd: add a small closure or protocol on the session/model:

```swift
func currentCwd(for paneID: String) -> String?
```

Look up `snapshot.agents` / panes by paneID at tap time. Pass this into `MobileTerminalScreen` / `MobileAttachSession`. Do not capture cwd in `init` only.

## 4. UI

Replace `webURL(at:)` with `detectedLink(at:)` that uses `DetectedLink.parse(raw, cwd: liveCwd(), home: remoteHome)`.

`configurationForMenuAtLocation`:

- `.web` → existing Open/Copy/Share menu
- `.hostFile` → Preview + Copy path (preview label is the path)
- nil → nil

Preview action: async fetch then present QL from `nearestViewController()`.

Fetch:

```
let sftp = try await transport.openSFTP(timeout: .seconds(15))
defer close
let attrs = try await sftp.attributes(at: path, timeout: .seconds(15))
guard !attrs.isDirectory else error
guard let size = attrs.size, size <= 25*1024*1024 else error
let data = try await sftp.readFileIfPresent(at: path, maxBytes: 25*1024*1024, timeout: .seconds(60))
```

Write under Caches/HostFilePreviews/<uuid>/<basename>. Present `QLPreviewController`. On dismiss, delete the uuid directory.

Loading overlay on `MobileTerminalScreen` via `@Published` on the session or a callback.

`import QuickLook` in the iOS target (XcodeGen auto-links the import).

Edit menu: if selection is a host file, add Preview/Copy path; if web, keep existing.

## 5. CHANGELOG

Unreleased Added: iOS long-press on terminal file paths / file:// opens a read-only Quick Look snapshot over SFTP.

## 6. Self-check

```
cd Packages/HerdrKit && swift test --filter TerminalLinkTests
```

Fix any HerdrSSH compile breaks. Do not xcodebuild.

## 7. Commit

```
feat(mobile): Quick Look host files from terminal path links

cosigned by OpenAI Codex at M1 Max
```
