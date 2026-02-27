import NIOCore
import NIOHTTP1

/// Outbound adapter that converts `HTTPPart<HTTPResponseHead, ByteBuffer>`
/// into `HTTPServerResponsePart` (which uses `IOData`).
///
/// This sits at the tail of the NIO pipeline so that business logic can work
/// with `ByteBuffer` directly, while NIO's HTTP encoder receives `IOData`.
final class HTTPByteBufferResponsePartHandler: ChannelOutboundHandler, RemovableChannelHandler {
    typealias OutboundIn = HTTPPart<HTTPResponseHead, ByteBuffer>
    typealias OutboundOut = HTTPServerResponsePart

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let part = Self.unwrapOutboundIn(data)
        switch part {
        case .head(let head):
            context.write(Self.wrapOutboundOut(.head(head)), promise: promise)
        case .body(let buffer):
            context.write(Self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: promise)
        case .end(let trailers):
            context.write(Self.wrapOutboundOut(.end(trailers)), promise: promise)
        }
    }
}
