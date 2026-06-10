# Troubleshooting

## `No Account for Team "FAG3XX5RL8"`

Open Xcode, go to Settings, add the Apple Developer account, and retry the signed build with `-allowProvisioningUpdates`.

## `No profiles for io.github.languel.sketchcam`

Automatic signing needs to create Mac App Development profiles for the app and extension. Use Xcode once if CLI provisioning cannot create them.

## Activate Fails Immediately

Make sure you are running `/Applications/SketchCam.app`, not a build product inside DerivedData. System extensions must be activated from an app in `/Applications`.

## Extension Approval Does Not Appear

Open System Settings and check:

```text
General -> Login Items & Extensions -> Camera Extensions
```

Also check:

```sh
systemextensionsctl list
```

## Camera Client Shows Fallback Pattern

The extension is active, but SketchCam.app is not publishing fresh host frames in the active format.

Check:

- Camera permission in System Settings.
- Test pattern toggle in SketchCam.
- Output preset in SketchCam.
- Whether another app is already holding exclusive camera access.

## Remove The Extension

Deactivate from SketchCam, then remove `/Applications/SketchCam.app`. macOS should also remove the bundled system extension. If it remains pending, reboot and check `systemextensionsctl list` again.

