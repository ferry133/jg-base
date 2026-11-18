## ADDED Requirements

### Requirement: A cluster that has not turned chamber on is unchanged

The chamber additions SHALL live in a kustomize component that no default path references. With the component not referenced, the rendered output of every existing im path SHALL be byte-identical to what it was before this change. With the component referenced, the rendered output minus the component's additions SHALL equal the output without it.

#### Scenario: Merge with nothing turned on
- **WHEN** this change is merged and no cluster references the component
- **THEN** the render of each existing im path is byte-identical to the render before the merge

#### Scenario: The component touches something it should not
- **WHEN** the component's patch changes a field of an existing container other than the additions it declares
- **THEN** the guard fails and names the field

### Requirement: The login credential is mounted into the bridge container only

The Secret that carries the chamber login credential and the server address SHALL be referenced only by the `chamber-bridge` container: no other container, init containers included, SHALL mount it or read any of its keys through its environment. The Secret SHALL be marked optional, so that a pod whose Secret has not arrived still starts and its terminal still serves.

#### Scenario: The credential is also wired into `app`
- **WHEN** a change adds the Secret to the `app` container's mounts or environment
- **THEN** the guard fails

#### Scenario: The Secret has not arrived
- **WHEN** the component is referenced and the Secret does not exist
- **THEN** the pod is Running and Ready, the terminal answers, and the bridge container's log names what is missing

### Requirement: The bridge is reachable only through a socket shared by two containers

The pod SHALL provide one in-memory volume mounted by `app` and `chamber-bridge` and by no other container, and the `chamber-bridge` container SHALL declare no port. The address `app` is given for chamber SHALL be a path on that volume.

#### Scenario: A third container mounts the socket volume
- **WHEN** a change mounts the socket volume into any other container
- **THEN** the guard fails

#### Scenario: Listening sockets on the node
- **WHEN** the component is running on a cluster and the node's listening TCP sockets are listed
- **THEN** none belongs to the bridge (positive control: the same listing shows the terminal's port)

### Requirement: The signer list reaches the pod and follows its source

The list of people's public keys and the list of revoked keys SHALL be delivered as one ConfigMap mounted read-only as a directory into `app`, without `subPath`, so that a change to the ConfigMap reaches a running pod without a restart. An empty list SHALL be a valid state. A change to either list SHALL NOT be merged without the operator's approval.

#### Scenario: A key is revoked
- **WHEN** a key is moved to the revoked list and the ConfigMap is updated
- **THEN** a directive signed by that key, which verified in the running pod before, fails in the same pod without a restart

#### Scenario: No person has a key yet
- **WHEN** both lists are empty
- **THEN** the pod starts, and the daily check reports that no signer is listed rather than reporting the verifier as healthy

### Requirement: The bridge image is the terminal's image

The `chamber-bridge` container SHALL run the same pinned image as `app`, taken from `app`'s pin by a replacement rather than written a second time.

#### Scenario: The image pin is bumped
- **WHEN** the pin in the default im path is bumped
- **THEN** the rendered bridge container carries the new pin with no edit to the component

### Requirement: Chamber membership is measured daily, with three outcomes

daily-check SHALL carry one row that reads, from the im pod's logs and without exec, whether the server is reachable, whether the rooms the im is in are exactly the expected ones, whether the verifier and the signer list are present, and whether the im shows as online. The expected rooms SHALL be derived by daily-check, not taken from the bridge's own report. A status line that is absent, unreadable or older than three reporting intervals SHALL make the row "not measured", never "ok". A cluster without the component SHALL report that chamber is not turned on. In deliver mode an im that is not online SHALL fail the row; in observe mode the online reading SHALL be reported and not judged.

#### Scenario: The status line is stale
- **WHEN** the newest status line is older than three reporting intervals
- **THEN** the row is "not measured" and says how old the line is

#### Scenario: The im is in a room it should not be in
- **WHEN** the bridge reports a room other than the expected one
- **THEN** the row fails and prints both the reported and the expected rooms

#### Scenario: Deliver mode, no session
- **WHEN** the mode is deliver and the status line says the im is not online
- **THEN** the row fails

#### Scenario: Chamber not turned on
- **WHEN** the im has no bridge container
- **THEN** the row is skipped with a message saying chamber is not turned on for this cluster
