# Prompt Petal installers

Release binaries for the desktop builds, and the Windows CI that verifies them.

**No application source lives here, and none ever will.** This repo is public so that
GitHub Actions minutes are free; the source is private. The workflow fetches it into the
runner's throwaway workspace with a read only deploy key scoped to that one private
repo, and only finished artifacts come back here.

That split is not tidiness. A workflow committed to a private repo on a billing blocked
account is refused before a runner is assigned, and it does not warn you at commit time:
it simply never runs, which is the worst way for a build gate to fail.

## What the Windows workflow does

Builds the jpackage `.exe` on a real Windows runner, signs it, installs it silently the
way a Microsoft Store certifier does, and then asserts what certification actually
checks:

- a Start Menu shortcut, in the place the declared install scope puts it
- an Add or Remove Programs entry with a working uninstall string
- an ARP publisher matching the organisation on the signing certificate
- the installed binary launches and stays up, and its window carries the app's own icon

Every one of those exists because a real submission was rejected for it, on this account,
across three sibling apps. The `break_mode` input injects a known defect so an assertion
can be watched going red; a check that has never failed has never been tested.

The same `.exe` goes on promptpetal.com and into the Microsoft Store, so there is one
Windows artifact rather than two builds of one version.
