# Lab 02 — Vault HA with Raft Integrated Storage

## Objective

Build and operate a three-node HashiCorp Vault cluster using Docker and Raft Integrated Storage, then validate high availability through controlled node failure, leader election, secret replication, and node recovery.

The goal of this lab is to develop hands-on operational experience with Vault HA and Raft, including cluster initialization, node membership, quorum, failover, replication, and recovery.

---

## Environment

- HashiCorp Vault 2.1.0
- Docker Desktop
- Docker Compose
- Raft Integrated Storage
- Shamir seal
- Three Vault nodes
- Local Docker bridge network
- macOS / Apple Silicon

> **Note:** TLS is intentionally disabled in this lab to simplify initial HA and Raft experimentation. TLS, authentication methods, audit logging, and other production security controls will be introduced in later labs.

---

## Architecture

The lab consists of three Vault nodes running as Docker containers on a shared Docker network.

```text
                    Vault Cluster

                 ┌───────────────┐
                 │    Vault-1    │
                 │     LEADER    │
                 │     Voter     │
                 └───────┬───────┘
                         │
                   Raft replication
                    ┌────┴────┐
                    │         │
             ┌──────▼─────┐ ┌─▼───────────┐
             │   Vault-2  │ │   Vault-3   │
             │   STANDBY  │ │   STANDBY   │
             │    Voter   │ │    Voter    │
             └────────────┘ └─────────────┘
```

Each Vault node uses Raft Integrated Storage with its own persistent Docker volume.

### Node configuration

| Node | API Address | Cluster Address | Initial Role |
|---|---|---|---|
| Vault-1 | `vault-1:8200` | `vault-1:8201` | Leader |
| Vault-2 | `vault-2:8200` | `vault-2:8201` | Standby |
| Vault-3 | `vault-3:8200` | `vault-3:8201` | Standby |

Vault-1 exposes port `8200` to the host for administration. Vault-2 and Vault-3 communicate through the internal Docker network.

---

## Key Concepts

### Raft Integrated Storage

Vault's Integrated Storage uses the Raft consensus protocol to replicate Vault's storage data across cluster members.

One node is elected leader and coordinates writes. The other nodes maintain replicated state and can become leader if the current leader fails.

### Quorum

A Raft cluster requires a majority of its voters to maintain quorum.

For a three-node cluster:

```text
Total voters: 3
Required quorum: 2
Failure tolerance: 1 node
```

An important distinction is that Raft requires a **majority**, not an odd number of nodes.

Three nodes are commonly used because they can tolerate one node failure while maintaining quorum.

---

# Experiment 1 — Cluster Initialization

## Objective

Initialize Vault-1 and establish the initial Vault cluster.

Vault-1 was initialized using Shamir seal configuration with:

```text
Total Shares: 5
Threshold: 3
```

This means that three of the five generated unseal key shares are required to unseal the Vault.

The root token and unseal keys were stored securely and were not committed to the repository.

After initialization, Vault-1 was unsealed and confirmed as the active node.

---

# Experiment 2 — Build the Three-Node Cluster

Vault-2 and Vault-3 were started as independent Vault processes and configured with `retry_join` pointing to Vault-1.

Each node was then joined to the existing Raft cluster and unsealed using three unseal key shares.

The resulting cluster was verified using:

```bash
vault operator raft list-peers
```

Expected topology:

```text
Node      State      Voter
vault-1   leader     true
vault-2   follower   true
vault-3   follower   true
```

This verified that all three nodes were members of the same Raft cluster.

---

# Experiment 3 — Active Node Failure

## Hypothesis

If the active Vault node fails, the remaining two nodes should be able to maintain quorum and elect a new leader.

Before the failure:

```text
Vault-1 → Leader
Vault-2 → Follower
Vault-3 → Follower
```

Vault-1 was intentionally stopped:

```bash
docker stop vault-1
```

## Result

Vault-2 became the active node.

The cluster continued operating because Vault-2 and Vault-3 represented two of the three voters, maintaining the required majority.

Vault-2 reported:

```text
HA Enabled: true
HA Mode: active
```

### Result

**Hypothesis confirmed.**

The cluster maintained quorum and successfully performed leader election after the active node failed.

---

# Experiment 4 — Write During Failover

## Objective

Determine whether the cluster remains capable of accepting writes after the original leader fails.

With Vault-2 acting as the active node, the KV secrets engine was enabled and a test secret was written:

```text
secret/ha-test
```

The secret contained:

```text
message = "Vault 2 is the leader"
```

The write succeeded while Vault-1 was unavailable.

### Result

The cluster remained **read/write available** after losing one of its three voters.

This demonstrated that maintaining Raft quorum allows the cluster to continue processing writes.

---

# Experiment 5 — Verify Replication

The secret written through Vault-2 was retrieved from Vault-3.

Vault-3 successfully returned:

```text
message = Vault 2 is the leader
```

This verified that the data written through the new leader was replicated to another cluster member.

### Result

**Replication confirmed.**

The experiment demonstrated that a successful leader election was followed by continued data replication across the remaining cluster members.

---

# Experiment 6 — Recover the Original Leader

Vault-1 was restarted after the failover:

```bash
docker start vault-1
```

After restarting, Vault-1 was initially sealed and required unsealing.

After unsealing, Vault-1 reported:

```text
HA Enabled: true
HA Mode: standby
```

Vault-1 did not automatically become leader again.

Vault-2 remained the active node.

The previously created `secret/ha-test` secret was then retrieved from Vault-1 successfully.

### Result

This demonstrated that:

1. The failed node can be recovered.
2. The recovered node rejoins as a standby rather than automatically reclaiming leadership.
3. Raft brings the recovered node back into the replicated cluster state.
4. Data written while the node was unavailable remains accessible after recovery.

---

# Failure Scenario Summary

The complete failure and recovery sequence was:

```text
                    INITIAL STATE

             Vault-1 → LEADER
             Vault-2 → FOLLOWER
             Vault-3 → FOLLOWER

                        │
                        │ Stop Vault-1
                        ▼

                    FAILOVER

             Vault-1 → DOWN
             Vault-2 → LEADER
             Vault-3 → FOLLOWER

                        │
                        │ Write secret
                        ▼

                 REPLICATION

             Vault-2 → Write
             Vault-3 → Read successfully

                        │
                        │ Restart Vault-1
                        ▼

                    RECOVERY

             Vault-1 → STANDBY
             Vault-2 → LEADER
             Vault-3 → FOLLOWER

             Vault-1 → Read secret successfully
```

---

# Troubleshooting Encountered

Building the cluster exposed several operational issues that were resolved during implementation.

### HTTP/HTTPS mismatch

The Vault CLI defaults to HTTPS when `VAULT_ADDR` is not configured.

Because the initial lab configuration intentionally uses HTTP, the CLI initially attempted to communicate over HTTPS and returned an HTTP/TLS mismatch.

The issue was resolved by explicitly setting:

```bash
VAULT_ADDR=http://127.0.0.1:8200
```

### `disable_mlock` configuration

Vault required an explicit `disable_mlock` setting with the Raft storage configuration.

The following was added to each node:

```hcl
disable_mlock = true
```

This is a deliberate lab configuration for the Docker/Raft environment and will be revisited when production security controls are introduced.

### Docker volume permissions

Vault runs as a non-root user inside the official container image.

The Raft database initially failed to start because the Vault process did not have permission to write to the mounted data volume.

The Docker volumes were corrected so the Vault container user could access the Raft data directory.

### Authentication / authorization

An attempt to run:

```bash
vault operator raft list-peers
```

without authentication resulted in a `403` response.

The command was subsequently executed using an authorized Vault token.

This reinforced the distinction between:

- Network connectivity
- Vault authentication
- Vault authorization

---

# Key Lessons Learned

### 1. Running is not the same as being operational

A Vault container can be running while the Vault node is:

- Uninitialized
- Sealed
- Standby
- Active

These represent different operational states.

### 2. HA depends on quorum

A three-node Raft cluster can tolerate the loss of one voter because the remaining two nodes still constitute a majority.

```text
3 voters → quorum = 2
```

### 3. Leader failure does not mean cluster failure

When the active node failed, another voter was elected leader and the cluster continued processing writes.

### 4. Writes are replicated

A secret written through the new leader was subsequently available from another cluster member.

### 5. Node recovery and leader recovery are different concepts

The original leader did not automatically become leader after restarting.

It returned as a standby while the existing leader continued operating.

### 6. Troubleshooting requires understanding the layer that failed

The lab encountered issues at multiple layers:

```text
Docker
  ↓
Container permissions
  ↓
Vault process
  ↓
Vault configuration
  ↓
Raft cluster membership
  ↓
Authentication / authorization
```

Understanding which layer is failing is critical when troubleshooting a production Vault environment.

---

# Future Enhancements

This lab establishes the foundation for additional production-oriented Vault exercises.

Planned enhancements include:

- TLS between Vault nodes and clients
- Load balancing
- Vault authentication methods
- Fine-grained Vault policies
- Kubernetes authentication
- Kubernetes secret injection
- Dynamic database credentials
- PostgreSQL integration
- Automated credential rotation
- Python automation
- Terraform-based Vault configuration
- Git-based Policy as Code
- CI/CD integration
- Vault audit logging
- Monitoring and operational health checks
- Vault upgrades and patching
- Raft snapshot and recovery procedures
- Disaster recovery scenarios
- Additional failure and troubleshooting scenarios

---

# Conclusion

This lab provided hands-on experience operating a three-node Vault HA cluster using Raft Integrated Storage.

The primary HA scenario was successfully validated by:

1. Building a three-node Vault cluster.
2. Establishing Raft membership.
3. Simulating failure of the active node.
4. Observing automatic leader election.
5. Performing a write after failover.
6. Verifying replication from another cluster member.
7. Recovering the original node.
8. Verifying that the recovered node returned as a standby.
9. Confirming that replicated data remained available after recovery.

The lab is intentionally designed to progress from basic Vault administration toward increasingly realistic enterprise operational scenarios.
