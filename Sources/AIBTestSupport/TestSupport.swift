import AIBConfig
import AIBRuntimeCore
import Foundation

public enum AIBTestSupport {
    public static func sampleConfig() -> AIBConfig {
        AIBConfig(
            version: 1,
            gateway: .init(),
            services: [
                ServiceConfig(
                    id: "sample",
                    mountPath: "/sample",
                    port: 0,
                    run: ["/usr/bin/true"],
                    watchMode: .external,
                    health: .init(),
                    restart: .init()
                ),
            ]
        )
    }
}
