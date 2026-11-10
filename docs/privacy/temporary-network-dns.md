# Temporary network DNS session

The user-authorized session is opt-in. Startup acquires an exclusive file lock,
recovers an interrupted session, and starts Astra's loopback UDP/TCP resolver.
The resolver forwards DNS messages through encrypted HTTPS using the browser's
selected network route. Its endpoint is an IP literal so bootstrap requires no
system DNS. No other application's settings, files, processes or account data
are inspected. Startup geography uses only the public exit location lookup.

A successful resolver probe precedes the system DNS change. macOS grants
network preference authorization through its native dialog. The original DNS
configuration of the active network service is recorded in a private journal
before mutation. Only DNS server addresses and port are owned by Astra.

Shutdown restores only values still owned by Astra. Concurrent edits to other
DNS fields survive restoration. Changed server addresses or port are treated
as a user replacement. Failed restoration retains the journal for the next
startup. Crash recovery runs on the next launch. A health check restores the
original settings if the encrypted resolver becomes unavailable while running.
A second app instance cannot acquire or restore the first instance's lease.

The networking layer owns the resolver and recovery. APIClient owns encrypted
DNS transport. The lifecycle adapter waits for startup and shutdown operations
so navigation cannot race initialization or discard unfinished recovery.
Proxy-side resolution remains controlled by the proxy. This feature does not
claim to modify or hide a remote proxy's DNS resolver.

Acceptance covers UDP/TCP DNS, startup, normal exit, automatic DNS, user edits,
recovery after interruption, and administrator authorization failure.

## Verification on 2026-11-10

The four focused policy tests pass. The loopback resolver answers UDP and TCP
queries. An authorized normal launch installed 127.0.0.1 with port 15353 in
macOS resolver configuration and created the private recovery journal.
Normal exit restored the previous 192.168.1.1 resolver, removed the recovery
journal and closed both loopback listeners. The application process exited.
