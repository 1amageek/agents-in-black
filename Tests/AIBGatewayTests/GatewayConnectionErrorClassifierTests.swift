@testable import AIBGateway
import Darwin
import NIOCore
import Testing

@Suite(.timeLimit(.minutes(1)))
struct GatewayConnectionErrorClassifierTests {

    @Test
    func treatsCommonClientDisconnectsAsExpected() {
        #expect(
            GatewayConnectionErrorClassifier.isExpectedClientDisconnect(
                IOError(errnoCode: ECONNRESET, reason: "read(descriptor:pointer:size:)")
            )
        )
        #expect(
            GatewayConnectionErrorClassifier.isExpectedClientDisconnect(
                IOError(errnoCode: EPIPE, reason: "write(descriptor:pointer:size:)")
            )
        )
        #expect(GatewayConnectionErrorClassifier.isExpectedClientDisconnect(ChannelError.eof))
    }

    @Test
    func leavesUnexpectedErrorsAsFailures() {
        #expect(
            !GatewayConnectionErrorClassifier.isExpectedClientDisconnect(
                IOError(errnoCode: EINVAL, reason: "bad request")
            )
        )
    }
}
