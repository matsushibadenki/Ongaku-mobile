import Foundation
import CryptoKit

// Production cache/provider code is compiled; only source registries/logging are stubbed.
enum L10n { static func tr(_ key: String, _ args: CVarArg...) -> String { key } }
enum PlaybackDebugLogger { static func event(_ text: String) {} }
enum LocalMediaManager { static let supportedAudioExtensions: Set<String> = ["mp3","wav"] }
final class GoogleDriveLibraryStore: @unchecked Sendable {
    static let shared = GoogleDriveLibraryStore()
    var source: (any RemoteAudioByteSource)?
    func byteSource(for url: URL) -> (any RemoteAudioByteSource)? { source }
}
final class RemoteMusicSourceStore: @unchecked Sendable {
    static let shared = RemoteMusicSourceStore()
    func sourceID(containing url: URL) -> UUID? { nil }
}
struct StubReply: @unchecked Sendable {
    var status: Int = 206
    var headers: [String:String] = ["Content-Range":"bytes 0-3/8"]
    var data = Data([1,2,3,4])
    var error: URLError? = nil
    var delay: TimeInterval = 0
}
final class NetworkStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var replies = [StubReply]()
    private static var calls = 0
    private let stateLock = NSLock()
    private var stopped = false
    static func install(_ plans: [StubReply]) { lock.withLock { replies = plans; calls = 0 } }
    static var hits: Int { lock.withLock { calls } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.lock.withLock { () -> StubReply in
            Self.calls += 1
            return Self.replies.count > 1 ? Self.replies.removeFirst() : Self.replies[0]
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [self] in
            stateLock.withLock {
                guard !stopped else { return }
                if let error = reply.error { client?.urlProtocol(self, didFailWithError: error); return }
                let response = HTTPURLResponse(url:request.url!,statusCode:reply.status,httpVersion:nil,headerFields:reply.headers)!
                client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
                client?.urlProtocol(self,didLoad:reply.data)
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }
    override func stopLoading() { stateLock.withLock { stopped = true } }
}
actor Tokens: GoogleOAuthAccessTokenProvider {
    var refreshes = [Bool]()
    func accessToken(forceRefresh: Bool) -> String { refreshes.append(forceRefresh); return "fixture" }
}
actor Bytes: RemoteAudioByteSource {
    let id: String
    let size: Int64
    let pause: TimeInterval
    let changes: Bool
    let checksum: String?
    var reads = 0
    var descriptors = 0
    init(_ id: String, size: Int64 = 8, pause: TimeInterval = 0, changes: Bool = false, checksum: String? = nil) {
        self.id=id; self.size=size; self.pause=pause; self.changes=changes; self.checksum=checksum
    }
    func descriptor() -> RemoteAudioResourceDescriptor {
        descriptors += 1
        return .init(stableID:id,fileName:"fixture.wav",contentLength:size,
                     revision:changes && descriptors>=3 ? "changed" : "1",checksumMD5:checksum)
    }
    func read(bytes range: Range<Int64>) async throws -> Data {
        reads += 1
        if pause>0 { try await Task.sleep(for:.seconds(pause)) }
        return Data(repeating:7,count:Int(range.count))
    }
}
@main struct RemoteResilienceRegression {
    static func check(_ value: Bool,_ message: String) throws { if !value { throw NSError(domain:message,code:1) } }
    static func main() async throws {
        setbuf(stdout,nil)
        let configuration=URLSessionConfiguration.ephemeral;configuration.protocolClasses=[NetworkStub.self]
        let http=RemoteAudioHTTP(session:URLSession(configuration:configuration),sleep:{ _ in try Task.checkCancellation() })
        let resource=RemoteAudioResourceDescriptor(stableID:"http",fileName:"f.wav",contentLength:8,revision:"1")
        let source=HTTPRangeAudioByteSource(resource:resource,contentURL:URL(string:"https://fixture.invalid/audio")!,requestHeaders:[:],http:http)
        NetworkStub.install([.init(status:503,headers:[:]),.init()])
        let good=try await source.read(bytes:0..<4)
        try check(good==Data([1,2,3,4]) && NetworkStub.hits==2,"bounded retry / exact range")
        NetworkStub.install([.init(error:URLError(.networkConnectionLost)),.init()])
        _=try await source.read(bytes:0..<4)
        try check(NetworkStub.hits==2,"network loss retry")
        NetworkStub.install([.init(status:503,headers:[:])])
        do { _=try await source.read(bytes:0..<4);throw NSError(domain:"retry did not stop",code:1) }
        catch RemoteAudioByteSourceError.invalidResponse(503) {}
        try check(NetworkStub.hits==3,"retry exhausted after three attempts")
        NetworkStub.install([.init(status:429,headers:["Retry-After":"60"])])
        do { _=try await source.read(bytes:0..<4);throw NSError(domain:"long retry ignored",code:1) }
        catch RemoteAudioByteSourceError.invalidResponse(429) {}
        try check(NetworkStub.hits==1,"honor long server backoff")
        for reply in [StubReply(headers:["Content-Range":"bytes 4-7/8"]),.init(headers:[:]),
                      .init(status:200,headers:[:],data:Data(repeating:1,count:8)),
                      .init(headers:["Content-Range":"bytes 0-3/8","Content-Encoding":"gzip"])] {
            NetworkStub.install([reply])
            do { _=try await source.read(bytes:0..<4);throw NSError(domain:"invalid range accepted",code:1) }
            catch RemoteAudioByteSourceError.invalidContentRange {}
        }
        NetworkStub.install([.init(data:Data([1,2]))])
        do { _=try await source.read(bytes:0..<4);throw NSError(domain:"truncated body accepted",code:1) }
        catch RemoteAudioByteSourceError.incompleteRange {}
        NetworkStub.install([.init(delay:0.5)])
        let pending=Task { try await source.read(bytes:0..<4) }
        try await Task.sleep(for:.milliseconds(30));pending.cancel()
        do { _=try await pending.value;throw NSError(domain:"cancel ignored",code:1) } catch is CancellationError {}
        print("PASS: retry limits, network loss, backoff, strict ranges, encoding, truncation and slow-request cancellation")
        let tokens=Tokens()
        let file=GoogleDriveAudioFile(id:"id",name:"a.mp3",mimeType:"audio/mpeg",size:8,modifiedTime:nil,md5Checksum:nil)
        let drive=GoogleDriveAudioByteSource(file:file,tokenProvider:tokens,http:http)
        NetworkStub.install([.init(status:401,headers:[:]),.init()])
        _=try await drive.read(bytes:0..<4)
        let refreshes=await tokens.refreshes
        try check(refreshes==[false,true],"single forced refresh")
        NetworkStub.install([.init(status:401,headers:[:])])
        do { _=try await drive.read(bytes:0..<4);throw NSError(domain:"401 loop",code:1) } catch GoogleDriveAudioError.requestFailed(401) {}
        try check(NetworkStub.hits==2,"repeated unauthorized bounded")
        let listing=Data(#"{"files":[{"id":"id","name":"a.mp3","mimeType":"audio/mpeg","size":"8","modifiedTime":"2026-10-16T01:02:03.123Z"}]}"#.utf8)
        NetworkStub.install([.init(status:200,headers:[:],data:listing)])
        let page=try await GoogleDriveAudioClient(tokenProvider:tokens,http:http).listAudioFiles()
        try check(page.files.count==1 && page.files[0].modifiedTime != nil,"fractional Drive timestamps")
        print("PASS: one OAuth refresh, bounded repeated 401 and fractional metadata timestamps")
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let coordinator=RemoteRangeDownloadCoordinator()
        for bad in [Bytes("revision",changes:true),Bytes("checksum",checksum:"incorrect")] {
            do { _=try await coordinator.materialize(source:bad,directory:root);throw NSError(domain:"changed resource published",code:1) }
            catch RemoteAudioByteSourceError.resourceChanged {}
        }
        let files=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
        try check(files.isEmpty,"bad content retained for resume")
        let expected = Insecure.MD5.hash(data: Data(repeating: 7, count: 8)).map { String(format: "%02x", $0) }.joined()
        _ = try await coordinator.materialize(source: Bytes("verified", checksum: expected), directory: root)
        let slow=Bytes("slow",pause:0.3)
        let transfer=Task { try await coordinator.materialize(source:slow,directory:root) }
        try await Task.sleep(for:.milliseconds(20))
        let queued=Task { try await coordinator.materialize(source:Bytes("queued"),directory:root) }
        try await Task.sleep(for:.milliseconds(20));queued.cancel()
        do { _=try await queued.value;throw NSError(domain:"queued cancel ignored",code:1) } catch is CancellationError {}
        _=try await transfer.value
        print("PASS: changed revision/checksum rejected and discarded; queued transfer cancels before writer becomes free")
        let directory=root.appendingPathComponent("cache")
        let cache=RemoteAudioCache(directory:directory,maximumByteCount:16)
        let playback=Bytes("playing")
        GoogleDriveLibraryStore.shared.source=playback
        var lease: RemotePlaybackFile?=try await cache.playbackFile(for:URL(string:"fixture://playing")!)
        let playingURL=lease!.url
        await cache.clear()
        try check(lease?.url == playingURL, "playback lease lost")
        try check(FileManager.default.fileExists(atPath:playingURL.path),"clear removed playing file")
        _=try await cache.playbackURL(from:Bytes("other"))
        _=try await cache.playbackURL(from:Bytes("third"))
        try check(FileManager.default.fileExists(atPath:playingURL.path),"eviction removed playing file")
        let stats=await cache.statistics()
        try check(stats.byteCount<=16,"cache exceeds budget")
        lease=nil
        await cache.clear()
        try check(!FileManager.default.fileExists(atPath:playingURL.path),"released file stayed pinned")
        let download=Task { try await cache.playbackURL(from:Bytes("inflight",pause:0.2)) }
        try await Task.sleep(for:.milliseconds(30));await cache.clear()
        _=try await download.value
        let reserved = Task { try await cache.playbackURL(from: Bytes("reservation", size: 12, pause: 0.2)) }
        try await Task.sleep(for: .milliseconds(30))
        do { _ = try await cache.playbackURL(from: Bytes("overbudget", size: 8)); throw NSError(domain: "future budget ignored", code: 1) }
        catch RemoteAudioCacheError.cacheBusy {}
        _ = try await reserved.value
        print("PASS: clear/eviction protect playback and transfers; leases release; cache stays within budget")
    }
}
