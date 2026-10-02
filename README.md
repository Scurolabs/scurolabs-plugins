<p align="center">
  <img src=".github/scurolabs_full_vertical-white.png" alt="ScuroLabs" width="260">
</p>

<p align="center">
  <strong>Independent Noctalia plugins for Linux desktops.</strong><br>
  <sub>Small utilities and visual experiments.</sub>
</p>

<p align="center">
  <a href="#plugins">Plugins</a> ·
  <a href="#installation">Installation</a> ·
  <a href="#security">Security</a> ·
  <a href="#ai-development-disclosure">AI development</a> ·
  <a href="#contributing">Contributing</a>
</p>

---

## Overview

ScuroLabs is a maintainer-led collection of Noctalia plugins for Linux
desktops. Each plugin is reviewed for its behavior, system access, manifest,
documentation, and compatibility evidence before it is considered for release.

ScuroLabs is not a general plugin marketplace or a submission queue. General
plugin submissions should use Noctalia's community-plugin process.

## Plugins

| Plugin | What it does | Access | Status |
| --- | --- | --- | --- |
| **I/O Usage**<br>`scurolabs/io-usage` | Displays aggregate read and write throughput in a Noctalia bar. | Read-only `/proc/diskstats` and `/sys/block` | **Pending** |
| **Radio Tellus**<br>`scurolabs/radio-tellus` | Browses and plays internet radio by country, genre, and mood, with Favorites, Recent history, and optional Last.fm scrobbling. | Radio Browser, station streams, optional Last.fm access, local playback processes, and saved plugin data and Last.fm credentials | **Pending** |

## Installation

> [!IMPORTANT]
> Public installation instructions remain unavailable until the standalone
> Noctalia source is authorized for release. Do not add this repository as a
> Noctalia source.

When the source is authorized, this section will contain the exact installation
command and the commands users can run to verify the source and enabled plugin.

## Requirements

Requirements vary by plugin. Check the relevant plugin README for Linux,
Noctalia, hardware, dependency, and compatibility requirements.

## Security

> [!WARNING]
> Noctalia plugins run with the user's privileges. Noctalia does not provide a
> filesystem, process, network, or credential security sandbox for plugins.

Review the relevant plugin README before installation. Each plugin's security
disclosure records:

- files and directories it reads or changes;
- processes, network, credentials, and sensitive data it can access;
- persistence, authorization prompts, and other side effects.

## AI development disclosure

ScuroLabs uses substantial AI assistance throughout development, including code
drafting, documentation, and review support. The maintainer remains responsible
for understanding, reviewing, testing, making security decisions, and
maintaining the project. AI-generated checks, screenshots, and test output do
not satisfy the human publication gate.

## Compatibility

Compatibility evidence is recorded per plugin. A platform is not described as
tested unless dated maintainer or community evidence exists. Expected but
untested platforms remain identified as untested.

## Contributing

Outside contributions and public issue handling are not currently enabled for
ScuroLabs. A plugin may be considered after explicit maintainer review of its
behavior, access, compatibility, documentation, and release requirements.

## Licensing

Licensing is documented per plugin. Confirm the license text and attribution
for each plugin before any public release.

---

<p align="center">
  <sub>ScuroLabs · Noctalia plugins for Linux desktops</sub>
</p>
