# CI / Build status

This project uses GitHub Actions to produce `.deb` artifacts for the
tweak. The expected pipeline:

```
push / PR / dispatch
      │
      ├─ lint.yml                  (Ubuntu 22.04, fast feedback)
      │     ├── plist_json           validate every plist & JSON
      │     ├── sources_count        sanity minimum of .m files / hooks
      │     └── shellcheck           bash quality on scripts/*.sh
      │
      └─ build.yml                 (macOS-14, slow production-grade)
            ├── verify               Theos build → upload .deb artifact
            └── lint                 clang static analysis (`make analyze=1`)
                                       — non-blocking, advisory only
```

Required secrets / settings:

* No secrets.
* `GITHUB_TOKEN` (default; for artifact upload).
* Repository setting: Pages **off** (we don't deploy dashboards; the
  artifacts are .deb files only).

Required local setup (for reproducing CI):

```bash
sudo mkdir -p /opt
sudo chown -R "$(whoami)" /opt
git clone --depth 1 https://github.com/theos/theos.git /opt/theos
brew install ldid jq xz
curl -L -o /tmp/ios18.6.tar.xz \
  https://github.com/theos/sdks/releases/download/iPhoneOS18.6/iPhoneOS18.6.sdk.tar.xz
mkdir -p /opt/theos/sdks
tar -xJf /tmp/ios18.6.tar.xz -C /opt/theos/sdks
THEOS=/opt/theos bash scripts/test_app.sh
```

## Failure recovery

| Symptom                                          | Likely cause                            | Fix |
| ------------------------------------------------ | --------------------------------------- | --- |
| `clang: error: 'libsubstrate/libsubstrate.h' not found` | Theos/ElleKit not on disk       | `git clone ... /opt/theos` |
| `error: SDK "iPhoneOS18.6.sdk" not found`        | SDK archive cache miss                  | re-run CI after cache warm-up |
| `fatal error: 'ellekit/ellekit.h' not found`     | Stage mismatch between LLE and SDK     | bump LLE in control |
| Build succeeds but `dpkg-deb` fails              | Resource copy step missing              | verify Makefile `internal-package::` |
| Workflow hangs forever                           | Xcode not selected                      | use `macos-14` default + keep `xcode-select` step |

## Manual probe

After CI uploads an artifact, install on a Dopamine device:

```bash
dpkg -i UltraHidePro-arm64-deb/com.ultrahidepro.tweak_*.deb
ssh root@iphone 'killall -9 SpringBoard || true'
ssh root@iphone 'log stream --predicate "subsystem == \"com.ultrahidepro.tweak\"" &'
```
