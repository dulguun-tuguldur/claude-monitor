# Spike Results

Keychain service naming and live usage-response capture are pending — these
steps require the human (Mr. D) to run commands directly, since the agent is
policy-restricted from touching the macOS Keychain / live OAuth tokens.

Until filled in, the code uses the assumed values baked into
`KeychainStore.candidateServices`, `UsageSnapshot` key constants, and
`TokenRefresher` (documented in the design spec).
