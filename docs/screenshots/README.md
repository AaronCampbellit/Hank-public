# Native Hank screenshot provenance

Captured on October 5, 2026, from the actual SwiftUI application in a task-owned
iPhone 17 Pro simulator running iOS 27.0, using Xcode 27.0 beta. The simulator
build used local ad hoc signing so Keychain-backed authentication could run.

- `settings.png`: the native profile and tab-order settings for the synthetic
  `alex@hank.example` account.
- `signin.png`: the native saved-profile sign-in screen after logging out of
  that synthetic account.

Both images are unmodified 1206 × 2622 PNG captures. A temporary XCTest UI
capture target drove the implemented app through normal controls; it did not
replace product views, network responses, or rendered content. The temporary
target and its generated credentials are not part of this repository.

The account belonged to a new, disposable local HankServerside Home reached
through a loopback tunnel. No production account, customer data, real home
integration, managed machine, or AI provider was connected.

The native app and share extension built successfully, and the existing
`HankTests` suite passed 96 tests with no failures or skips. Simulator evidence
does not verify device provisioning, APNs, App Store distribution, or physical
agent integrations. Default Notes/Calendar tab taps did not change the visible
page in this iOS 27 beta automation run; those images are excluded, and no
claim of complete native UI acceptance is made.

To reproduce, start the HankServerside disposable demo, run this app on a
simulator with the Debug autoconnect variables described in the root README,
open More → Settings, capture the screen, log out, and capture sign-in.
Keep account credentials, custom schemes, test bundles, and simulator data
private and untracked.
