import Foundation
import SwiftVideo
import NIO
import NIOExtras
import BrightFutures

let clock = WallClock()
let group = MultiThreadedEventLoopGroup(numberOfThreads: 4)
let quiesce = ServerQuiescingHelper(group: group)

var subs: [String: Terminal<CodedMediaSample>] = [:]

// onEnded is called when a publish or subscribe session ends. AssetID is the string value that's passed to the closure.
let onEnded: LiveOnEnded = { print("\($0) ended") ; subs.removeValue(forKey: $0) }

//
// With the Rtmp system, onConnection is called after an RTMP publish or subscribe handshake occurs.  The workspaceToken contains the 
// "playpath" (or stream key) portion of the URI and the "workspaceId" contains the "app" portion of the URI.
// You must return a future that emits either true or false, depending on if permission is granted to either publish or subscribe.
// Note that the nomenclature "publisher" and "subscriber" are from the perspective of the media server, therefore when the peer is
// publishing, the server is subscribing.
//
// Asset ID is a generated UUIDv4 that can identify the asset in the system.
//
let onConnection: LiveOnConnection = { pub, sub in
    if let pub = pub, let streamKey = pub.workspaceToken() {
        print("publisher asking for permission: \(pub.workspaceId())/\(streamKey)")
    }
    if let sub = sub, let tx = sub as? Source<CodedMediaSample>, let streamKey = sub.workspaceToken() {
        print("subscriber asking for permission: \(sub.workspaceId())/\(streamKey)")

        // In order to receive samples, we need to compose the subscriber with a receiver and keep a strong reference to it.
        // Releasing the reference will close the connection an end the stream.
        // You can create more sophisticated graphs with decoders, buses, and other components.
        subs[sub.assetId()] = tx >>> Tx { print("got sample \($0.pts().toString()) type = \($0.mediaType())"); return .nothing(nil) }
    }
    return Future { $0(.success(true)) }
}

let rtmp = Rtmp(clock, onEnded: onEnded, onConnection: onConnection)

_ = rtmp.serve(host: "0.0.0.0", port: 1935, quiesce: quiesce, group: group)

_ = try rtmp.wait()
