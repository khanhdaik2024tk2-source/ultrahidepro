## Summary

- <!-- What does this PR do? -->

## Change set

- <!-- Files modified + brief rationale -->

## Audit / safety checklist

- [ ] I confirmed `AUDIT_REPORT.md` rules (`UHPathBlocked`, denylist, vm_read
      over `__TEXT` only, kernel patches guarded by `UH_KwriteSafe`).
- [ ] I read the layer that I touched end-to-end (no orphan symbols).
- [ ] I added/updated smoke tests if new hooks were introduced.

## Build / CI

- [ ] Local `bash scripts/test_app.sh` passes.
- [ ] `make analyze=1` does not surface new warnings.

## Risk

- **Layer**: <!-- filesystem / process / dyld / env / sandbox_amfi / net /
   bridge / anti_hook / runtime / kernel -->
- **Process bundle-IDs affected**: <!-- list or "none" -->
- **Substrate/ElleKit coverage**: <!-- MSHookFunction or MSHookMessageEx -->

## Manual test plan

- [ ] Built `.deb` installs via Sileo on Dopamine 3.0.9 / iOS 18.6.2.
- [ ] `log stream --predicate 'subsystem == "com.ultrahidepro.tweak"'`
      shows no error/fault entries.
- [ ] Banking app (VCB / MBBank / MoMo) launches without jailbreak prompt.
- [ ] SpringBoard stable (no respring loop, denylist preserved).

## References

- AUDIT_REPORT.md §... <!-- Id of relevant audit finding -->
