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
import NIOSSL
import NIOExtras
import Foundation

// swiftlint:disable function_parameter_count

public final class NetworkEvent: Event {
    public func type() -> String { return "network" }
    public func time() -> TimePoint { return timePoint }
    public func assetId() -> String { return idAsset }
    public func workspaceId() -> String { return idWorkspace }
    public func workspaceToken() -> String? { return tokenWorkspace }
    public func info() -> EventInfo? { return eventInfo }
    public func data() -> ByteBuffer { return bytes }
    public init(time: TimePoint?,
                assetId: String,
                workspaceId: String,
                workspaceToken: String? = nil,
                bytes: ByteBuffer,
                info: EventInfo? = nil) {
        self.timePoint = time ?? TimePoint(0, 1000)
        self.eventInfo = info
        self.idAsset = assetId
        self.idWorkspace = workspaceId
        self.tokenWorkspace = workspaceToken
        self.bytes = bytes
    }
    private let timePoint: TimePoint
    private let idAsset: String
    private let idWorkspace: String
    private let tokenWorkspace: String?
    private let eventInfo: EventInfo?
    private let bytes: ByteBuffer
}

public final class Connection: Source<NetworkEvent>, ChannelInboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    public let ident: String

    private let connected: (_ ctx: Connection) -> Void
    private let ended: (_ ctx: Connection) -> Void
    private let clock: Clock
    private weak var ctx: ChannelHandlerContext?

    public init(_ clock: Clock,
                uuid: String? = nil,
                connected: @escaping (_ ctx: Connection) -> Void,
                ended: @escaping (_ ctx: Connection) -> Void) {

        self.ended = ended
        self.connected = connected
        self.clock = clock
        self.ident = uuid ?? UUID().uuidString
        super.init()
        super.set { [weak self] event in
            guard let strongSelf = self else {
                print("no longer here")
                return .gone
            }
            if let ctx = strongSelf.ctx,
              strongSelf.ident != event.assetId() {
                let data = event.data()
                ctx.pipeline.eventLoop.execute { [weak self] in
                    guard let strongSelf = self else {
                        return
                    }
                    ctx.writeAndFlush(strongSelf.wrapOutboundOut(data), promise: nil)
                }
                return .nothing(event.info())
            } else {
                return .just(event)
            }
        }
    }

    // Invoked on client connection
    public func channelRegistered(context: ChannelHandlerContext) { }

    public func channelActive(context: ChannelHandlerContext) {
        self.ctx = context
        self.connected(self)
    }

    // Invoked on client disconnect
    public func channelInactive(context: ChannelHandlerContext) {
        self.ended(self)
    }

    public func close() {
        if let ctx = self.ctx {
            ctx.pipeline.eventLoop.execute { ctx.close(promise: nil) }
        }
    }
    // Invoked when data are received from the client
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let bytes = self.unwrapInboundIn(data)
        let event = NetworkEvent(time: self.clock.current(),
                                 assetId: self.ident,
                                 workspaceId: "network",
                                 bytes: bytes)
        let result = self.emit(event)
        switch result {
        case .error(let error):
            print("got error \(error)")
            self.close()
        case .gone:
            print("got .gone")
            self.close()
        default: ()
        }
    }

    // Invoked when channelRead as processed all the read event in the current read operation
    public func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }

    // Invoked when an error occurs
    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("error: ", error)
        _ = .error(EventError("tcp", -1, "\(error)")) >>- self
    }
}

public func tcpServe(group: EventLoopGroup,
                     host: String,
                     port: Int,
                     clock: Clock,
                     quiesce: ServerQuiescingHelper,
                     connected: @escaping (_ ctx: Connection) -> Void,
                     ended: @escaping (_ ctx: Connection) -> Void) -> EventLoopFuture<Channel> {

    let res = ServerBootstrap(group: group)
        // Define backlog and enable SO_REUSEADDR options at the server level
        .serverChannelOption(ChannelOptions.backlog, value: 256)
        .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
        .serverChannelInitializer { channel in
            channel.pipeline.addHandler(quiesce.makeServerChannelHandler(channel: channel))
        }
        // Handler Pipeline: handlers that are processing events from accepted Channels
        // To demonstrate that we can have several reusable handlers we start with a Swift-NIO default
        // handler that limits the speed at which we read from the client if we cannot keep up with the
        // processing through EchoHandler.
        // This is to protect the server from overload.
        .childChannelInitializer { channel in
            channel.pipeline.addHandler(BackPressureHandler()).flatMap { _ in
                channel.pipeline.addHandler(Connection(clock, connected: connected, ended: ended))
            }
        }

        // Enable common socket options at the channel level (TCP_NODELAY and SO_REUSEADDR).
        // These options are applied to accepted Channels
        .childChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
        // Message grouping
        .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
        // Let Swift-NIO adjust the buffer size, based on actual trafic.
        .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())
        .bind(host: host, port: port)

    return res
}

public func tcpClient(group: EventLoopGroup,
                      host: String,
                      port: Int,
                      clock: Clock,
                      uuid: String? = nil,
                      connected: @escaping (_ ctx: Connection) -> Void,
                      ended: @escaping (_ ctx: Connection) -> Void) -> EventLoopFuture<Channel> {
    let res = ClientBootstrap(group: group)
        .channelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())
        .channelInitializer { channel in
            channel.pipeline.addHandler(BackPressureHandler()).flatMap { _ in
                channel.pipeline.addHandler(Connection(clock, uuid: uuid, connected: connected, ended: ended))
            }
        }
    return res.connect(host: host, port: port)
}

public func tlsClient(group: EventLoopGroup,
                      host: String,
                      port: Int,
                      clock: Clock,
                      uuid: String? = nil,
                      connected: @escaping (_ ctx: Connection) -> Void,
                      ended: @escaping (_ ctx: Connection) -> Void) throws -> EventLoopFuture<Channel> {
    let configuration = TLSConfiguration.forClient()
    let tlsContext = try NIOSSLContext(configuration: configuration)
    let tlsHandler = try NIOSSLClientHandler(context: tlsContext, serverHostname: host)
    let res = ClientBootstrap(group: group)
        .channelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())
        .channelInitializer { channel in
            channel.pipeline.addHandler(tlsHandler).flatMap { _ in
                channel.pipeline.addHandler(Connection(clock, uuid: uuid, connected: connected, ended: ended))
            }
        }
    return res.connect(host: host, port: port)
}
