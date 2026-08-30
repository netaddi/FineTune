# Persistent Console 1 Tracks

FineTune can keep one Softube Console 1 Audio Unit alive for each pinned app.
The instance belongs to the app's persistence identifier rather than to a
temporary process ID, tap, or output device, so ordinary app relaunches and
route changes do not allocate a different Console strip.

## Before you start

- Install and activate the Console 1 AUv2 plug-in before launching FineTune.
- Make the target app produce audio once so it appears in FineTune.
- Console 1 is supported on per-app effect chains only. FineTune deliberately
  excludes it from output-device chains because those hosts can be transient.
- Each app chain can contain at most one Console 1 instance.

## Configure a strip

1. Open FineTune's edit mode and pin the target app.
2. Expand that app's EQ/effects panel.
3. Choose **Add Effect**, search for **Console 1**, and add the Softube plug-in.
4. Repeat for the other apps that need persistent strips.
5. For each eligible app, choose **Console 1 startup order → Next launch
   #N**. Moving an app to an occupied position swaps the two positions.
6. Quit and reopen FineTune. The row label reports the saved order for the next
   launch; changing it does not destroy or renumber the instance that is
   already running.

The saved number is a deterministic *FineTune startup order*, not an absolute
Softube track number. Console 1 selects the lowest free track across every host
on the Mac. If a DAW or another Audio Unit host already owns lower tracks, close
those hosts before restarting FineTune when exact track numbers matter.

## What stays persistent

For an eligible pinned app, FineTune retains the Console 1 instance while the
app is inactive and across process relaunches, tap recreation, output changes,
and ordinary effect or chain bypasses. Bypassing therefore does not release the
startup position. Removing Console 1, unpinning or ignoring the app releases
its position and compacts the remaining order.

A plug-in quarantined after a crash is not instantiated and does not reserve a
position. Resolve the plug-in problem before removing and adding it again; this
prevents a repeated startup crash loop.

## Multichannel signal path

Some USB interfaces expose a stream-specific tap with more than two channels.
FineTune resolves the tap source and output destination independently: it
extracts the source device's preferred L/R pair, runs the per-app EQ and Audio
Unit chain once as stereo, and writes the result to the destination device's
preferred L/R pair. Every other native channel passes through with the same
gain ramp and limiter protection.

Seeing the Console 1 window or component in memory proves that the instance
loaded, but not by itself that audio reached its render callback. If a plug-in
appears loaded while the sound remains unchanged, compare the chain bypass with
a deliberately obvious effect or preset. Also confirm that the interface's
preferred output pair is the pair connected to the monitor path. See the
[troubleshooting guide](troubleshooting.md#audio-unit-loads-but-sound-does-not-change).

## Built-in EQ is independent

The FineTune 10-band EQ is separate from the Audio Unit chain. An app with no
saved EQ choice starts with a flat curve and the EQ switched off. FineTune
preserves an existing explicit on/off choice. Adding Console 1 does not enable
the built-in EQ.

## Backup and recovery

FineTune saves app pins, effect chains, Console startup order, plug-in state,
and EQ choices in:

```text
~/Library/Application Support/FineTune/settings.json
```

Quit FineTune before copying or restoring this file; a running instance can
overwrite manual changes. The serialized Audio Unit preset data is opaque and
may depend on the installed plug-in version, so keep the whole file together
with the matching FineTune and Console 1 versions.

If the assigned track is unexpected:

1. Confirm that every target app is pinned and contains exactly one Console 1.
2. Check the **Next launch #N** order on each app row.
3. Quit FineTune and any other Console 1 hosts.
4. Reopen FineTune before the other hosts.
5. If a plug-in row shows a load warning, resolve that failure first; a
   quarantined instance intentionally does not participate in the order.
