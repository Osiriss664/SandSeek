/// The version `sandseek --version` prints. Scripts/package_app.sh reads the
/// quoted value on the `current` line below as the default of the app bundle's
/// CFBundleShortVersionString (SANDSEEK_VERSION overrides it), so change it
/// here only and keep that line in this form.
public enum SandSeekVersion {
    public static let current = "0.1.0"

    /// What `sandseek --version` prints.
    public static let text = "sandseek \(current)"
}
