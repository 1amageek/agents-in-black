import Foundation

/// Live information about a service that is currently deployed to a provider.
/// Returned by `DeploymentProvider.listDeployedServices`.
///
/// Cloud Run service names are scoped per region — the same name can exist in
/// multiple regions simultaneously. The identity therefore combines region and name.
public struct DeployedServiceInfo: Sendable, Equatable, Identifiable {
    public var id: String { "\(region)/\(name)" }

    /// Provider-side service name (e.g., Cloud Run service name).
    public var name: String

    /// Region the service is deployed to.
    public var region: String

    /// Public base URL of the service, when known.
    public var url: String?

    /// Container image reference of the latest live revision.
    public var image: String?

    /// When the latest revision was deployed.
    public var lastDeployedAt: Date?

    /// Latest revision name (provider-specific).
    public var revisionName: String?

    /// Provider-specific generation counter (Cloud Run: `metadata.generation`).
    public var generation: Int?

    /// Configured request timeout in seconds (when known).
    public var timeoutSeconds: Int?

    /// Names of environment variables configured on the service (values not exposed).
    public var envVarNames: Set<String>

    public init(
        name: String,
        region: String,
        url: String? = nil,
        image: String? = nil,
        lastDeployedAt: Date? = nil,
        revisionName: String? = nil,
        generation: Int? = nil,
        timeoutSeconds: Int? = nil,
        envVarNames: Set<String> = []
    ) {
        self.name = name
        self.region = region
        self.url = url
        self.image = image
        self.lastDeployedAt = lastDeployedAt
        self.revisionName = revisionName
        self.generation = generation
        self.timeoutSeconds = timeoutSeconds
        self.envVarNames = envVarNames
    }
}

/// Drift category for a single service, comparing the workspace plan
/// (the intended state) against what is actually deployed.
public enum DeploymentDriftStatus: Sendable, Equatable {

    /// The workspace plans this service and it is deployed in the expected region.
    /// Image / env / generation are within accepted bounds.
    case inSync

    /// The service exists in the deploy provider but is not present in the workspace plan.
    /// Typical case: leftover from an older topology, or a service deployed by hand.
    case orphan

    /// The workspace plans this service but no live deployment exists in the expected region.
    case missing

    /// The service is deployed, but in a different region than the workspace plan asks for.
    /// Carries the live region for display.
    case regionMismatch(deployedRegion: String, expectedRegion: String)

    /// The service is deployed in the right region, but the live image does not match
    /// the registry image AIB would push for the current plan.
    case imageStale(deployedImage: String, expectedImage: String)
}

/// Per-service drift entry produced by `AIBDeployService.computeDrift`.
public struct DeploymentDriftEntry: Sendable, Equatable, Identifiable {
    /// Identity combines the live region (or "missing") with the service name,
    /// so multi-region deployments of the same name remain distinguishable.
    public var id: String {
        if let deployed {
            return "\(deployed.region)/\(serviceName)"
        }
        return "missing/\(serviceName)"
    }

    /// Provider-side service name this entry refers to.
    public var serviceName: String

    /// Workspace service ref (e.g., `agent/node`) when the drift is about a planned service.
    /// `nil` for orphan deployments that have no matching plan entry.
    public var serviceRef: String?

    /// Live state, when the service is deployed.
    public var deployed: DeployedServiceInfo?

    /// Drift category.
    public var status: DeploymentDriftStatus

    public init(
        serviceName: String,
        serviceRef: String?,
        deployed: DeployedServiceInfo?,
        status: DeploymentDriftStatus
    ) {
        self.serviceName = serviceName
        self.serviceRef = serviceRef
        self.deployed = deployed
        self.status = status
    }
}

/// Aggregate drift report produced by `AIBDeployService.computeDrift`.
public struct DeploymentDriftReport: Sendable, Equatable {
    public var entries: [DeploymentDriftEntry]

    public init(entries: [DeploymentDriftEntry]) {
        self.entries = entries
    }

    public var orphans: [DeploymentDriftEntry] {
        entries.filter { if case .orphan = $0.status { return true } else { return false } }
    }

    public var missing: [DeploymentDriftEntry] {
        entries.filter { if case .missing = $0.status { return true } else { return false } }
    }

    public var regionMismatches: [DeploymentDriftEntry] {
        entries.filter {
            if case .regionMismatch = $0.status { return true } else { return false }
        }
    }

    public var imageStale: [DeploymentDriftEntry] {
        entries.filter {
            if case .imageStale = $0.status { return true } else { return false }
        }
    }

    public var inSync: [DeploymentDriftEntry] {
        entries.filter { if case .inSync = $0.status { return true } else { return false } }
    }
}
