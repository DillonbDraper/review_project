# Safe conference operation diagnostics

Open the browser developer console before reproducing the call and filter for
`Conference operation failed`. Copy only that warning's small structured record:
operation, exception name, reason category, signalingState, iceConnectionState,
connectionState and iceGatheringState. For example:

```json
{"operation":"setRemoteDescription","name":"OperationError","reason":"operation-rejected","signalingState":"have-remote-offer","iceConnectionState":"checking","connectionState":"connecting","iceGatheringState":"complete"}
```

These are allowlisted values, not raw exception messages. Unknown values become
`Error`, `unclassified` or `unknown`. A reason describes the exception class, not
the underlying network cause. This does not establish a TURN or connectivity
diagnosis. Successful operations produce no warning. Warnings cover description,
ICE candidate and track mutations, including synchronous failures and rejected
promises; replaced tracks use their owning peer group's connection states.

Do not share full console exports, native error objects, SDP, ICE candidates,
WebRTC internals dumps, configuration, URLs, room identifiers or credentials.
No diagnostic telemetry is sent to a backend.
