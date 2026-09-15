# M08 operator SOP

Run the two audit scripts against a selected local Skill or pre-expanded package. A failed or unknown check is a denial. The package audit never starts npm, Node, package scripts, or networking.

Before any real DSH change, create a profile backup with `New-XQDSHProfileBackup.ps1`, record the package, exact version, registry tarball source, integrity, and the backup manifest SHA-256 in the installation record. The plugin audit only treats the original `.tgz` as integrity-verifiable; a pre-expanded directory is always ineligible. Show all changes and obtain an operator confirmation outside the script. Real installation is deliberately not automated: run DSH's documented operator procedure only after approval.

Keep the record `PENDING` until a Windows 11 VM proves dump-config, boot, minimum function, and loopback-only listening. On any failure call `Restore-XQDSHProfileBackup.ps1` with the recorded `-ExpectedManifestSha256` and explicit `-ConfirmRestore RESTORE`, then repeat configuration verification. Restore verifies the approved manifest and every file before an atomic directory cutover. Removal uses the same explicit confirmation, backed-up profile restoration, and VM catalog/listener checks. Never place a key, token, cookie, or profile file content in records.
