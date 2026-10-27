import Foundation

public enum AdministratorRecoveryPolicy {
    public static func permits(current: InstalledApp, original: InstalledApp, selectedVersion: String, selectedBuild: String) -> Bool {
        guard current.bundleID == original.bundleID, let team = ApplicationSourceCatalog.replacementTeam(for: original) else { return false }
        if current.version == original.version && current.build == original.build { return current.teamID == original.teamID }
        return current.teamID == team && VersionOrder.compare(current.version, selectedVersion) == .orderedSame && (selectedBuild.isEmpty || current.build == selectedBuild)
    }
}
