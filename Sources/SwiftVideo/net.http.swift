/*
   SwiftVideo, Copyright 2019 Unpause SAS

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
*/

import NIO
import NIOWebSocket
import NIOHTTP1
import NIOExtras
import Foundation


let websocketResponse = """
<!DOCTYPE html>
<html>
  <head>
    <meta charset='utf-8'>
    <title>Swift NIO WebSocket Test Page</title>
    <script>
        var wsconnection = new WebSocket('ws://localhost:8888/websocket');
        wsconnection.onmessage = function (msg) {
            var element = document.createElement('p');
            element.innerHTML = msg.data;

            var textDiv = document.getElementById('websocket-stream');
            textDiv.insertBefore(element, null);
        };
    </script>
  </head>
  <body>
    <h1>WebSocket Stream</h1>
    <div id='websocket-stream'></div>
  </body>
</html>
"""

public class Http {
    public init(_ clock: Clock) {
        //self.ws = nil
        self.channel = nil
        self.clock = clock
        self.handlers = [String:(WebSocket, String, String) -> String?]()
        self.closeWatchers = [String:(WebSocket, String) -> ()]()
    }
    public func serve(host: String, port: Int, quiesce: ServerQuiescingHelper, group: EventLoopGroup? = nil) throws -> Bool {

        let group = group ?? MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        let upgrader = NIOWebSocketServerUpgrader(shouldUpgrade: { (channel: Channel, head: HTTPRequestHead) in channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
                                 upgradePipelineHandler: { [weak self] (channel: Channel, _: HTTPRequestHead) in
                                    let ws = WebSocket(channel)
                                    let uuid = UUID().uuidString
                                    ws.onText { [weak self] ws, string in
                                        guard let strongSelf = self else {
                                            return
                                        }
                                        do {
                                            let obj = try string.toJSON(CheckJSON.self)
                                            guard let handler = strongSelf.handlers[obj.cmd] else {
                                                print("sending bad_command")
                                                try strongSelf.sendResponse(ws, cmd: obj.cmd, status: "bad_command")
                                                return
                                            }
                                            if let response = handler(ws, uuid, string) {
                                                try strongSelf.sendResponse(ws, cmd: obj.cmd, status: response)
                                            }
                                        } catch(let error) {
                                            print("Decode error \(error)")
                                        }
                                    }
                                    ws.onClose { [weak self] ws in
                                        guard let strongSelf = self else {
                                            return
                                        }
                                        for watcher in strongSelf.closeWatchers {
                                            watcher.1(ws, uuid)
                                        }
                                    }
                                    return channel.pipeline.addHandler(ws)
                                 })

        let bootstrap = ServerBootstrap(group: group)
        // Specify backlog and enable SO_REUSEADDR for the server itself
        .serverChannelOption(ChannelOptions.backlog, value: 256)
        .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
        .serverChannelInitializer { channel in
            channel.pipeline.addHandler(quiesce.makeServerChannelHandler(channel: channel))
        }
        // Set the handlers that are applied to the accepted Channels
        .childChannelInitializer { channel in
            let httpHandler = HTTPHandler()
            let config: NIOHTTPServerUpgradeConfiguration = (
                            upgraders: [ upgrader ],
                            completionHandler: { _ in
                                channel.pipeline.removeHandler(httpHandler, promise: nil)
                            }
                        )
            return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: config).flatMap {
                channel.pipeline.addHandler(httpHandler)

            }
        }

        // Enable SO_REUSEADDR for the accepted Channels
        .childChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)

        self.channel = try bootstrap.bind(host: host, port: port).wait()
        
        return true
    }
    public func setHandler(_ command: String, handler: @escaping (WebSocket, String, String) -> String?) {
        self.handlers[command] = handler
    }

    public func setCloseWatcher(_ name: String, _ handler: @escaping (WebSocket, String) -> ()) {
        self.closeWatchers[name] = handler;
    }
    public func removeCloseWatcher(_ name: String) {
        self.closeWatchers.removeValue(forKey: name)
    }
    public func sendResponse(_ ws: WebSocket, cmd: String, sub: String? = nil, status: String) throws {
        let str: String = try String(data: JSONEncoder().encode(["status": status, "cmd": cmd, "sub": sub ?? ""]), encoding: .utf8) ?? ""
        ws.send(str)
    }

    public func sendJSON<T>(_ ws: WebSocket, data: T) throws where T: Codable {
        try ws.send(String(data: JSONEncoder().encode(data), encoding: .utf8) ?? "")
    }

    public func shutdown() {
        self.channel = nil
    }

    //var ws: HTTPProtocolUpgrader?
    //var server: HTTPServer?
    var channel: Channel?
    let clock: Clock
    var handlers: [String:(WebSocket, String, String) -> String?]
    var closeWatchers: [String: (WebSocket, String) -> ()]
}

private struct CheckJSON : Codable {
    let cmd: String
    
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        cmd = try values.decode(String.self, forKey: .cmd)
    }

     enum CodingKeys: String, CodingKey {
        case cmd
    }
}

private enum http {
    // struct Responder: HTTPServerResponder {
    //     func respond(to request: HTTPRequest, on worker: Worker) -> EventLoopFuture<HTTPResponse> {
    //         let res = HTTPResponse(status: .ok, body: "This is a WebSocket server")
    //         return worker.eventLoop.newSucceededFuture(result: res)
    //     }
    // }

    struct AuthData: Codable {
        let name: String
    }

    struct Auth: Codable {
        let cmd: String
        let api_key: String
        let d: AuthData
    }

    struct Sub: Codable {
        let cmd: String
        let ch: String
    }

    struct RtcSdp: Codable {
        let type: String
        let sdp: String
    }
    struct RtcCandidate: Codable {
        let candidate: String
        let sdpMid: String
        let sdpMLineIndex: Int
    }
    struct RtcCommData: Codable {
        let sdp: RtcSdp?
        let candidate: RtcCandidate?
    }
    struct RtcComm: Codable {
        let cmd: String
        let ch: String
        let d: RtcCommData
    }
}


private final class HTTPHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private var responseBody: ByteBuffer!

    func channelRegistered(context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: websocketResponse.utf8.count)
        buffer.writeString(websocketResponse)
        self.responseBody = buffer
    }

    func channelUnregistered(context: ChannelHandlerContext) {
        self.responseBody = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let reqPart = self.unwrapInboundIn(data)

        // We're not interested in request bodies here: we're just serving up GET responses
        // to get the client to initiate a websocket request.
        guard case .head(let head) = reqPart else {
            return
        }

        // GETs only.
        guard case .GET = head.method else {
            self.respond405(context: context)
            return
        }

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/html")
        headers.add(name: "Content-Length", value: String(self.responseBody.readableBytes))
        headers.add(name: "Connection", value: "close")
        let responseHead = HTTPResponseHead(version: .init(major: 1, minor: 1),
                                    status: .ok,
                                    headers: headers)
        context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
        context.write(self.wrapOutboundOut(.body(.byteBuffer(self.responseBody))), promise: nil)
        context.write(self.wrapOutboundOut(.end(nil))).whenComplete { (_: Result<Void, Error>) in
            context.close(promise: nil)
        }
        context.flush()
    }

    private func respond405(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "Connection", value: "close")
        headers.add(name: "Content-Length", value: "0")
        let head = HTTPResponseHead(version: .init(major: 1, minor: 1),
                                    status: .methodNotAllowed,
                                    headers: headers)
        context.write(self.wrapOutboundOut(.head(head)), promise: nil)
        context.write(self.wrapOutboundOut(.end(nil))).whenComplete { (_: Result<Void, Error>) in
            context.close(promise: nil)
        }
        context.flush()
    }
}


public final class WebSocket: ChannelInboundHandler {
    public typealias InboundIn = WebSocketFrame
    public typealias OutboundOut = WebSocketFrame
    public typealias FnOnText = (WebSocket, String) -> ()
    public typealias FnOnClose = (WebSocket) -> ()

    private var awaitingClose: Bool = false
    private weak var channel: Channel?
    private var onTextFn: FnOnText? = nil
    private var onCloseFn: FnOnClose? = nil

    public init( _ channel: Channel ) {
        self.channel = channel
    }
    public func onText(_ fn: @escaping FnOnText) {
        self.onTextFn = fn
    }
    public func onClose(_ fn: @escaping FnOnClose) {
        self.onCloseFn = fn
    }
    public func send(_ data: String) {
        guard let channel = self.channel,
            channel.isActive else {
            return
        }
        var buffer = channel.allocator.buffer(capacity: data.utf8.count)
        buffer.writeString(data)
        let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
        _ = channel.writeAndFlush(self.wrapOutboundOut(frame))
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        self.sendTime(context: context)
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)

        switch frame.opcode {
        case .connectionClose:
            self.receivedClose(context: context, frame: frame)
        case .ping:
            self.pong(context: context, frame: frame)
        case .text:
            if let onTextFn = self.onTextFn {
                var data = frame.unmaskedData
                let text = data.readString(length: data.readableBytes) ?? ""
                onTextFn(self, text)
            }
        case .binary, .continuation, .pong:
            // We ignore these frames.
            break
        default:
            // Unknown frames are errors.
            self.closeOnError(context: context)
        }
    }

    public func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }

    private func sendTime(context: ChannelHandlerContext) {
        guard context.channel.isActive else { return }

        // We can't send if we sent a close message.
        guard !self.awaitingClose else { return }

        /*// We can't really check for error here, but it's also not the purpose of the
        // example so let's not worry about it.
        let theTime = NIODeadline.now().uptimeNanoseconds
        var buffer = context.channel.allocator.buffer(capacity: 12)
        buffer.writeString("\(theTime)")

        let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
        context.writeAndFlush(self.wrapOutboundOut(frame)).map {
            context.eventLoop.scheduleTask(in: .seconds(1), { self.sendTime(context: context) })
        }.whenFailure { (_: Error) in
            context.close(promise: nil)
        }*/
    }

    private func receivedClose(context: ChannelHandlerContext, frame: WebSocketFrame) {
        // Handle a received close frame. In websockets, we're just going to send the close
        // frame and then close, unless we already sent our own close frame.
        if awaitingClose {
            // Cool, we started the close and were waiting for the user. We're done.
            context.close(promise: nil)
        } else {
            // This is an unsolicited close. We're going to send a response frame and
            // then, when we've sent it, close up shop. We should send back the close code the remote
            // peer sent us, unless they didn't send one at all.
            var data = frame.unmaskedData
            let closeDataCode = data.readSlice(length: 2) ?? context.channel.allocator.buffer(capacity: 0)
            let closeFrame = WebSocketFrame(fin: true, opcode: .connectionClose, data: closeDataCode)
            _ = context.write(self.wrapOutboundOut(closeFrame)).map { () in
                context.close(promise: nil)
            }
        }
        if let fn = self.onCloseFn {
            fn(self)
        }
    }

    private func pong(context: ChannelHandlerContext, frame: WebSocketFrame) {
        var frameData = frame.data
        let maskingKey = frame.maskKey

        if let maskingKey = maskingKey {
            frameData.webSocketUnmask(maskingKey)
        }

        let responseFrame = WebSocketFrame(fin: true, opcode: .pong, data: frameData)
        context.write(self.wrapOutboundOut(responseFrame), promise: nil)
    }

    private func closeOnError(context: ChannelHandlerContext) {
        // We have hit an error, we want to close. We do that by sending a close frame and then
        // shutting down the write side of the connection.
        var data = context.channel.allocator.buffer(capacity: 2)
        data.write(webSocketErrorCode: .protocolError)
        let frame = WebSocketFrame(fin: true, opcode: .connectionClose, data: data)
        context.write(self.wrapOutboundOut(frame)).whenComplete { (_: Result<Void, Error>) in
            context.close(mode: .output, promise: nil)
        }
        awaitingClose = true
        if let fn = self.onCloseFn {
            fn(self)
        }
    }
}
