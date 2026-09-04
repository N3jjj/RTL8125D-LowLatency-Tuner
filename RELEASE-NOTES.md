# Release notes — English public build

This build is based on the working GUI version, translated fully to English and hardened for public use.

Changes compared with the private/test build:

- all UI text, messages, logs and documentation are English;
- adapter discovery uses PCI hardware ID instead of only the friendly name;
- automatic profile application is locked to RTL8125D `DEV_8125 / REV_0C`;
- other RTL8125 revisions are detected but the Apply button is disabled;
- hardware ID and driver version are displayed in the GUI;
- applying the profile shows a warning/confirmation first;
- automatic registry backup remains enabled;
- README explains every setting and the experimental nature of hidden Realtek values;
- `irm | iex` usage is documented for an already elevated PowerShell window.


## v1.0.1 packaging fix

- Fixed the launcher/script filename mismatch in the release ZIP.
