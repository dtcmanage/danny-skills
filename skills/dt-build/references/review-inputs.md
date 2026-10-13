# Review input packets

Use the tooling packet for review evidence with mutable operator context. Existing run-authored
seals, approvals and operation boundaries retain their original meaning. This tooling does not
rewrite them, authorize a successor, or exempt any existing pin.

Before review prep, author a JSON input manifest: `{"inputs":[{"path":"<absolute path>","kind":"source"}]}`.
Relative paths resolve from the manifest's directory. Omitted `kind` means `immutable`.
The mutable kinds are defined only in `scripts/review-inputs.ps1` (`DtReviewMutableKinds`):
declare the applicable kind for each operator context input. Do not label source, authority,
approval, or predecessor evidence as mutable, even when that evidence is a guide or notes file.
A guide used as an authorization policy is authority, not mutable operator context.
The manifest must cover every input required by the review; it grants no authority.

Run `scripts/prepare-review-packet.ps1 -InputManifestPath <manifest> -PacketDirectory <new directory>`.
It copies mutable inputs into the packet and hashes the copied bytes. Immutable inputs retain
live path/hash/size pins. It returns `packet_path`, `packet_sha256`, and each input's `review_path`.
Retain the packet hash in the review dispatch/evidence record and use `review_path` in the
review prompt. Do not substitute live mutable files for the snapshots. Never overwrite a packet.

Before dispatch and again before consuming its verdict, run
`scripts/verify-review-packet.ps1 -PacketPath <packet> -ExpectedPacketSha256 <prep hash>`.
An edited immutable input, packet, or snapshot fails. Mutable live edits produce `changes`
information, including added and removed/edited note entry counts; guides report changed.
Missing or malformed live context is reported as unavailable/unreadable, without altering
the review snapshot. Append-only text/JSONL counts nonempty lines as entries, including duplicates.
Persist the result with the review evidence. Continue to read and follow complete current
operator instructions through normal run status/resume; a snapshot does not freeze live instructions.

Use `Test-DtPathEqual` from `scripts/path-identity.ps1` wherever a path in a recorded binding
is compared to an observed path. Compare hash and byte count separately. It normalizes both
slash forms, trailing separators and Windows case, preserving roots and UNC shares.
Never compare entire path/hash/size dictionaries for filesystem identity.

For old run-authored pins, adoption requires the run's permitted operator action. Preserve
historical records and qualification evidence; do not replace pins or waive a stop merely
because this tooling is available.
