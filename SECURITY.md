# Security

Do not commit Tailscale auth keys, Chrome Remote Desktop authorization codes or
PINs, Codex authentication state, SSH private keys, browser profiles, or files
from any persistent state directory.

The example configuration deliberately contains no credentials. Authenticate
Tailscale and Chrome Remote Desktop interactively after the container starts.

Report a suspected vulnerability privately through GitHub's security advisory
interface for this repository. Do not open a public issue containing secrets.
