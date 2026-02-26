import Testing
@testable import AIBConfig

@Test(.timeLimit(.minutes(1)))
func durationParserParsesSeconds() throws {
    let duration = try DurationString("5s").parse()
    #expect(duration.components.seconds == 5)
}
