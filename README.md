# TotheMoonSands Home Assistant Add-ons

Custom add-on repository for Home Assistant.

## Add-ons in this repository

- `git_pull`: Pull Home Assistant config updates from Git with robust SSH/HTTPS auth handling.

## Install in Home Assistant

1. Go to **Settings** -> **Add-ons** -> **Add-on Store**.
2. Open the menu in the top-right and choose **Repositories**.
3. Add this repository URL:
   - `https://github.com/<your-org>/ha_git_pull`
4. Reload the add-on store and install **Git pull**.

## Fork improvements

This fork adds:

- hardened SSH and HTTPS auth handling
- deployment key normalization/validation
- persistent SSH known_hosts handling
- remote URL normalization and repair
- optional Home Assistant `quick_reload` apply mode

Detailed add-on docs: `git_pull/DOCS.md`  
Public-history cleanup guide: `PUBLIC_RELEASE.md`
