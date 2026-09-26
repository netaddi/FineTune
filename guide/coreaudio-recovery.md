# Recovering after Core Audio restarts

A long playback pause and an audio-server restart are different failures. A
paused client can keep its existing tap. When `coreaudiod` restarts, its object
IDs and listener registrations may no longer describe the same objects; merely
rediscovering the app's PID does not restore capture.

## Recovery behavior

FineTune listens for the system audio-service restart notification. It advances
an audio-service generation, invalidates old routing work, stops provisioning
new graphs, and retires old callbacks. Old server IDs are abandoned rather than
destroyed in the new server, where the same numbers could belong to other
objects. Crash-cleanup bookkeeping is cleared without clearing plug-in crash
quarantine state.

After callbacks and in-flight device operations quiesce, FineTune re-registers
process, device and default-volume listeners, reads fresh snapshots, and
recreates required graphs with their saved gain, mute, routing and effects.
Persistent Console 1 hosts remain alive during this recovery so graph rebuilding
does not intentionally allocate new strips. Listener registration and graph
failures are retried; a visible warning reports incomplete protection. A failed
service recovery also offers **Retry**.

Normal graph teardown has a separate safety rule: a timed-out cleanup is still
pending, not completed. The foreground waits at most 100 ms per resource cleanup
before retaining it for background retry. Device stop, IOProc destruction,
aggregate destruction and tap destruction are ordered and identity-checked.
A replacement must not reuse a resource container whose previous cleanup is
still pending.

The health check uses output activity, not input activity. A graph that never
delivered its first callback can therefore be repaired. Retired/secondary or
unpublished callbacks cannot make a dead primary look healthy, while a legitimate
device transition is not mistaken for a stall. Partial listener registrations
are repaired independently.

## Safety limits

FineTune is not a system-wide fail-closed limiter. While Core Audio is down or
capture cannot be restored, macOS may produce unprocessed audio. Pause playback
or lower the physical monitor level when a recovery warning appears. Recovery
cannot cancel arbitrary synchronous HAL calls or a hung third-party Audio Unit;
such a failure may still require restarting FineTune or the audio service.

## Validation

`AudioServiceRecoveryTests` exercises graph restoration, saved processing,
repeated restarts, stopped-engine cancellation, missing devices, failed listener
registration, pending handoffs, output-only stalls and visible retry failures.
`AudioServiceLifetimeTests` covers callback retirement, stale health callbacks,
unknown resource identity and failed IOProc joins with injected HAL operations.

The opt-in integration test is intentionally separate from the normal suite:

```sh
FINETUNE_TEST_AUDIO_SERVICE_RESTART=1 swift test --filter AudioServiceRecoveryTests/realHALRestartNotifications
```

It waits up to 90 seconds for an operator to restart Core Audio twice. It does
not restart the service itself. Run only on a test machine with playback paused:
the test observes real HAL notifications but rebuilds recording test controllers,
not a physical output graph. Hardware loopback measurements and plug-in render
checks on the target machine remain necessary. An M1 test host without the M4's
BlackHole aggregate and Console 1 cannot establish those hardware-specific
results.

## Crash investigation boundary

The inspected 2026-09-26 M4 crash was inside Apple's
`HALS_IOContext_Legacy_Impl::ProcessOutputForTaps`, on the BlackHole aggregate's
I/O thread. Contemporaneous ARK activity and mixed sample rates are relevant
correlations, not proof of a sole root cause. Removing ARK and hardening FineTune's
resource lifetime reduce known interactions; neither proves that all Core Audio
crashes have been eliminated. Preserve new diagnostic reports if one recurs.
