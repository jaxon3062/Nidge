# Nidge

Open-source iPhone app for downloading photos from a Nikon Z5II to Apple
Photos. Download only; no camera control. Full requirements, architecture and
milestones are in `docs/PLAN.md`. Read it before starting work.

## Working rules

- Follow the milestones in order. Each has a gate; if a gate fails, stop and
  report to the owner instead of working around it silently.
- Protocol facts must be verified on the real Z5II. Record findings in
  `docs/protocol/`. Never claim something works without a test on the camera.
- Protocol code lives in the `NidgeKit` Swift package and must stay testable
  from macOS through `nidge-cli` and the mock PTP/IP server.
- Do not copy code from AGPL/GPL projects (nsg, libgphoto2). Use them as
  protocol references only.
- Do not use "SnapBridge", "Nikon" or Nikon logos in the app name, icon or
  bundle ID.
- Target iOS 26, Swift 6, SwiftUI. Test device: iPhone 13 Pro. The owner is on
  a free Apple ID, so avoid capabilities that need a paid team unless the plan
  says otherwise.
- Steps that need the camera, the phone, or a capture tool require the owner's
  hands. Give exact instructions and wait for the result.
